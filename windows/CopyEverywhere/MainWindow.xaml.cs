using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CopyEverywhere.Services;
using Microsoft.Toolkit.Uwp.Notifications;
using Microsoft.Win32;
using Windows.Devices.Enumeration;

namespace CopyEverywhere;

public partial class MainWindow : Window
{
    private enum SseConnectionState
    {
        Disconnected,
        Reconnecting,
        Connected
    }

    private readonly ConfigStore _configStore;
    private readonly ApiClient _apiClient;
    private readonly MdnsDiscoveryService _mdnsService;
    private readonly BluetoothService _bluetoothService;
    private readonly ServerConfig _serverConfig;
    private readonly ServerProcess _serverProcess;

    public ConfigStore ConfigStore => _configStore;
    public ApiClient ApiClient => _apiClient;
    public BluetoothService BluetoothService => _bluetoothService;
    public ServerConfig ServerConfig => _serverConfig;
    public ServerProcess ServerProcess => _serverProcess;
    private SendService? _sendService;
    public SendService? SendService
    {
        get => _sendService;
        set
        {
            if (_sendService != null)
                _sendService.BluetoothSendProgress -= OnBluetoothSendProgress;
            _sendService = value;
            if (_sendService != null)
                _sendService.BluetoothSendProgress += OnBluetoothSendProgress;
        }
    }

    public event Action<bool>? FloatingBallVisibilityChanged;

    private const int ChunkSize = 10 * 1024 * 1024; // 10MB
    private const long ChunkedThreshold = 50L * 1024 * 1024; // 50MB

    // Chunked upload state
    private CancellationTokenSource? _uploadCts;
    private string? _chunkedUploadId;
    private string? _chunkedFilePath;
    private bool _isChunkedUpload;

    // Download state
    private ClipResponse? _downloadClipMetadata;

    // Queue polling timer
    private System.Windows.Threading.DispatcherTimer? _queueTimer;

    // SSE state
    private CancellationTokenSource? _sseCts;
    private System.Threading.Tasks.Task? _sseTask;
    private SseConnectionState _sseConnectionState = SseConnectionState.Disconnected;
    private string _sseStatusDetail = "Auto-receive is idle until this device registers with the server.";

    // Bluetooth scan state
    private bool _isScanning;
    private List<DeviceInformation> _discoveredBtDevices = new();
    private bool _isUpdatingTargetDeviceList;

    private static ReceiverStatus ParseReceiverStatus(string? status)
    {
        return status switch
        {
            "online" => ReceiverStatus.Online,
            "degraded" => ReceiverStatus.Degraded,
            _ => ReceiverStatus.Offline,
        };
    }

    private static string ReceiverStatusLabel(ReceiverStatus status)
    {
        return status switch
        {
            ReceiverStatus.Online => "Online",
            ReceiverStatus.Degraded => "Degraded",
            _ => "Offline",
        };
    }

    private static Brush ReceiverStatusBrush(ReceiverStatus status)
    {
        return status switch
        {
            ReceiverStatus.Online => new SolidColorBrush(Color.FromRgb(34, 197, 94)),
            ReceiverStatus.Degraded => new SolidColorBrush(Color.FromRgb(234, 179, 8)),
            _ => new SolidColorBrush(Color.FromRgb(239, 68, 68)),
        };
    }

    public MainWindow()
    {
        InitializeComponent();

        _configStore = new ConfigStore();
        _apiClient = new ApiClient(_configStore);
        _mdnsService = new MdnsDiscoveryService();
        _bluetoothService = new BluetoothService();
        _serverConfig = new ServerConfig();
        _serverProcess = new ServerProcess { Config = _serverConfig };

        // Wire up Bluetooth events
        _bluetoothService.SessionReady += OnBluetoothSessionReady;
        _bluetoothService.SessionHandshakeFailed += OnBluetoothHandshakeFailed;
        _bluetoothService.ConnectionFailed += OnBluetoothConnectionFailed;
        _bluetoothService.Connected += OnBluetoothConnected;
        _bluetoothService.ConnectionAccepted += OnBluetoothConnectionAccepted;
        _bluetoothService.TransferReceived += OnBluetoothTransferReceived;
        _bluetoothService.ReceiveProgress += OnBluetoothReceiveProgress;
        _bluetoothService.ReceiveFailed += OnBluetoothReceiveFailed;

        DataContext = _configStore;

        // PasswordBox doesn't support binding, so set manually
        AccessTokenBox.Password = _configStore.AccessToken;

        UpdateMainPanelState();
        UpdateDeviceInfoDisplay();
        UpdateAccessTokenVisibility();
        UpdateReceiverStatusUI();
        UpdateTargetDeviceStatusUI();
        FloatingBallCheckBox.IsChecked = _configStore.ShowFloatingBall;
        RefreshClipboardPreview();
        InitializeTransferModeUI();
        InitializeServerConfigUI();

        // Start mDNS discovery
        _mdnsService.ServersChanged += OnDiscoveredServersChanged;
        _mdnsService.StartBrowsing();

        // Auto-start embedded server if configured
        if (_serverConfig.ServerEnabled && _serverConfig.AutoStartServer)
        {
            SetServerEnabled(true);
        }
    }

    private void AccessTokenBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        _configStore.AccessToken = AccessTokenBox.Password;
    }

    private async void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(_configStore.HostUrl))
        {
            ShowStatus("Please enter a Host URL", isError: true);
            return;
        }

        _configStore.Save();
        ShowStatus("Configuration saved", isError: false);
        UpdateMainPanelState();

        // Register device with the server (best-effort)
        await RegisterDeviceAsync();
    }

    private async System.Threading.Tasks.Task RegisterDeviceAsync()
    {
        try
        {
            var name = Environment.MachineName;
            var result = await _apiClient.RegisterDeviceAsync(name, "windows");
            if (result != null && !string.IsNullOrEmpty(result.DeviceId))
            {
                _configStore.SaveDeviceConfig(result.DeviceId, name);
                UpdateDeviceInfoDisplay();
                // Restart SSE with new credentials
                StopSSE();
                StartSSE();
                _ = LoadDeviceListAsync();
            }
        }
        catch
        {
            // Registration is best-effort — don't block the save flow
        }
    }

    private void UpdateDeviceInfoDisplay()
    {
        if (!string.IsNullOrEmpty(_configStore.DeviceId))
        {
            DeviceInfoPanel.Visibility = Visibility.Visible;
            DeviceNameText.Text = _configStore.DeviceName;
            DeviceIdText.Text = _configStore.DeviceId;
        }
        else
        {
            DeviceInfoPanel.Visibility = Visibility.Collapsed;
        }

        UpdateReceiverStatusUI();
    }

    private void FloatingBallCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        var isChecked = FloatingBallCheckBox.IsChecked == true;
        _configStore.ShowFloatingBall = isChecked;
        _configStore.PersistConfig();
        FloatingBallVisibilityChanged?.Invoke(isChecked);
    }

    // --- Ctrl+V paste-to-send ---

    private async void PasteCommand_Executed(object sender, System.Windows.Input.ExecutedRoutedEventArgs e)
    {
        if (!_configStore.IsSendReady || SendService == null) return;

        e.Handled = true; // Prevent default paste into text inputs

        try
        {
            MaybeShowTargetFallbackWarningToast();

            // Priority order: text → image → file URL
            if (Clipboard.ContainsText())
            {
                var text = Clipboard.GetText();
                if (string.IsNullOrEmpty(text))
                {
                    ShowInWindowToast("Clipboard is empty");
                    return;
                }
                await SendService.SendTextAsync(text);
                var preview = text.Length > 40 ? text[..40] + "..." : text;
                ShowInWindowToast($"Sent: {preview}");
                return;
            }

            if (Clipboard.ContainsImage())
            {
                // Save image to temp file and send as file
                var image = Clipboard.GetImage();
                if (image != null)
                {
                    var tempPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "clipboard_image.png");
                    using (var fileStream = new FileStream(tempPath, FileMode.Create))
                    {
                        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
                        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(image));
                        encoder.Save(fileStream);
                    }
                    await SendService.SendFileAsync(tempPath);
                    ShowInWindowToast("Sent: clipboard image");
                    try { File.Delete(tempPath); } catch { }
                    return;
                }
            }

            if (Clipboard.ContainsFileDropList())
            {
                var files = Clipboard.GetFileDropList();
                foreach (string? filePath in files)
                {
                    if (filePath != null && File.Exists(filePath))
                    {
                        await SendService.SendFileAsync(filePath);
                        ShowInWindowToast($"Sent: {System.IO.Path.GetFileName(filePath)}");
                    }
                }
                return;
            }

            ShowInWindowToast("Clipboard is empty");
        }
        catch (Exception ex)
        {
            ShowInWindowToast($"Send failed: {ex.Message}");
        }
    }

    private System.Windows.Threading.DispatcherTimer? _toastTimer;

    private void ShowInWindowToast(string message)
    {
        ToastBannerText.Text = message;
        ToastBanner.Visibility = Visibility.Visible;

        _toastTimer?.Stop();
        _toastTimer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(3),
        };
        _toastTimer.Tick += (_, _) =>
        {
            ToastBanner.Visibility = Visibility.Collapsed;
            _toastTimer.Stop();
        };
        _toastTimer.Start();
    }

    // --- Window-level drag-and-drop ---

    private void Window_DragEnter(object sender, DragEventArgs e)
    {
        if (!_configStore.IsSendReady) return;
        if (e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent(DataFormats.UnicodeText) || e.Data.GetDataPresent(DataFormats.Text))
        {
            DropOverlay.Visibility = Visibility.Visible;
            e.Effects = DragDropEffects.Copy;
        }
        else
        {
            e.Effects = DragDropEffects.None;
        }
        e.Handled = true;
    }

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent(DataFormats.UnicodeText) || e.Data.GetDataPresent(DataFormats.Text))
        {
            e.Effects = DragDropEffects.Copy;
        }
        else
        {
            e.Effects = DragDropEffects.None;
        }
        e.Handled = true;
    }

    private void Window_DragLeave(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
    }

    private async void Window_Drop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;

        if (!_configStore.IsSendReady || SendService == null) return;

        MaybeShowTargetFallbackWarningToast();

        // Handle file drops
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            var files = (string[])e.Data.GetData(DataFormats.FileDrop);
            foreach (var filePath in files)
            {
                if (File.Exists(filePath))
                {
                    try
                    {
                        await SendService.SendFileAsync(filePath);
                    }
                    catch (Exception ex)
                    {
                        Services.SendService.ShowToast("Send failed", $"Failed to send: {ex.Message}");
                    }
                }
            }
            return;
        }

        // Handle text drops
        var text = e.Data.GetDataPresent(DataFormats.UnicodeText)
            ? (string?)e.Data.GetData(DataFormats.UnicodeText)
            : (string?)e.Data.GetData(DataFormats.Text);

        if (!string.IsNullOrEmpty(text))
        {
            try
            {
                await SendService.SendTextAsync(text);
            }
            catch (Exception ex)
            {
                Services.SendService.ShowToast("Send failed", $"Failed to send: {ex.Message}");
            }
        }
    }

    private async void TestConnectionButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(_configStore.HostUrl))
        {
            ShowStatus("Please enter a Host URL first", isError: true);
            return;
        }

        TestConnectionButton.IsEnabled = false;
        TestConnectionButton.Content = "Testing...";
        ShowStatus("Connecting...", isError: false);

        try
        {
            var result = await _apiClient.TestConnectionAsync();
            ShowStatus(result.Message, isError: !result.Success);
            UpdateAccessTokenVisibility();
        }
        finally
        {
            TestConnectionButton.IsEnabled = true;
            TestConnectionButton.Content = "Test Connection";
        }
    }

    private async void SendClipboardButton_Click(object sender, RoutedEventArgs e)
    {
        var clipboardText = GetClipboardText();
        if (string.IsNullOrEmpty(clipboardText))
        {
            ShowSendStatus("Clipboard is empty", isError: true);
            return;
        }

        SendClipboardButton.IsEnabled = false;
        SendClipboardButton.Content = "Sending...";
        ShowSendStatus("Uploading clipboard text...", isError: false);

        try
        {
            var targetSendWarning = TargetSendWarningMessage();
            if (targetSendWarning != null)
            {
                ShowSendStatus(targetSendWarning, isError: false);
            }
            else
            {
                ShowSendStatus("Uploading clipboard text...", isError: false);
            }

            var clip = await _apiClient.SendTextClipAsync(
                clipboardText,
                string.IsNullOrEmpty(_configStore.DeviceId) ? null : _configStore.DeviceId,
                string.IsNullOrEmpty(_configStore.TargetDeviceId) ? null : _configStore.TargetDeviceId);
            if (clip != null)
            {
                var expiresIn = clip.ExpiresAt.ToLocalTime().ToString("HH:mm:ss");
                var deliveryMessage = BuildDeliveryFeedbackMessage();
                ShowSendStatus($"Sent! Clip ID: {clip.Id}\nExpires at: {expiresIn}\n{deliveryMessage}", isError: false);
                _ = RefreshQueueAsync();
            }
            else
            {
                ShowSendStatus("Upload failed — no response from server", isError: true);
            }
        }
        catch (Exception ex)
        {
            ShowSendStatus($"Error: {ex.Message}", isError: true);
        }
        finally
        {
            SendClipboardButton.IsEnabled = true;
            SendClipboardButton.Content = "Send Clipboard";
        }
    }

    private async void ReceiveLatestButton_Click(object sender, RoutedEventArgs e)
    {
        ReceiveLatestButton.IsEnabled = false;
        ReceiveLatestButton.Content = "Receiving...";
        ShowReceiveStatus("Fetching latest clip...", isError: false);

        try
        {
            var clip = await _apiClient.GetLatestClipAsync();
            if (clip == null)
            {
                ShowReceiveStatus("No content available or expired", isError: true);
                return;
            }

            if (clip.Type != "text")
            {
                ShowReceiveStatus($"Latest clip is a {clip.Type} (ID: {clip.Id}), not text", isError: true);
                return;
            }

            var text = await _apiClient.GetClipRawTextAsync(clip.Id);
            if (text == null)
            {
                ShowReceiveStatus("Failed to download clip content", isError: true);
                return;
            }

            Clipboard.SetText(text);
            RefreshClipboardPreview();
            ShowReceiveStatus($"Copied to clipboard! (Clip ID: {clip.Id})", isError: false);

            ShowToastNotification("Copied to clipboard", $"Text from clip {clip.Id} has been copied to your clipboard.");
        }
        catch (Exception ex)
        {
            ShowReceiveStatus($"Error: {ex.Message}", isError: true);
        }
        finally
        {
            ReceiveLatestButton.IsEnabled = true;
            ReceiveLatestButton.Content = "Receive Latest";
        }
    }

    private async void FetchClipButton_Click(object sender, RoutedEventArgs e)
    {
        var clipId = ClipIdTextBox.Text.Trim();
        if (string.IsNullOrEmpty(clipId))
        {
            ShowReceiveStatus("Please enter a Clip ID", isError: true);
            return;
        }

        FetchClipButton.IsEnabled = false;
        FetchClipButton.Content = "Fetching...";
        ShowReceiveStatus($"Fetching clip {clipId}...", isError: false);

        try
        {
            var text = await _apiClient.GetClipRawTextAsync(clipId);
            if (text == null)
            {
                ShowReceiveStatus($"Clip {clipId} not found or expired", isError: true);
                return;
            }

            Clipboard.SetText(text);
            RefreshClipboardPreview();
            ShowReceiveStatus($"Copied to clipboard! (Clip ID: {clipId})", isError: false);

            ShowToastNotification("Copied to clipboard", $"Content from clip {clipId} has been copied to your clipboard.");
        }
        catch (Exception ex)
        {
            ShowReceiveStatus($"Error: {ex.Message}", isError: true);
        }
        finally
        {
            FetchClipButton.IsEnabled = true;
            FetchClipButton.Content = "Fetch";
        }
    }

    // --- File Upload ---

    private void DropZone_DragOver(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            e.Effects = DragDropEffects.Copy;
            DropZoneText.Text = "Drop to upload";
            DropZoneText.Foreground = new SolidColorBrush(Color.FromRgb(21, 128, 61));
        }
        else
        {
            e.Effects = DragDropEffects.None;
        }
        e.Handled = true;
    }

    private void DropZone_DragLeave(object sender, DragEventArgs e)
    {
        DropZoneText.Text = "Drop a file here";
        DropZoneText.Foreground = new SolidColorBrush(Colors.Gray);
    }

    private void DropZone_Drop(object sender, DragEventArgs e)
    {
        DropZoneText.Text = "Drop a file here";
        DropZoneText.Foreground = new SolidColorBrush(Colors.Gray);

        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            var files = (string[])e.Data.GetData(DataFormats.FileDrop);
            if (files.Length > 0 && File.Exists(files[0]))
            {
                _ = UploadFileAsync(files[0]);
            }
        }
    }

    private void ChooseFileButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Choose a file to upload",
            Filter = "All files (*.*)|*.*",
        };

        if (dialog.ShowDialog() == true)
        {
            _ = UploadFileAsync(dialog.FileName);
        }
    }

    private async System.Threading.Tasks.Task UploadFileAsync(string filePath)
    {
        var fileInfo = new FileInfo(filePath);
        _uploadCts = new CancellationTokenSource();

        ChooseFileButton.IsEnabled = false;
        UploadProgressPanel.Visibility = Visibility.Visible;
        UploadProgressBar.Value = 0;
        UploadProgressText.Text = "Starting upload...";

        var stopwatch = Stopwatch.StartNew();

        try
        {
            var targetSendWarning = TargetSendWarningMessage();
            if (targetSendWarning != null)
            {
                ShowFileUploadStatus(targetSendWarning, isError: false);
            }

            if (fileInfo.Length >= ChunkedThreshold)
            {
                _isChunkedUpload = true;
                _chunkedFilePath = filePath;
                ChunkedControlPanel.Visibility = Visibility.Visible;
                PauseUploadButton.Visibility = Visibility.Visible;
                ResumeUploadButton.Visibility = Visibility.Collapsed;

                await UploadChunkedAsync(filePath, fileInfo.Length, _uploadCts.Token);
            }
            else
            {
                _isChunkedUpload = false;
                ChunkedControlPanel.Visibility = Visibility.Collapsed;

                var progress = new Progress<(long sent, long total)>(p =>
                {
                    var pct = p.total > 0 ? (double)p.sent / p.total * 100 : 0;
                    UploadProgressBar.Value = pct;
                    var speed = stopwatch.Elapsed.TotalSeconds > 0
                        ? p.sent / stopwatch.Elapsed.TotalSeconds
                        : 0;
                    UploadProgressText.Text = $"{pct:F0}% — {FormatSpeed(speed)}";
                });

                var clip = await _apiClient.SendFileAsync(
                    filePath,
                    progress,
                    senderDeviceId: string.IsNullOrEmpty(_configStore.DeviceId) ? null : _configStore.DeviceId,
                    targetDeviceId: string.IsNullOrEmpty(_configStore.TargetDeviceId) ? null : _configStore.TargetDeviceId,
                    ct: _uploadCts.Token);
                if (clip != null)
                {
                    var expiresAt = clip.ExpiresAt.ToLocalTime().ToString("HH:mm:ss");
                    ShowFileUploadStatus($"Uploaded! Clip ID: {clip.Id}\nFile: {clip.Filename} ({FormatBytes(clip.SizeBytes)})\nExpires at: {expiresAt}\n{BuildDeliveryFeedbackMessage()}", isError: false);
                    _ = RefreshQueueAsync();
                }
            }
        }
        catch (OperationCanceledException)
        {
            ShowFileUploadStatus("Upload cancelled", isError: true);
        }
        catch (Exception ex)
        {
            ShowFileUploadStatus($"Upload error: {ex.Message}", isError: true);
        }
        finally
        {
            ChooseFileButton.IsEnabled = true;
            if (!_isChunkedUpload || _uploadCts?.IsCancellationRequested == true)
            {
                UploadProgressPanel.Visibility = Visibility.Collapsed;
                ChunkedControlPanel.Visibility = Visibility.Collapsed;
            }
        }
    }

    private async System.Threading.Tasks.Task UploadChunkedAsync(string filePath, long fileSize, CancellationToken ct)
    {
        var filename = Path.GetFileName(filePath);
        var totalChunks = (int)Math.Ceiling((double)fileSize / ChunkSize);

        ShowFileUploadStatus($"Initializing chunked upload ({totalChunks} chunks)...", isError: false);

        var initResult = await _apiClient.InitChunkedUploadAsync(
            filename,
            fileSize,
            ChunkSize,
            senderDeviceId: string.IsNullOrEmpty(_configStore.DeviceId) ? null : _configStore.DeviceId,
            targetDeviceId: string.IsNullOrEmpty(_configStore.TargetDeviceId) ? null : _configStore.TargetDeviceId,
            ct: ct);
        if (initResult == null)
        {
            ShowFileUploadStatus("Failed to initialize chunked upload", isError: true);
            return;
        }

        _chunkedUploadId = initResult.UploadId;
        await UploadChunksFromAsync(filePath, fileSize, _chunkedUploadId, totalChunks, startPart: 1, ct);
    }

    private async System.Threading.Tasks.Task UploadChunksFromAsync(string filePath, long fileSize, string uploadId, int totalChunks, int startPart, CancellationToken ct)
    {
        var stopwatch = Stopwatch.StartNew();

        using var fileStream = new FileStream(filePath, FileMode.Open, FileAccess.Read);

        for (int i = startPart; i <= totalChunks; i++)
        {
            ct.ThrowIfCancellationRequested();

            fileStream.Seek((long)(i - 1) * ChunkSize, SeekOrigin.Begin);
            var remaining = fileSize - fileStream.Position;
            var readSize = (int)Math.Min(ChunkSize, remaining);
            var buffer = new byte[readSize];
            await fileStream.ReadAsync(buffer, 0, readSize, ct);

            UploadProgressText.Text = $"Chunk {i}/{totalChunks}";

            await _apiClient.UploadChunkAsync(uploadId, i, buffer, ct);

            var overallPct = (double)i / totalChunks * 100;
            UploadProgressBar.Value = overallPct;

            var bytesUploaded = Math.Min((long)i * ChunkSize, fileSize);
            var speed = stopwatch.Elapsed.TotalSeconds > 0
                ? bytesUploaded / stopwatch.Elapsed.TotalSeconds
                : 0;
            UploadProgressText.Text = $"Chunk {i}/{totalChunks} — {overallPct:F0}% — {FormatSpeed(speed)}";
        }

        ShowFileUploadStatus("Finalizing upload...", isError: false);
        var clip = await _apiClient.CompleteChunkedUploadAsync(uploadId, ct);
        if (clip != null)
        {
            var expiresAt = clip.ExpiresAt.ToLocalTime().ToString("HH:mm:ss");
            ShowFileUploadStatus($"Uploaded! Clip ID: {clip.Id}\nFile: {clip.Filename} ({FormatBytes(clip.SizeBytes)})\nExpires at: {expiresAt}\n{BuildDeliveryFeedbackMessage()}", isError: false);
            _ = RefreshQueueAsync();
        }

        UploadProgressPanel.Visibility = Visibility.Collapsed;
        ChunkedControlPanel.Visibility = Visibility.Collapsed;
    }

    private void PauseUploadButton_Click(object sender, RoutedEventArgs e)
    {
        _uploadCts?.Cancel();
        PauseUploadButton.Visibility = Visibility.Collapsed;
        ResumeUploadButton.Visibility = Visibility.Visible;
        UploadProgressText.Text += " (Paused)";
        ShowFileUploadStatus("Upload paused", isError: false);
    }

    private async void ResumeUploadButton_Click(object sender, RoutedEventArgs e)
    {
        if (_chunkedUploadId == null || _chunkedFilePath == null) return;

        _uploadCts = new CancellationTokenSource();
        PauseUploadButton.Visibility = Visibility.Visible;
        ResumeUploadButton.Visibility = Visibility.Collapsed;

        try
        {
            var status = await _apiClient.GetUploadStatusAsync(_chunkedUploadId);
            if (status == null)
            {
                ShowFileUploadStatus("Upload not found on server", isError: true);
                return;
            }

            var fileInfo = new FileInfo(_chunkedFilePath);
            var totalChunks = (int)Math.Ceiling((double)fileInfo.Length / ChunkSize);
            var receivedParts = status.ReceivedParts.ToHashSet();
            var nextPart = 1;
            for (int i = 1; i <= totalChunks; i++)
            {
                if (!receivedParts.Contains(i))
                {
                    nextPart = i;
                    break;
                }
                if (i == totalChunks) nextPart = totalChunks + 1; // All done
            }

            if (nextPart > totalChunks)
            {
                // All chunks uploaded, just finalize
                var clip = await _apiClient.CompleteChunkedUploadAsync(_chunkedUploadId, _uploadCts.Token);
                if (clip != null)
                {
                    var expiresAt = clip.ExpiresAt.ToLocalTime().ToString("HH:mm:ss");
                    ShowFileUploadStatus($"Uploaded! Clip ID: {clip.Id}\nFile: {clip.Filename} ({FormatBytes(clip.SizeBytes)})\nExpires at: {expiresAt}\n{BuildDeliveryFeedbackMessage()}", isError: false);
                    _ = RefreshQueueAsync();
                }
                UploadProgressPanel.Visibility = Visibility.Collapsed;
                ChunkedControlPanel.Visibility = Visibility.Collapsed;
            }
            else
            {
                ShowFileUploadStatus($"Resuming from chunk {nextPart}/{totalChunks}...", isError: false);
                await UploadChunksFromAsync(_chunkedFilePath, fileInfo.Length, _chunkedUploadId, totalChunks, nextPart, _uploadCts.Token);
            }
        }
        catch (OperationCanceledException)
        {
            // Paused again
        }
        catch (Exception ex)
        {
            ShowFileUploadStatus($"Resume error: {ex.Message}", isError: true);
        }
        finally
        {
            ChooseFileButton.IsEnabled = true;
        }
    }

    // --- File Download ---

    private async void LookupClipButton_Click(object sender, RoutedEventArgs e)
    {
        var clipId = DownloadClipIdTextBox.Text.Trim();
        if (string.IsNullOrEmpty(clipId))
        {
            ShowDownloadStatus("Please enter a Clip ID", isError: true);
            return;
        }

        LookupClipButton.IsEnabled = false;
        LookupClipButton.Content = "Looking up...";
        FileMetadataBorder.Visibility = Visibility.Collapsed;

        try
        {
            var clip = await _apiClient.GetClipMetadataAsync(clipId);
            if (clip == null)
            {
                ShowDownloadStatus($"Clip {clipId} not found or expired", isError: true);
                return;
            }

            _downloadClipMetadata = clip;
            var createdAt = clip.CreatedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");
            FileMetadataText.Text = $"Filename: {clip.Filename ?? "(text)"}\nType: {clip.Type}\nSize: {FormatBytes(clip.SizeBytes)}\nUploaded: {createdAt}";
            FileMetadataBorder.Visibility = Visibility.Visible;
            DownloadStatusBorder.Visibility = Visibility.Collapsed;
        }
        catch (System.Net.Http.HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Forbidden)
        {
            ShowDownloadStatus("Upload incomplete — download unavailable", isError: true);
        }
        catch (Exception ex)
        {
            ShowDownloadStatus($"Error: {ex.Message}", isError: true);
        }
        finally
        {
            LookupClipButton.IsEnabled = true;
            LookupClipButton.Content = "Lookup";
        }
    }

    private async void DownloadFileButton_Click(object sender, RoutedEventArgs e)
    {
        if (_downloadClipMetadata == null) return;

        var suggestedName = _downloadClipMetadata.Filename ?? $"clip_{_downloadClipMetadata.Id}";
        var dialog = new SaveFileDialog
        {
            Title = "Save file",
            FileName = suggestedName,
            Filter = "All files (*.*)|*.*",
        };

        if (dialog.ShowDialog() != true) return;

        var savePath = dialog.FileName;
        DownloadFileButton.IsEnabled = false;
        DownloadProgressPanel.Visibility = Visibility.Visible;
        DownloadProgressBar.Value = 0;
        DownloadProgressText.Text = "Starting download...";

        var stopwatch = Stopwatch.StartNew();

        try
        {
            var progress = new Progress<(long received, long total)>(p =>
            {
                var pct = p.total > 0 ? (double)p.received / p.total * 100 : 0;
                DownloadProgressBar.Value = pct;
                var speed = stopwatch.Elapsed.TotalSeconds > 0
                    ? p.received / stopwatch.Elapsed.TotalSeconds
                    : 0;
                DownloadProgressText.Text = $"{pct:F0}% — {FormatSpeed(speed)}";
            });

            await _apiClient.DownloadFileAsync(_downloadClipMetadata.Id, savePath, progress);

            DownloadProgressPanel.Visibility = Visibility.Collapsed;
            ShowDownloadStatus($"Downloaded to {Path.GetFileName(savePath)}", isError: false);

            // Open Explorer and select the file
            Process.Start("explorer.exe", $"/select,\"{savePath}\"");
        }
        catch (System.Net.Http.HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Forbidden)
        {
            DownloadProgressPanel.Visibility = Visibility.Collapsed;
            ShowDownloadStatus("Upload incomplete — download unavailable", isError: true);
        }
        catch (Exception ex)
        {
            DownloadProgressPanel.Visibility = Visibility.Collapsed;
            ShowDownloadStatus($"Download error: {ex.Message}", isError: true);
        }
        finally
        {
            DownloadFileButton.IsEnabled = true;
        }
    }

    // --- Server Queue ---

    private void StartQueuePolling()
    {
        _queueTimer?.Stop();
        _queueTimer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(5),
        };
        _queueTimer.Tick += async (_, _) => await RefreshQueueAsync();
        _queueTimer.Start();
        _ = RefreshQueueAsync();
    }

    private void StopQueuePolling()
    {
        _queueTimer?.Stop();
    }

    private async System.Threading.Tasks.Task RefreshQueueAsync()
    {
        if (!_configStore.IsConfigured || string.IsNullOrEmpty(_configStore.DeviceId)) return;

        try
        {
            var items = await _apiClient.GetQueueAsync(_configStore.DeviceId);
            RenderQueueList(items);
        }
        catch
        {
            // Best effort — don't crash on transient failures
        }
    }

    private void RenderQueueList(System.Collections.Generic.List<ClipResponse> items)
    {
        QueueListPanel.Children.Clear();

        if (items.Count == 0)
        {
            QueueListPanel.Children.Add(new TextBlock
            {
                Text = "Queue mode is empty \u2014 send something to make it available for manual receive.",
                Foreground = new SolidColorBrush(Colors.Gray),
                FontSize = 12,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 8, 0, 8),
            });
            return;
        }

        foreach (var item in items)
        {
            var row = CreateQueueRow(item);
            QueueListPanel.Children.Add(row);
        }
    }

    private Border CreateQueueRow(ClipResponse item)
    {
        // Type icon
        var typeIcon = new TextBlock
        {
            Text = item.Type switch { "text" => "\ud83d\udcdd", "image" => "\ud83d\uddbc\ufe0f", _ => "\ud83d\udcce" },
            FontSize = 14,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0),
        };

        var preview = item.Filename ?? item.Type;
        if (preview.Length > 60) preview = preview[..60] + "...";

        var previewText = new TextBlock
        {
            Text = preview,
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 180,
        };

        var metadataText = new TextBlock
        {
            Text = item.DeliveryState == "targeted_fallback"
                ? "Automatic delivery missed; click Receive to recover"
                : $"{FormatBytes(item.SizeBytes)} • {FormatAge(item.CreatedAt)}",
            FontSize = 11,
            Foreground = new SolidColorBrush(Colors.Gray),
            Margin = new Thickness(0, 2, 0, 0),
        };

        var detailsPanel = new StackPanel();
        detailsPanel.Children.Add(previewText);
        if (item.DeliveryState == "targeted_fallback")
        {
            detailsPanel.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromRgb(255, 237, 213)),
                CornerRadius = new CornerRadius(999),
                Padding = new Thickness(6, 2, 6, 2),
                Margin = new Thickness(0, 4, 0, 0),
                Child = new TextBlock
                {
                    Text = "Queue fallback",
                    FontSize = 10,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = new SolidColorBrush(Color.FromRgb(194, 65, 12)),
                }
            });
        }
        detailsPanel.Children.Add(metadataText);

        var leftPanel = new StackPanel { Orientation = Orientation.Horizontal };
        leftPanel.Children.Add(typeIcon);
        leftPanel.Children.Add(detailsPanel);

        // Receive button
        var receiveButton = new Button
        {
            Content = "Receive",
            Width = 65,
            Height = 24,
            FontSize = 11,
            Tag = item,
        };
        receiveButton.Click += QueueReceiveButton_Click;

        var rowGrid = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(receiveButton, Dock.Right);
        rowGrid.Children.Add(receiveButton);
        rowGrid.Children.Add(leftPanel);

        return new Border
        {
            BorderBrush = new SolidColorBrush(Color.FromRgb(230, 230, 230)),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(4, 6, 4, 6),
            Child = rowGrid,
        };
    }

    private async void QueueReceiveButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.Tag is not ClipResponse item) return;

        button.IsEnabled = false;
        button.Content = "...";

        try
        {
            if (item.Type == "file")
            {
                // Save file to Downloads
                var downloadsPath = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
                var savePath = Path.Combine(downloadsPath, item.Filename ?? $"clip_{item.Id}");

                var success = await _apiClient.ConsumeClipToFileAsync(item.Id, savePath, _configStore.DeviceId);
                if (success)
                {
                    ShowToastNotification("File saved", $"Saved {Path.GetFileName(savePath)} to Downloads");
                }
                else
                {
                    ShowToastNotification("Already consumed", "This clip was already received by another device.");
                }
            }
            else
            {
                // Text or image — write to clipboard
                var result = await _apiClient.ConsumeClipRawAsync(item.Id, _configStore.DeviceId);
                if (result != null)
                {
                    var (data, contentType) = result.Value;
                    if (contentType != null && contentType.StartsWith("image/"))
                    {
                        using var ms = new System.IO.MemoryStream(data);
                        var bitmap = new System.Windows.Media.Imaging.BitmapImage();
                        bitmap.BeginInit();
                        bitmap.StreamSource = ms;
                        bitmap.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
                        bitmap.EndInit();
                        Clipboard.SetImage(bitmap);
                        ShowToastNotification("Image received", "Image copied to clipboard");
                    }
                    else
                    {
                        var text = System.Text.Encoding.UTF8.GetString(data);
                        Clipboard.SetText(text);
                        ShowToastNotification("Text received", "Text copied to clipboard");
                    }
                }
                else
                {
                    ShowToastNotification("Already consumed", "This clip was already received by another device.");
                }
            }
        }
        catch (Exception ex)
        {
            ShowToastNotification("Receive failed", ex.Message);
        }

        // Refresh queue to remove the consumed item
        await RefreshQueueAsync();
    }

    // --- Target Device & SSE ---

    private void TargetDeviceComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isUpdatingTargetDeviceList)
        {
            return;
        }

        if (TargetDeviceComboBox.SelectedIndex <= 0)
        {
            _configStore.TargetDeviceId = "";
            _configStore.TargetDeviceReceiverStatus = ReceiverStatus.Offline;
        }
        else if (TargetDeviceComboBox.SelectedItem is ComboBoxItem item && item.Tag is string deviceId)
        {
            _configStore.TargetDeviceId = deviceId;
            _configStore.TargetDeviceReceiverStatus = item.DataContext is DeviceInfo device
                ? ParseReceiverStatus(device.ReceiverStatus)
                : ReceiverStatus.Offline;
        }
        _configStore.PersistConfig();
        UpdateTargetDeviceStatusUI();
    }

    private async System.Threading.Tasks.Task LoadDeviceListAsync()
    {
        if (!_configStore.IsConfigured) return;

        try
        {
            _isUpdatingTargetDeviceList = true;
            var devices = await _apiClient.GetDevicesAsync();
            TargetDeviceComboBox.Items.Clear();
            TargetDeviceComboBox.Items.Add(new ComboBoxItem { Content = "(Queue mode \u2014 any device)", Tag = "" });

            var selectedIndex = 0;
            var index = 1;
            foreach (var device in devices)
            {
                if (device.Id == _configStore.DeviceId) continue; // Exclude self
                var platformIcon = device.Platform switch
                {
                    "macos" => "\U0001F34E",
                    "windows" => "\U0001FA9F",
                    _ => "\U0001F4BB",
                };
                var receiverStatus = ParseReceiverStatus(device.ReceiverStatus);
                var statusBrush = ReceiverStatusBrush(receiverStatus);
                var statusLabel = ReceiverStatusLabel(receiverStatus);
                var item = new ComboBoxItem
                {
                    Content = new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Children =
                        {
                            new TextBlock
                            {
                                Text = platformIcon,
                                Margin = new Thickness(0, 0, 6, 0),
                                VerticalAlignment = VerticalAlignment.Center,
                            },
                            new TextBlock
                            {
                                Text = "\u25CF",
                                Foreground = statusBrush,
                                Margin = new Thickness(0, 0, 6, 0),
                                VerticalAlignment = VerticalAlignment.Center,
                            },
                            new TextBlock
                            {
                                Text = $"{device.Name} ({device.Id})",
                                VerticalAlignment = VerticalAlignment.Center,
                            },
                            new TextBlock
                            {
                                Text = $" {statusLabel}",
                                Foreground = statusBrush,
                                FontWeight = FontWeights.SemiBold,
                                VerticalAlignment = VerticalAlignment.Center,
                            }
                        }
                    },
                    Tag = device.Id,
                    DataContext = device,
                };
                TargetDeviceComboBox.Items.Add(item);
                if (device.Id == _configStore.TargetDeviceId)
                    selectedIndex = index;
                index++;
            }
            TargetDeviceComboBox.SelectedIndex = selectedIndex;
            if (selectedIndex <= 0)
            {
                if (!string.IsNullOrEmpty(_configStore.TargetDeviceId))
                {
                    _configStore.TargetDeviceId = "";
                    _configStore.PersistConfig();
                }
                _configStore.TargetDeviceReceiverStatus = ReceiverStatus.Offline;
            }
            else if (TargetDeviceComboBox.SelectedItem is ComboBoxItem selectedItem && selectedItem.DataContext is DeviceInfo selectedDevice)
            {
                _configStore.TargetDeviceReceiverStatus = ParseReceiverStatus(selectedDevice.ReceiverStatus);
            }
            UpdateTargetDeviceStatusUI();
        }
        catch
        {
            // Best effort
        }
        finally
        {
            _isUpdatingTargetDeviceList = false;
        }
    }

    private void UpdateTargetDeviceStatusUI()
    {
        if (string.IsNullOrEmpty(_configStore.TargetDeviceId))
        {
            TargetDeviceStatusBorder.Visibility = Visibility.Visible;
            TargetDeviceStatusBorder.Background = new SolidColorBrush(Color.FromRgb(243, 244, 246));
            TargetDeviceStatusText.Foreground = new SolidColorBrush(Color.FromRgb(75, 85, 99));
            TargetDeviceStatusDetailText.Foreground = new SolidColorBrush(Color.FromRgb(75, 85, 99));
            TargetDeviceStatusText.Text = "Delivery mode: Queue mode";
            TargetDeviceStatusDetailText.Text = "Clips stay available for manual receive on any device.";
            return;
        }

        var status = _configStore.TargetDeviceReceiverStatus;
        var brush = ReceiverStatusBrush(status);
        var isOnline = status == ReceiverStatus.Online;
        var background = isOnline
            ? new SolidColorBrush(Color.FromRgb(220, 252, 231))
            : status == ReceiverStatus.Degraded
                ? new SolidColorBrush(Color.FromRgb(254, 249, 195))
                : new SolidColorBrush(Color.FromRgb(254, 226, 226));

        TargetDeviceStatusBorder.Visibility = Visibility.Visible;
        TargetDeviceStatusBorder.Background = background;
        TargetDeviceStatusText.Foreground = brush;
        TargetDeviceStatusDetailText.Foreground = brush;
        TargetDeviceStatusText.Text = "Delivery mode: Targeted auto-delivery";
        TargetDeviceStatusDetailText.Text = isOnline
            ? "The selected device looks ready. This clip will wait for that device to auto-receive first."
            : "Automatic delivery may miss this device and then fall back into the queue.";
    }

    private string? TargetSendWarningMessage()
    {
        return _configStore.TargetDeviceReceiverStatus switch
        {
            ReceiverStatus.Degraded when !string.IsNullOrEmpty(_configStore.TargetDeviceId) =>
                "Targeted auto-delivery is degraded. This send may fall back to queue recovery instead of auto-delivering.",
            ReceiverStatus.Offline when !string.IsNullOrEmpty(_configStore.TargetDeviceId) =>
                "Targeted auto-delivery is offline. This send will likely fall back to queue recovery instead of auto-delivering.",
            _ => null,
        };
    }

    private void MaybeShowTargetFallbackWarningToast()
    {
        var warning = TargetSendWarningMessage();
        if (warning != null)
        {
            ShowInWindowToast(warning);
        }
    }

    private string BuildDeliveryFeedbackMessage()
    {
        if (string.IsNullOrEmpty(_configStore.TargetDeviceId))
        {
            return "Queue mode: available for manual receive on any device.";
        }

        return _configStore.TargetDeviceReceiverStatus switch
        {
            ReceiverStatus.Online => "Targeted auto-delivery: waiting for the selected device to auto-receive.",
            ReceiverStatus.Degraded => "Targeted auto-delivery: the selected device may miss and fall back to queue recovery.",
            _ => "Targeted auto-delivery: the selected device is offline, so queue fallback is likely.",
        };
    }

    public void StartSSE()
    {
        if (_sseTask != null) return; // Already running
        if (!_configStore.IsConfigured || string.IsNullOrEmpty(_configStore.DeviceId)) return;

        LogSseDiagnostic("starting receiver channel");
        _sseCts = new CancellationTokenSource();
        SetSseConnectionState(
            SseConnectionState.Reconnecting,
            "Connecting receiver channel for targeted auto-delivery...");
        _sseTask = SSELoopAsync(_sseCts.Token);
    }

    public void StopSSE()
    {
        _sseCts?.Cancel();
        _sseTask = null;
        LogSseDiagnostic("receiver channel stopped");
        SetSseConnectionState(SseConnectionState.Disconnected, CurrentDisconnectedSseDetail());
    }

    private async System.Threading.Tasks.Task SSELoopAsync(CancellationToken ct)
    {
        var backoff = TimeSpan.FromSeconds(1);
        var maxBackoff = TimeSpan.FromSeconds(30);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var baseUrl = _configStore.HostUrl.TrimEnd('/');
                var url = $"{baseUrl}/api/v1/devices/{_configStore.DeviceId}/stream";

                using var client = new System.Net.Http.HttpClient { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
                if (!string.IsNullOrWhiteSpace(_configStore.AccessToken))
                {
                    client.DefaultRequestHeaders.Authorization =
                        new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _configStore.AccessToken);
                }

                using var response = await client.GetAsync(url, System.Net.Http.HttpCompletionOption.ResponseHeadersRead, ct);
                response.EnsureSuccessStatusCode();

                using var stream = await response.Content.ReadAsStreamAsync(ct);
                using var reader = new StreamReader(stream);

                backoff = TimeSpan.FromSeconds(1); // Reset on successful connection
                LogSseDiagnostic("receiver channel connected");
                SetSseConnectionState(
                    SseConnectionState.Connected,
                    "Receiver channel connected. This device is ready for targeted auto-delivery.");
                var eventType = "";
                var eventData = "";

                while (!ct.IsCancellationRequested)
                {
                    var line = await reader.ReadLineAsync();
                    if (line == null)
                    {
                        throw new IOException("Receiver channel closed unexpectedly.");
                    }

                    if (line.StartsWith("event:"))
                    {
                        eventType = line[6..].Trim();
                    }
                    else if (line.StartsWith("data:"))
                    {
                        eventData = line[5..].Trim();
                    }
                    else if (line == "" && !string.IsNullOrEmpty(eventType))
                    {
                        if (eventType == "clip" && !string.IsNullOrEmpty(eventData))
                        {
                            _ = HandleSSEClipEvent(eventData);
                        }
                        eventType = "";
                        eventData = "";
                    }
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                if (ct.IsCancellationRequested) break;

                var retryDelay = backoff;
                var reason = string.IsNullOrWhiteSpace(ex.Message)
                    ? "connection dropped"
                    : ex.Message;
                LogSseDiagnostic($"receiver channel disconnected: {reason}. retrying in {FormatRetryDelay(retryDelay)}");
                SetSseConnectionState(
                    SseConnectionState.Reconnecting,
                    $"Receiver channel offline: {reason} Retrying in {FormatRetryDelay(retryDelay)}.");
            }

            if (ct.IsCancellationRequested) break;

            await System.Threading.Tasks.Task.Delay(backoff, ct).ContinueWith(_ => { });
            backoff = TimeSpan.FromSeconds(Math.Min(backoff.TotalSeconds * 2, maxBackoff.TotalSeconds));
        }

        if (ct.IsCancellationRequested)
        {
            SetSseConnectionState(SseConnectionState.Disconnected, CurrentDisconnectedSseDetail());
        }
    }

    private async System.Threading.Tasks.Task HandleSSEClipEvent(string jsonData)
    {
        try
        {
            var clipEvent = System.Text.Json.JsonSerializer.Deserialize<SSEClipEvent>(jsonData);
            if (clipEvent == null) return;

            var clipId = clipEvent.ClipId;
            var type = clipEvent.Type;
            var filename = clipEvent.Filename;

            if (type == "file")
            {
                var savePath = BuildUniqueDownloadsPath(filename ?? $"clip_{clipId}");

                var success = await _apiClient.ConsumeClipToFileAsync(clipId, savePath, _configStore.DeviceId);
                if (success)
                {
                    Dispatcher.Invoke(() =>
                        ShowToastNotification("File received", $"Saved {Path.GetFileName(savePath)} to Downloads"));
                }
                else
                {
                    LogSseDiagnostic($"targeted clip {clipId} was already consumed before auto-receive completed");
                }
            }
            else
            {
                var result = await _apiClient.ConsumeClipRawAsync(clipId, _configStore.DeviceId);
                if (result != null)
                {
                    var (data, contentType) = result.Value;
                    Dispatcher.Invoke(() =>
                    {
                        if (contentType != null && contentType.StartsWith("image/"))
                        {
                            using var ms = new System.IO.MemoryStream(data);
                            var bitmap = new System.Windows.Media.Imaging.BitmapImage();
                            bitmap.BeginInit();
                            bitmap.StreamSource = ms;
                            bitmap.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
                            bitmap.EndInit();
                            Clipboard.SetImage(bitmap);
                            ShowToastNotification("Image received", "Image copied to clipboard");
                        }
                        else
                        {
                            var text = System.Text.Encoding.UTF8.GetString(data);
                            Clipboard.SetText(text);
                            ShowToastNotification("Text received", "Text copied to clipboard");
                        }
                    });
                }
                else
                {
                    LogSseDiagnostic($"targeted clip {clipId} was already consumed before auto-receive completed");
                }
            }

            // Refresh queue after receiving
            Dispatcher.Invoke(() => _ = RefreshQueueAsync());
        }
        catch (Exception ex)
        {
            LogSseDiagnostic($"targeted auto-receive failed: {ex.Message}");
            ShowTargetedAutoReceiveFallbackWarning("targeted clip");
        }
    }

    private void ShowTargetedAutoReceiveFallbackWarning(string clipLabel)
    {
        Dispatcher.Invoke(() =>
        {
            ShowToastNotification(
                "Targeted auto-delivery fell back to queue",
                $"Couldn't auto-receive {clipLabel}. It remains available in queue recovery for manual receive.");
            _ = RefreshQueueAsync();
        });
    }

    private static string BuildUniqueDownloadsPath(string filename)
    {
        var downloadsPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        var savePath = Path.Combine(downloadsPath, filename);

        if (!File.Exists(savePath))
        {
            return savePath;
        }

        var ext = Path.GetExtension(savePath);
        var nameWithoutExt = Path.GetFileNameWithoutExtension(savePath);
        var counter = 1;
        do
        {
            savePath = Path.Combine(downloadsPath, $"{nameWithoutExt} ({counter}){ext}");
            counter++;
        } while (File.Exists(savePath));

        return savePath;
    }

    private static void LogSseDiagnostic(string message)
    {
        Debug.WriteLine($"[SSE] {message}");
    }

    // --- Bluetooth ---

    private void InitializeTransferModeUI()
    {
        // Set combo box to current transfer mode
        TransferModeComboBox.SelectedIndex = _configStore.TransferMode == TransferMode.Bluetooth ? 1 : 0;
        UpdateBluetoothSectionVisibility();
        RenderPairedDevices();

        // Start RFCOMM server if already in Bluetooth mode (for receiving inbound connections)
        if (_configStore.TransferMode == TransferMode.Bluetooth)
        {
            StartBluetoothServerIfNeeded();
        }
    }

    private void TransferModeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (TransferModeComboBox.SelectedItem is not ComboBoxItem item) return;
        var tag = item.Tag as string;

        var newMode = tag == "Bluetooth" ? TransferMode.Bluetooth : TransferMode.LanServer;
        if (newMode == _configStore.TransferMode) return;

        _configStore.TransferMode = newMode;
        _configStore.PersistConfig();
        UpdateBluetoothSectionVisibility();

        if (newMode == TransferMode.Bluetooth)
        {
            // Stop LAN services, start Bluetooth
            StopSSE();
            StopQueuePolling();
            StartBluetoothServerIfNeeded();
        }
        else
        {
            // Stop Bluetooth, restart LAN services
            _bluetoothService.StopServer();
            if (_configStore.IsConfigured)
            {
                StartSSE();
                StartQueuePolling();
                _ = RefreshQueueAsync();
            }
        }
        UpdateMainPanelState();
    }

    private void UpdateBluetoothSectionVisibility()
    {
        BluetoothSection.Visibility = _configStore.TransferMode == TransferMode.Bluetooth
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void UpdateBluetoothStatus()
    {
        Dispatcher.Invoke(() =>
        {
            switch (_configStore.BluetoothConnectionStatus)
            {
                case BluetoothConnectionStatus.Disconnected:
                    BtStatusIcon.Foreground = Brushes.Gray;
                    BtStatusText.Text = "Disconnected";
                    break;
                case BluetoothConnectionStatus.Connecting:
                    BtStatusIcon.Foreground = new SolidColorBrush(Color.FromRgb(234, 179, 8)); // yellow
                    BtStatusText.Text = "Connecting...";
                    break;
                case BluetoothConnectionStatus.Connected:
                    BtStatusIcon.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94)); // green
                    BtStatusText.Text = _configStore.BluetoothConnectedDeviceName != null
                        ? $"Connected to {_configStore.BluetoothConnectedDeviceName}"
                        : "Connected";
                    break;
                case BluetoothConnectionStatus.Error:
                    BtStatusIcon.Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68)); // red
                    BtStatusText.Text = "Error";
                    break;
            }

            if (_configStore.BluetoothConnectionStatus == BluetoothConnectionStatus.Error &&
                !string.IsNullOrEmpty(_configStore.BluetoothErrorMessage))
            {
                BtErrorBorder.Visibility = Visibility.Visible;
                BtErrorText.Text = _configStore.BluetoothErrorMessage;
            }
            else
            {
                BtErrorBorder.Visibility = Visibility.Collapsed;
            }

            RenderPairedDevices();
            if (_configStore.TransferMode == TransferMode.Bluetooth)
            {
                UpdateBtStatusPanel();
            }
        });
    }

    private void UpdateBtStatusPanel()
    {
        var status = _configStore.BluetoothConnectionStatus;

        SolidColorBrush dotColor;
        string statusText;
        System.Windows.Media.Color bgColor;

        switch (status)
        {
            case BluetoothConnectionStatus.Connected:
                dotColor = new SolidColorBrush(Color.FromRgb(34, 197, 94));
                statusText = "Connected";
                bgColor = Color.FromArgb(25, 34, 197, 94);
                break;
            case BluetoothConnectionStatus.Connecting:
                dotColor = new SolidColorBrush(Color.FromRgb(234, 179, 8));
                statusText = "Connecting\u2026";
                bgColor = Color.FromArgb(25, 234, 179, 8);
                break;
            case BluetoothConnectionStatus.Error:
                dotColor = new SolidColorBrush(Color.FromRgb(239, 68, 68));
                statusText = !string.IsNullOrEmpty(_configStore.BluetoothErrorMessage)
                    ? $"Error: {_configStore.BluetoothErrorMessage}"
                    : "Error";
                bgColor = Color.FromArgb(25, 239, 68, 68);
                break;
            default:
                dotColor = Brushes.Gray;
                statusText = "Disconnected";
                bgColor = Color.FromArgb(25, 128, 128, 128);
                break;
        }

        BtStatusDot.Fill = dotColor;
        BtStatusLabel.Text = statusText;
        BtStatusBadge.Background = new SolidColorBrush(bgColor);

        if (_configStore.BluetoothConnectedDeviceName != null)
        {
            BtConnectedDeviceText.Text = $"Connected to {_configStore.BluetoothConnectedDeviceName}";
            BtConnectedDeviceText.Visibility = Visibility.Visible;
        }
        else
        {
            BtConnectedDeviceText.Visibility = Visibility.Collapsed;
        }

        BtPairHintText.Visibility = !_configStore.IsSendReady ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RenderPairedDevices()
    {
        PairedDevicesPanel.Children.Clear();

        if (_configStore.PairedDevices.Count == 0)
        {
            PairedDevicesPanel.Children.Add(new TextBlock
            {
                Text = "No paired devices. Scan to find nearby devices.",
                Foreground = Brushes.Gray,
                FontSize = 11,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 10, 0, 10),
            });
            return;
        }

        foreach (var device in _configStore.PairedDevices)
        {
            var isConnected = _configStore.BluetoothConnectionStatus == BluetoothConnectionStatus.Connected
                && _configStore.BluetoothConnectedDeviceName == device.Name;

            var nameText = new TextBlock
            {
                Text = device.Name,
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
            };

            var addressText = new TextBlock
            {
                Text = device.AddressString,
                FontSize = 11,
                Foreground = Brushes.Gray,
            };

            var infoStack = new StackPanel { Margin = new Thickness(0, 0, 8, 0) };
            infoStack.Children.Add(nameText);
            infoStack.Children.Add(addressText);

            var buttonPanel = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center,
            };

            if (isConnected)
            {
                buttonPanel.Children.Add(new TextBlock
                {
                    Text = "\u2713",
                    FontSize = 14,
                    Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94)),
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(0, 0, 6, 0),
                });

                var disconnectBtn = new Button { Content = "Disconnect", Width = 80, Height = 24, FontSize = 11 };
                disconnectBtn.Click += (_, _) => DisconnectBluetooth();
                buttonPanel.Children.Add(disconnectBtn);
            }
            else
            {
                var connectBtn = new Button
                {
                    Content = "Connect",
                    Width = 70,
                    Height = 24,
                    FontSize = 11,
                    IsEnabled = _configStore.BluetoothConnectionStatus != BluetoothConnectionStatus.Connecting,
                };
                var capturedDevice = device;
                connectBtn.Click += (_, _) => ConnectToPairedDevice(capturedDevice);
                buttonPanel.Children.Add(connectBtn);
            }

            var forgetBtn = new Button
            {
                Content = "Forget",
                Width = 55,
                Height = 24,
                FontSize = 11,
                Foreground = new SolidColorBrush(Color.FromRgb(185, 28, 28)),
                Margin = new Thickness(4, 0, 0, 0),
            };
            var capturedAddr = device.Address;
            forgetBtn.Click += (_, _) => ForgetBluetoothDevice(capturedAddr);
            buttonPanel.Children.Add(forgetBtn);

            var row = new DockPanel { LastChildFill = true };
            DockPanel.SetDock(buttonPanel, Dock.Right);
            row.Children.Add(buttonPanel);
            row.Children.Add(infoStack);

            var border = new Border
            {
                BorderBrush = new SolidColorBrush(Color.FromRgb(230, 230, 230)),
                BorderThickness = new Thickness(0, 0, 0, 1),
                Padding = new Thickness(8, 6, 8, 6),
                Background = isConnected
                    ? new SolidColorBrush(Color.FromRgb(219, 234, 254))
                    : Brushes.Transparent,
                Child = row,
            };
            PairedDevicesPanel.Children.Add(border);
        }
    }

    private async void BtScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isScanning) return;

        _isScanning = true;
        BtScanButton.Content = "Scanning...";
        BtScanButton.IsEnabled = false;
        BtScanningPanel.Visibility = Visibility.Visible;
        BtScanErrorText.Visibility = Visibility.Collapsed;
        BtDiscoveredBorder.Visibility = Visibility.Collapsed;
        BtDiscoveredPanel.Children.Clear();

        try
        {
            var devices = await BluetoothService.FindDevicesAsync();
            _discoveredBtDevices = devices.ToList();

            if (_discoveredBtDevices.Count == 0)
            {
                BtDiscoveredBorder.Visibility = Visibility.Visible;
                BtDiscoveredPanel.Children.Add(new TextBlock
                {
                    Text = "No CopyEverywhere devices found.",
                    Foreground = Brushes.Gray,
                    FontSize = 11,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 10, 0, 10),
                });
            }
            else
            {
                BtDiscoveredBorder.Visibility = Visibility.Visible;
                RenderDiscoveredBtDevices();
            }
        }
        catch (Exception ex)
        {
            BtScanErrorText.Text = $"Scan failed: {ex.Message}";
            BtScanErrorText.Visibility = Visibility.Visible;
        }
        finally
        {
            _isScanning = false;
            BtScanButton.Content = "Scan";
            BtScanButton.IsEnabled = true;
            BtScanningPanel.Visibility = Visibility.Collapsed;
        }
    }

    private void RenderDiscoveredBtDevices()
    {
        BtDiscoveredPanel.Children.Clear();

        foreach (var device in _discoveredBtDevices)
        {
            var isPaired = _configStore.PairedDevices.Any(p => device.Name == p.Name);

            var nameText = new TextBlock
            {
                Text = device.Name ?? "(Unknown)",
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
            };

            var buttonPanel = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center,
            };

            if (isPaired)
            {
                buttonPanel.Children.Add(new TextBlock
                {
                    Text = "Paired",
                    FontSize = 11,
                    Foreground = Brushes.Gray,
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
            else
            {
                var pairBtn = new Button { Content = "Pair", Width = 55, Height = 24, FontSize = 11 };
                var capturedDevice = device;
                pairBtn.Click += (_, _) => PairBluetoothDevice(capturedDevice);
                buttonPanel.Children.Add(pairBtn);
            }

            var row = new DockPanel { LastChildFill = true };
            DockPanel.SetDock(buttonPanel, Dock.Right);
            row.Children.Add(buttonPanel);
            row.Children.Add(nameText);

            BtDiscoveredPanel.Children.Add(new Border
            {
                BorderBrush = new SolidColorBrush(Color.FromRgb(230, 230, 230)),
                BorderThickness = new Thickness(0, 0, 0, 1),
                Padding = new Thickness(8, 6, 8, 6),
                Child = row,
            });
        }
    }

    private async void PairBluetoothDevice(DeviceInformation deviceInfo)
    {
        _configStore.BluetoothConnectionStatus = BluetoothConnectionStatus.Connecting;
        _configStore.BluetoothErrorMessage = null;
        UpdateBluetoothStatus();

        try
        {
            // Attempt connection — this triggers the system pairing dialog if needed
            await _bluetoothService.ConnectAsync(deviceInfo);
        }
        catch (Exception ex)
        {
            _configStore.BluetoothConnectionStatus = BluetoothConnectionStatus.Error;
            _configStore.BluetoothErrorMessage = $"Pairing failed: {ex.Message}";
            UpdateBluetoothStatus();
        }
    }

    private async void ConnectToPairedDevice(PairedBluetoothDevice device)
    {
        _configStore.BluetoothConnectionStatus = BluetoothConnectionStatus.Connecting;
        _configStore.BluetoothErrorMessage = null;
        UpdateBluetoothStatus();

        try
        {
            await _bluetoothService.ConnectByAddressAsync(device.Address);
        }
        catch (Exception ex)
        {
            _configStore.BluetoothConnectionStatus = BluetoothConnectionStatus.Error;
            _configStore.BluetoothErrorMessage = $"Connection failed: {ex.Message}";
            UpdateBluetoothStatus();
        }
    }

    private void DisconnectBluetooth()
    {
        _bluetoothService.Disconnect();
        _configStore.BluetoothConnectionStatus = BluetoothConnectionStatus.Disconnected;
        _configStore.BluetoothConnectedDeviceName = null;
        _configStore.BluetoothErrorMessage = null;
        UpdateBluetoothStatus();
    }

    private void ForgetBluetoothDevice(ulong address)
    {
        // If currently connected to this device, disconnect first
        if (_bluetoothService.ConnectedDevice != null)
        {
            try
            {
                // Compare by checking if the device is connected and matches
                var connectedName = _configStore.BluetoothConnectedDeviceName;
                var forgettingDevice = _configStore.PairedDevices.FirstOrDefault(d => d.Address == address);
                if (forgettingDevice != null && connectedName == forgettingDevice.Name)
                {
                    DisconnectBluetooth();
                }
            }
            catch { /* Best effort */ }
        }

        _configStore.RemovePairedDevice(address);
        RenderPairedDevices();
        RenderDiscoveredBtDevices();
    }

    // Bluetooth event handlers

    private void OnBluetoothSessionReady(BluetoothSession session)
    {
        Dispatcher.Invoke(() =>
        {
            var deviceName = _bluetoothService.ConnectedDevice?.Name ?? "Unknown Device";
            _configStore.BluetoothConnectedDeviceName = deviceName;
            _configStore.BluetoothConnectionStatus = BluetoothConnectionStatus.Connected;
            _configStore.BluetoothErrorMessage = null;

            // Add to paired devices if not already there
            if (_bluetoothService.ConnectedDevice != null)
            {
                var btDevice = _bluetoothService.ConnectedDevice;
                var address = btDevice.BluetoothAddress;
                var addressStr = FormatBluetoothAddress(address);

                _configStore.AddPairedDevice(new PairedBluetoothDevice
                {
                    Name = btDevice.Name ?? "Unknown",
                    Address = address,
                    AddressString = addressStr,
                });
            }

            UpdateBluetoothStatus();
        });
    }

    private void OnBluetoothHandshakeFailed(Exception ex)
    {
        Dispatcher.Invoke(() =>
        {
            _configStore.BluetoothConnectionStatus = BluetoothConnectionStatus.Error;
            _configStore.BluetoothErrorMessage = $"Handshake failed: {ex.Message}";
            UpdateBluetoothStatus();
        });
    }

    private void OnBluetoothConnectionFailed(Exception ex)
    {
        Dispatcher.Invoke(() =>
        {
            _configStore.BluetoothConnectionStatus = BluetoothConnectionStatus.Error;
            _configStore.BluetoothErrorMessage = $"Connection failed: {ex.Message}";
            UpdateBluetoothStatus();
        });
    }

    private void OnBluetoothConnected(Windows.Networking.Sockets.StreamSocket socket, Windows.Devices.Bluetooth.BluetoothDevice? device)
    {
        // Session creation is automatic — SessionReady will fire on handshake success
    }

    private void OnBluetoothConnectionAccepted(Windows.Networking.Sockets.StreamSocket socket, Windows.Devices.Bluetooth.BluetoothDevice? device)
    {
        // Session creation is automatic — SessionReady will fire on handshake success
    }

    private void OnBluetoothSendProgress(double progress)
    {
        Dispatcher.Invoke(() =>
        {
            if (progress < 1.0)
            {
                UploadProgressPanel.Visibility = Visibility.Visible;
                UploadProgressBar.Value = progress * 100;
                UploadProgressText.Text = $"Bluetooth send — {progress * 100:F0}%";
            }
            else
            {
                UploadProgressPanel.Visibility = Visibility.Collapsed;
            }
        });
    }

    private void OnBluetoothReceiveProgress(double progress, BluetoothTransferHeader header)
    {
        Dispatcher.Invoke(() =>
        {
            if (progress < 1.0)
            {
                BtReceiveProgressPanel.Visibility = Visibility.Visible;
                BtReceiveProgressBar.Value = progress * 100;
                var label = header.Type == BluetoothContentType.File
                    ? $"Receiving {header.Filename} — {progress * 100:F0}%"
                    : $"Receiving text — {progress * 100:F0}%";
                BtReceiveProgressText.Text = label;
            }
            else
            {
                BtReceiveProgressPanel.Visibility = Visibility.Collapsed;
            }
        });
    }

    private void OnBluetoothTransferReceived(BluetoothSession session, BluetoothTransferPayload payload)
    {
        Dispatcher.Invoke(() =>
        {
            BtReceiveProgressPanel.Visibility = Visibility.Collapsed;

            if (payload.Header.Type == BluetoothContentType.Text)
            {
                var text = System.Text.Encoding.UTF8.GetString(payload.Data);
                Clipboard.SetText(text);
                RefreshClipboardPreview();
                ShowToastNotification("Received text", $"Received text ({payload.Data.Length} chars) — copied to clipboard");
            }
            else
            {
                // Save file to Downloads folder
                var downloadsPath = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
                var savePath = Path.Combine(downloadsPath, payload.Header.Filename);

                // Avoid overwriting — append (1), (2), etc. if file exists
                if (File.Exists(savePath))
                {
                    var ext = Path.GetExtension(savePath);
                    var nameWithoutExt = Path.GetFileNameWithoutExtension(savePath);
                    var counter = 1;
                    do
                    {
                        savePath = Path.Combine(downloadsPath, $"{nameWithoutExt} ({counter}){ext}");
                        counter++;
                    } while (File.Exists(savePath));
                }

                File.WriteAllBytes(savePath, payload.Data);

                // Verify byte count matches header
                var written = new FileInfo(savePath).Length;
                if (written != payload.Header.Size)
                {
                    ShowToastNotification("Receive warning",
                        $"Size mismatch for {payload.Header.Filename}: expected {payload.Header.Size} bytes, got {written}");
                }
                else
                {
                    ShowToastNotification("Received file",
                        $"Saved {Path.GetFileName(savePath)} to Downloads");
                }
            }
        });
    }

    private void OnBluetoothReceiveFailed(Exception ex)
    {
        Dispatcher.Invoke(() =>
        {
            BtReceiveProgressPanel.Visibility = Visibility.Collapsed;
            ShowToastNotification("Bluetooth receive failed", ex.Message);
        });
    }

    private async void StartBluetoothServerIfNeeded()
    {
        if (_bluetoothService.IsServerRunning) return;
        try
        {
            await _bluetoothService.StartServerAsync();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Failed to start Bluetooth RFCOMM server: {ex.Message}");
        }
    }

    private static string FormatBluetoothAddress(ulong address)
    {
        var bytes = BitConverter.GetBytes(address);
        return $"{bytes[5]:X2}:{bytes[4]:X2}:{bytes[3]:X2}:{bytes[2]:X2}:{bytes[1]:X2}:{bytes[0]:X2}";
    }

    // --- Helpers ---

    private static string FormatBytes(long bytes)
    {
        string[] sizes = ["B", "KB", "MB", "GB"];
        double len = bytes;
        int order = 0;
        while (len >= 1024 && order < sizes.Length - 1)
        {
            order++;
            len /= 1024;
        }
        return $"{len:F1} {sizes[order]}";
    }

    private static string FormatAge(DateTime createdAt)
    {
        var age = DateTime.UtcNow - createdAt;
        if (age.TotalMinutes < 1) return "just now";
        if (age.TotalHours < 1) return $"{(int)age.TotalMinutes}m ago";
        if (age.TotalDays < 1) return $"{(int)age.TotalHours}h ago";
        return $"{(int)age.TotalDays}d ago";
    }

    private static string FormatSpeed(double bytesPerSecond)
    {
        if (bytesPerSecond >= 1024 * 1024)
            return $"{bytesPerSecond / (1024 * 1024):F1} MB/s";
        if (bytesPerSecond >= 1024)
            return $"{bytesPerSecond / 1024:F1} KB/s";
        return $"{bytesPerSecond:F0} B/s";
    }

    private void ShowFileUploadStatus(string message, bool isError)
    {
        FileUploadStatusBorder.Visibility = Visibility.Visible;
        FileUploadStatusText.Text = message;

        if (isError)
        {
            FileUploadStatusBorder.Background = new SolidColorBrush(Color.FromRgb(254, 226, 226));
            FileUploadStatusText.Foreground = new SolidColorBrush(Color.FromRgb(185, 28, 28));
        }
        else
        {
            FileUploadStatusBorder.Background = new SolidColorBrush(Color.FromRgb(220, 252, 231));
            FileUploadStatusText.Foreground = new SolidColorBrush(Color.FromRgb(21, 128, 61));
        }
    }

    private void ShowDownloadStatus(string message, bool isError)
    {
        DownloadStatusBorder.Visibility = Visibility.Visible;
        DownloadStatusText.Text = message;

        if (isError)
        {
            DownloadStatusBorder.Background = new SolidColorBrush(Color.FromRgb(254, 226, 226));
            DownloadStatusText.Foreground = new SolidColorBrush(Color.FromRgb(185, 28, 28));
        }
        else
        {
            DownloadStatusBorder.Background = new SolidColorBrush(Color.FromRgb(220, 252, 231));
            DownloadStatusText.Foreground = new SolidColorBrush(Color.FromRgb(21, 128, 61));
        }
    }

    private void RefreshClipboardPreview()
    {
        var text = GetClipboardText();
        if (string.IsNullOrEmpty(text))
        {
            ClipboardPreviewText.Text = "(empty)";
            ClipboardPreviewText.Foreground = new SolidColorBrush(Colors.Gray);
            SendClipboardButton.IsEnabled = false;
        }
        else
        {
            var preview = text.Length > 500 ? text[..500] + "..." : text;
            ClipboardPreviewText.Text = preview;
            ClipboardPreviewText.Foreground = new SolidColorBrush(Colors.Black);
            SendClipboardButton.IsEnabled = true;
        }
    }

    private static string? GetClipboardText()
    {
        try
        {
            if (Clipboard.ContainsText())
                return Clipboard.GetText();
        }
        catch
        {
            // Clipboard may be locked by another process
        }
        return null;
    }

    private static void ShowToastNotification(string title, string message)
    {
        try
        {
            new ToastContentBuilder()
                .AddText(title)
                .AddText(message)
                .Show();
        }
        catch
        {
            // Toast notifications may not be available in all environments
        }
    }

    private void ShowStatus(string message, bool isError)
    {
        StatusBorder.Visibility = Visibility.Visible;
        StatusText.Text = message;

        if (isError)
        {
            StatusBorder.Background = new SolidColorBrush(Color.FromRgb(254, 226, 226));
            StatusText.Foreground = new SolidColorBrush(Color.FromRgb(185, 28, 28));
        }
        else
        {
            StatusBorder.Background = new SolidColorBrush(Color.FromRgb(220, 252, 231));
            StatusText.Foreground = new SolidColorBrush(Color.FromRgb(21, 128, 61));
        }
    }

    private void ShowSendStatus(string message, bool isError)
    {
        SendStatusBorder.Visibility = Visibility.Visible;
        SendStatusText.Text = message;

        if (isError)
        {
            SendStatusBorder.Background = new SolidColorBrush(Color.FromRgb(254, 226, 226));
            SendStatusText.Foreground = new SolidColorBrush(Color.FromRgb(185, 28, 28));
        }
        else
        {
            SendStatusBorder.Background = new SolidColorBrush(Color.FromRgb(220, 252, 231));
            SendStatusText.Foreground = new SolidColorBrush(Color.FromRgb(21, 128, 61));
        }
    }

    private void ShowReceiveStatus(string message, bool isError)
    {
        ReceiveStatusBorder.Visibility = Visibility.Visible;
        ReceiveStatusText.Text = message;

        if (isError)
        {
            ReceiveStatusBorder.Background = new SolidColorBrush(Color.FromRgb(254, 226, 226));
            ReceiveStatusText.Foreground = new SolidColorBrush(Color.FromRgb(185, 28, 28));
        }
        else
        {
            ReceiveStatusBorder.Background = new SolidColorBrush(Color.FromRgb(220, 252, 231));
            ReceiveStatusText.Foreground = new SolidColorBrush(Color.FromRgb(21, 128, 61));
        }
    }

    // --- mDNS Discovery ---

    private void OnDiscoveredServersChanged()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(OnDiscoveredServersChanged);
            return;
        }

        DiscoveredServersPanel.Children.Clear();

        var servers = _mdnsService.DiscoveredServers;
        if (servers.Count == 0)
        {
            DiscoveredServersPanel.Children.Add(new TextBlock
            {
                Text = "Scanning for servers on LAN...",
                Foreground = Brushes.Gray,
                FontSize = 11,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 10, 0, 10),
            });
            return;
        }

        foreach (var server in servers)
        {
            var isSelected = _configStore.HostUrl.TrimEnd('/') == $"http://{server.Host}:{server.Port}";

            var nameText = new TextBlock
            {
                Text = server.Name,
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
            };

            var detailParts = new System.Collections.Generic.List<string> { $"{server.Host}:{server.Port}" };
            if (!string.IsNullOrEmpty(server.Version))
                detailParts.Add($"v{server.Version}");
            if (server.AuthRequired)
                detailParts.Add("auth required");

            var detailText = new TextBlock
            {
                Text = string.Join(" \u2022 ", detailParts),
                FontSize = 11,
                Foreground = Brushes.Gray,
            };

            var stack = new StackPanel { Margin = new Thickness(8, 0, 0, 0) };
            stack.Children.Add(nameText);
            stack.Children.Add(detailText);

            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center,
            };

            if (isSelected)
            {
                row.Children.Add(new TextBlock
                {
                    Text = "\u2713",
                    FontSize = 14,
                    FontWeight = FontWeights.Bold,
                    Foreground = new SolidColorBrush(Color.FromRgb(37, 99, 235)),
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(4, 0, 0, 0),
                });
            }

            row.Children.Add(stack);

            var border = new Border
            {
                Padding = new Thickness(8, 6, 8, 6),
                Cursor = System.Windows.Input.Cursors.Hand,
                Background = isSelected
                    ? new SolidColorBrush(Color.FromRgb(219, 234, 254))
                    : Brushes.Transparent,
            };
            border.Child = row;

            // Click to select
            var capturedServer = server;
            border.MouseLeftButtonUp += (_, _) => SelectDiscoveredServer(capturedServer);

            DiscoveredServersPanel.Children.Add(border);
        }
    }

    private void SelectDiscoveredServer(DiscoveredServer server)
    {
        _configStore.HostUrl = $"http://{server.Host}:{server.Port}";
        _configStore.ServerAuthRequired = server.AuthRequired;
        HostUrlTextBox.Text = _configStore.HostUrl;
        UpdateAccessTokenVisibility();
        OnDiscoveredServersChanged(); // Refresh selection highlight
    }

    private void UpdateAccessTokenVisibility()
    {
        if (_configStore.ServerAuthRequired == false)
        {
            AccessTokenPanel.Visibility = Visibility.Collapsed;
        }
        else
        {
            AccessTokenPanel.Visibility = Visibility.Visible;
            AccessTokenLabel.Text = _configStore.ServerAuthRequired == true
                ? "Access Token (required)"
                : "Access Token (optional)";
        }
    }

    // ── Embedded server toggle ─��──────────────────────────────────────

    public void SetServerEnabled(bool enabled)
    {
        _serverConfig.ServerEnabled = enabled;
        _serverConfig.Save();

        if (enabled)
        {
            _serverProcess.Start();
            AutoConnectToLocalServer();
        }
        else
        {
            _serverProcess.Stop();
        }

        UpdateServerManagementPanel();
    }

    private void AutoConnectToLocalServer()
    {
        _configStore.HostUrl = $"http://localhost:{_serverConfig.Port}";
        if (_serverConfig.AuthEnabled && !string.IsNullOrEmpty(_serverConfig.AccessToken))
        {
            _configStore.AccessToken = _serverConfig.AccessToken;
            AccessTokenBox.Password = _serverConfig.AccessToken;
        }
        _configStore.Save();
        UpdateMainPanelState();
    }

    // ── Embedded server config UI handlers ──────────────────────────────

    private void InitializeServerConfigUI()
    {
        ServerEnabledCheckBox.IsChecked = _serverConfig.ServerEnabled;
        ServerPortBox.Text = _serverConfig.Port.ToString();
        ServerBindAddressBox.Text = _serverConfig.BindAddress;
        ServerStoragePathBox.Text = _serverConfig.StoragePath;
        ServerTtlBox.Text = _serverConfig.TtlHours.ToString();
        ServerMaxClipSizeBox.Text = _serverConfig.MaxClipSizeMB.ToString();
        ServerAuthCheckBox.IsChecked = _serverConfig.AuthEnabled;
        ServerAccessTokenBox.Password = _serverConfig.AccessToken;
        ServerAutoStartCheckBox.IsChecked = _serverConfig.AutoStartServer;

        ServerConfigSection.Visibility = _serverConfig.ServerEnabled ? Visibility.Visible : Visibility.Collapsed;
        ServerTokenPanel.Visibility = _serverConfig.AuthEnabled ? Visibility.Visible : Visibility.Collapsed;
        UpdateServerManagementPanel();
    }

    private void ServerEnabledCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        var enabled = ServerEnabledCheckBox.IsChecked == true;
        ServerConfigSection.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        SetServerEnabled(enabled);
    }

    private void ServerAuthCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        ServerTokenPanel.Visibility = ServerAuthCheckBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ServerAccessTokenBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        // No-op — value read on Apply
    }

    private void ServerStorageBrowseButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "Select server storage directory",
            UseDescriptionForTitle = true,
        };
        if (!string.IsNullOrEmpty(ServerStoragePathBox.Text))
        {
            dialog.InitialDirectory = ServerStoragePathBox.Text;
        }
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
        {
            ServerStoragePathBox.Text = dialog.SelectedPath;
        }
    }

    private async void ServerApplyButton_Click(object sender, RoutedEventArgs e)
    {
        // Read values from UI into ServerConfig
        if (int.TryParse(ServerPortBox.Text, out var port)) _serverConfig.Port = port;
        _serverConfig.BindAddress = ServerBindAddressBox.Text;
        _serverConfig.StoragePath = ServerStoragePathBox.Text;
        if (int.TryParse(ServerTtlBox.Text, out var ttl)) _serverConfig.TtlHours = ttl;
        if (int.TryParse(ServerMaxClipSizeBox.Text, out var maxSize)) _serverConfig.MaxClipSizeMB = maxSize;
        _serverConfig.AuthEnabled = ServerAuthCheckBox.IsChecked == true;
        _serverConfig.AccessToken = ServerAccessTokenBox.Password;
        _serverConfig.AutoStartServer = ServerAutoStartCheckBox.IsChecked == true;
        _serverConfig.Save();

        // Restart if running
        if (_serverProcess.IsRunning)
        {
            await _serverProcess.RestartAsync();
            // Give the server a moment to start before auto-connecting
            await System.Threading.Tasks.Task.Delay(1000);
            AutoConnectToLocalServer();
        }

        ShowStatus("Server configuration saved", isError: false);
    }

    // ── Server management panel ─────────────────────────────────────────

    private void ServerStartButton_Click(object sender, RoutedEventArgs e)
    {
        SetServerEnabled(true);
        ServerEnabledCheckBox.IsChecked = true;
        UpdateServerManagementPanel();
    }

    private void ServerStopButton_Click(object sender, RoutedEventArgs e)
    {
        _serverProcess.Stop();
        UpdateServerManagementPanel();
    }

    private async void ServerRestartButton_Click(object sender, RoutedEventArgs e)
    {
        await _serverProcess.RestartAsync();
        await System.Threading.Tasks.Task.Delay(1000);
        AutoConnectToLocalServer();
        UpdateServerManagementPanel();
    }

    private void UpdateServerManagementPanel()
    {
        if (!_serverConfig.ServerEnabled)
        {
            ServerManagementSection.Visibility = Visibility.Collapsed;
            return;
        }

        ServerManagementSection.Visibility = Visibility.Visible;

        if (_serverProcess.IsRunning)
        {
            ServerStatusDot.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94)); // green
            ServerStatusText.Text = "Running";
            ServerStartButton.Visibility = Visibility.Collapsed;
            ServerStopButton.Visibility = Visibility.Visible;
            ServerRestartButton.Visibility = Visibility.Visible;
        }
        else
        {
            ServerStatusDot.Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68)); // red
            ServerStatusText.Text = "Stopped";
            ServerStartButton.Visibility = Visibility.Visible;
            ServerStopButton.Visibility = Visibility.Collapsed;
            ServerRestartButton.Visibility = Visibility.Collapsed;
        }

        // Storage stats
        _serverConfig.RefreshUsedSpace();
        var usedMB = _serverConfig.UsedSpaceBytes / (1024.0 * 1024.0);
        ServerStorageUsedText.Text = $"Used: {usedMB:F1} MB";
        ServerStoragePathText.Text = _serverConfig.StoragePath;

        // Log viewer
        ServerLogText.Text = string.Join("\n", _serverProcess.LogLines);
        ServerLogScrollViewer.ScrollToEnd();

        // Fetch connected devices
        _ = LoadServerDevicesAsync();
    }

    private async System.Threading.Tasks.Task LoadServerDevicesAsync()
    {
        if (!_serverProcess.IsRunning) return;

        try
        {
            var baseUrl = $"http://localhost:{_serverConfig.Port}";
            using var client = new System.Net.Http.HttpClient();
            if (_serverConfig.AuthEnabled && !string.IsNullOrEmpty(_serverConfig.AccessToken))
            {
                client.DefaultRequestHeaders.Authorization =
                    new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _serverConfig.AccessToken);
            }

            var response = await client.GetAsync($"{baseUrl}/api/v1/devices");
            if (response.IsSuccessStatusCode)
            {
                var json = await response.Content.ReadAsStringAsync();
                var devices = System.Text.Json.JsonSerializer.Deserialize<List<ServerDevice>>(json);
                ServerDevicesPanel.Children.Clear();
                if (devices != null && devices.Count > 0)
                {
                    foreach (var device in devices)
                    {
                        var tb = new TextBlock
                        {
                            Text = $"{device.Name} ({device.Platform}) — {device.DeviceId}",
                            FontSize = 11,
                            Margin = new Thickness(6, 3, 6, 3),
                        };
                        ServerDevicesPanel.Children.Add(tb);
                    }
                }
                else
                {
                    ServerDevicesPanel.Children.Add(new TextBlock
                    {
                        Text = "No devices connected",
                        Foreground = Brushes.Gray,
                        FontSize = 11,
                        HorizontalAlignment = HorizontalAlignment.Center,
                        Margin = new Thickness(0, 6, 0, 6),
                    });
                }
            }
        }
        catch
        {
            // Server might not be ready yet
        }
    }

    private void UpdateMainPanelState()
    {
        var isBtMode = _configStore.TransferMode == TransferMode.Bluetooth;
        var showPanel = isBtMode || _configStore.IsConfigured;
        UpdateReceiverStatusUI();
        UpdateTargetDeviceStatusUI();

        if (showPanel)
        {
            MainPanelPlaceholder.Visibility = Visibility.Collapsed;
            ClipboardPanel.Visibility = Visibility.Visible;
            RefreshClipboardPreview();

            // Toggle queue vs BT status sections
            LanQueueSection.Visibility = isBtMode ? Visibility.Collapsed : Visibility.Visible;
            BtStatusSection.Visibility = isBtMode ? Visibility.Visible : Visibility.Collapsed;

            if (isBtMode)
            {
                UpdateBtStatusPanel();
            }
            else
            {
                StartQueuePolling();
                _ = LoadDeviceListAsync();
                StartSSE();
            }
        }
        else
        {
            MainPanelPlaceholder.Visibility = Visibility.Visible;
            ClipboardPanel.Visibility = Visibility.Collapsed;
            StopQueuePolling();
            StopSSE();
        }
    }

    private void SetSseConnectionState(SseConnectionState state, string detail)
    {
        void Apply()
        {
            _sseConnectionState = state;
            _sseStatusDetail = detail;
            UpdateReceiverStatusUI();
        }

        if (Dispatcher.CheckAccess())
        {
            Apply();
        }
        else
        {
            Dispatcher.Invoke(Apply);
        }
    }

    private void UpdateReceiverStatusUI()
    {
        var effectiveState = _sseConnectionState;
        var detail = _sseStatusDetail;

        if (_configStore.TransferMode == TransferMode.Bluetooth)
        {
            effectiveState = SseConnectionState.Disconnected;
            detail = "LAN receiver is inactive while Bluetooth Direct mode is selected.";
        }
        else if (!_configStore.IsConfigured)
        {
            effectiveState = SseConnectionState.Disconnected;
            detail = "Save a server URL to bring the receiver channel online.";
        }
        else if (string.IsNullOrEmpty(_configStore.DeviceId))
        {
            effectiveState = SseConnectionState.Disconnected;
            detail = "This device is not registered yet. Save settings to register and enable auto-receive.";
        }

        SolidColorBrush dotBrush;
        SolidColorBrush textBrush;
        SolidColorBrush backgroundBrush;
        string title;

        switch (effectiveState)
        {
            case SseConnectionState.Connected:
                dotBrush = new SolidColorBrush(Color.FromRgb(34, 197, 94));
                textBrush = new SolidColorBrush(Color.FromRgb(21, 128, 61));
                backgroundBrush = new SolidColorBrush(Color.FromRgb(220, 252, 231));
                title = "Connected";
                break;
            case SseConnectionState.Reconnecting:
                dotBrush = new SolidColorBrush(Color.FromRgb(234, 179, 8));
                textBrush = new SolidColorBrush(Color.FromRgb(161, 98, 7));
                backgroundBrush = new SolidColorBrush(Color.FromRgb(254, 249, 195));
                title = "Reconnecting";
                break;
            default:
                dotBrush = Brushes.Gray;
                textBrush = new SolidColorBrush(Color.FromRgb(75, 85, 99));
                backgroundBrush = new SolidColorBrush(Color.FromRgb(243, 244, 246));
                title = "Disconnected";
                break;
        }

        ReceiverStatusBorder.Background = backgroundBrush;
        ReceiverStatusIcon.Foreground = dotBrush;
        ReceiverStatusText.Text = $"Receiver Status: {title}";
        ReceiverStatusText.Foreground = textBrush;
        ReceiverStatusDetailText.Text = detail;
        ReceiverStatusDetailText.Foreground = textBrush;

        LanReceiverStatusBorder.Background = backgroundBrush;
        LanReceiverStatusDot.Fill = dotBrush;
        LanReceiverStatusLabel.Text = title;
        LanReceiverStatusLabel.Foreground = textBrush;
        LanReceiverStatusDetailText.Text = detail;
        LanReceiverStatusDetailText.Foreground = textBrush;
    }

    private string CurrentDisconnectedSseDetail()
    {
        if (_configStore.TransferMode == TransferMode.Bluetooth)
        {
            return "LAN receiver is inactive while Bluetooth Direct mode is selected.";
        }

        if (!_configStore.IsConfigured)
        {
            return "Save a server URL to bring the receiver channel online.";
        }

        if (string.IsNullOrEmpty(_configStore.DeviceId))
        {
            return "This device is not registered yet. Save settings to register and enable auto-receive.";
        }

        return "Receiver channel disconnected.";
    }

    private static string FormatRetryDelay(TimeSpan delay)
    {
        return delay.TotalSeconds >= 60
            ? $"{delay.TotalMinutes:F0}m"
            : $"{delay.TotalSeconds:F0}s";
    }

    // Refresh clipboard preview and queue when window is activated
    protected override void OnActivated(EventArgs e)
    {
        base.OnActivated(e);
        RefreshClipboardPreview();
        if (_configStore.TransferMode == TransferMode.LanServer && _configStore.IsConfigured)
        {
            _ = RefreshQueueAsync();
            StartQueuePolling();
        }
        else if (_configStore.TransferMode == TransferMode.Bluetooth)
        {
            UpdateBtStatusPanel();
        }
    }

    // Minimize to tray instead of closing
    protected override void OnStateChanged(EventArgs e)
    {
        base.OnStateChanged(e);
        if (WindowState == WindowState.Minimized)
        {
            Hide();
            ShowInTaskbar = false;
            StopQueuePolling();
        }
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        // Hide to tray instead of closing
        e.Cancel = true;
        Hide();
        ShowInTaskbar = false;
        StopQueuePolling();
    }
}
