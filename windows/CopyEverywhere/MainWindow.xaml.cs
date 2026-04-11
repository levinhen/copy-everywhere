using System;
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

namespace CopyEverywhere;

public partial class MainWindow : Window
{
    private readonly ConfigStore _configStore;
    private readonly ApiClient _apiClient;
    private readonly HistoryStore _historyStore;

    private const int ChunkSize = 10 * 1024 * 1024; // 10MB
    private const long ChunkedThreshold = 50L * 1024 * 1024; // 50MB

    // Chunked upload state
    private CancellationTokenSource? _uploadCts;
    private string? _chunkedUploadId;
    private string? _chunkedFilePath;
    private bool _isChunkedUpload;

    // Download state
    private ClipResponse? _downloadClipMetadata;

    public MainWindow()
    {
        InitializeComponent();

        _configStore = new ConfigStore();
        _apiClient = new ApiClient(_configStore);
        _historyStore = new HistoryStore();

        DataContext = _configStore;

        // PasswordBox doesn't support binding, so set manually
        AccessTokenBox.Password = _configStore.AccessToken;

        UpdateMainPanelState();
        RefreshClipboardPreview();
        RefreshHistoryList();
    }

    private void AccessTokenBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        _configStore.AccessToken = AccessTokenBox.Password;
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(_configStore.HostUrl))
        {
            ShowStatus("Please enter a Host URL", isError: true);
            return;
        }

        if (string.IsNullOrWhiteSpace(_configStore.AccessToken))
        {
            ShowStatus("Please enter an Access Token", isError: true);
            return;
        }

        _configStore.Save();
        ShowStatus("Configuration saved", isError: false);
        UpdateMainPanelState();
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
            var clip = await _apiClient.SendTextClipAsync(clipboardText);
            if (clip != null)
            {
                var expiresIn = clip.ExpiresAt.ToLocalTime().ToString("HH:mm:ss");
                ShowSendStatus($"Sent! Clip ID: {clip.Id}\nExpires at: {expiresIn}", isError: false);
                _historyStore.AddRecord(new HistoryRecord
                {
                    ClipId = clip.Id,
                    Type = "text",
                    Filename = null,
                    Timestamp = clip.CreatedAt,
                    ExpiresAt = clip.ExpiresAt,
                    Status = "success",
                });
                RefreshHistoryList();
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

                var clip = await _apiClient.SendFileAsync(filePath, progress, _uploadCts.Token);
                if (clip != null)
                {
                    var expiresAt = clip.ExpiresAt.ToLocalTime().ToString("HH:mm:ss");
                    ShowFileUploadStatus($"Uploaded! Clip ID: {clip.Id}\nFile: {clip.Filename} ({FormatBytes(clip.SizeBytes)})\nExpires at: {expiresAt}", isError: false);
                    _historyStore.AddRecord(new HistoryRecord
                    {
                        ClipId = clip.Id,
                        Type = clip.Type,
                        Filename = clip.Filename,
                        Timestamp = clip.CreatedAt,
                        ExpiresAt = clip.ExpiresAt,
                        Status = "success",
                    });
                    RefreshHistoryList();
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
            // Record failed upload in history
            _historyStore.AddRecord(new HistoryRecord
            {
                ClipId = _chunkedUploadId ?? "?",
                Type = "file",
                Filename = Path.GetFileName(filePath),
                Timestamp = DateTime.UtcNow,
                ExpiresAt = DateTime.UtcNow.AddHours(1),
                Status = "failed",
            });
            RefreshHistoryList();
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

        var initResult = await _apiClient.InitChunkedUploadAsync(filename, fileSize, ChunkSize, ct);
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
            ShowFileUploadStatus($"Uploaded! Clip ID: {clip.Id}\nFile: {clip.Filename} ({FormatBytes(clip.SizeBytes)})\nExpires at: {expiresAt}", isError: false);
            _historyStore.AddRecord(new HistoryRecord
            {
                ClipId = clip.Id,
                Type = clip.Type,
                Filename = clip.Filename,
                Timestamp = clip.CreatedAt,
                ExpiresAt = clip.ExpiresAt,
                Status = "success",
            });
            RefreshHistoryList();
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
                    ShowFileUploadStatus($"Uploaded! Clip ID: {clip.Id}\nFile: {clip.Filename} ({FormatBytes(clip.SizeBytes)})\nExpires at: {expiresAt}", isError: false);
                    _historyStore.AddRecord(new HistoryRecord
                    {
                        ClipId = clip.Id,
                        Type = clip.Type,
                        Filename = clip.Filename,
                        Timestamp = clip.CreatedAt,
                        ExpiresAt = clip.ExpiresAt,
                        Status = "success",
                    });
                    RefreshHistoryList();
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

    // --- History ---

    private void RefreshHistoryList()
    {
        HistoryListPanel.Children.Clear();

        if (_historyStore.Records.Count == 0)
        {
            HistoryListPanel.Children.Add(new TextBlock
            {
                Text = "No history yet",
                Foreground = new SolidColorBrush(Colors.Gray),
                FontSize = 12,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 8, 0, 8),
            });
            return;
        }

        foreach (var record in _historyStore.Records)
        {
            var row = CreateHistoryRow(record);
            HistoryListPanel.Children.Add(row);
        }
    }

    private Border CreateHistoryRow(HistoryRecord record)
    {
        var isGrayed = record.IsExpired || record.Status == "failed";

        // Type icon + Clip ID
        var typeIcon = new TextBlock
        {
            Text = record.TypeIcon,
            FontSize = 14,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0),
        };

        var clipIdText = new TextBlock
        {
            Text = record.ClipId,
            FontWeight = FontWeights.SemiBold,
            FontSize = 13,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = isGrayed ? new SolidColorBrush(Colors.Gray) : new SolidColorBrush(Colors.Black),
        };

        // Filename or type label
        var detailText = new TextBlock
        {
            Text = record.Filename ?? record.Type,
            FontSize = 11,
            Foreground = new SolidColorBrush(Colors.Gray),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 120,
        };

        var leftPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Children = { typeIcon, clipIdText, detailText },
        };

        // Timestamp
        var timestamp = new TextBlock
        {
            Text = record.Timestamp.ToLocalTime().ToString("MM/dd HH:mm"),
            FontSize = 11,
            Foreground = new SolidColorBrush(Colors.Gray),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
        };

        // Status label
        var statusLabel = new TextBlock
        {
            Text = record.DisplayLabel,
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
            Foreground = record.Status == "failed"
                ? new SolidColorBrush(Color.FromRgb(185, 28, 28))
                : record.IsExpired
                    ? new SolidColorBrush(Colors.Gray)
                    : new SolidColorBrush(Color.FromRgb(21, 128, 61)),
        };

        // Delete button
        var deleteButton = new Button
        {
            Content = "\u2715",
            Width = 24,
            Height = 24,
            FontSize = 11,
            Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
            Tag = record.ClipId,
        };
        deleteButton.Click += HistoryDeleteButton_Click;

        var rightPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Children = { timestamp, statusLabel, deleteButton },
        };

        var rowGrid = new DockPanel
        {
            LastChildFill = true,
        };
        DockPanel.SetDock(rightPanel, Dock.Right);
        rowGrid.Children.Add(rightPanel);
        rowGrid.Children.Add(leftPanel);

        var border = new Border
        {
            BorderBrush = new SolidColorBrush(Color.FromRgb(230, 230, 230)),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(4, 6, 4, 6),
            Cursor = System.Windows.Input.Cursors.Hand,
            Tag = record.ClipId,
            Child = rowGrid,
        };

        border.MouseLeftButtonUp += HistoryRow_Click;

        return border;
    }

    private void HistoryRow_Click(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is Border border && border.Tag is string clipId)
        {
            try
            {
                Clipboard.SetText(clipId);
                ShowToastNotification("Clip ID Copied", $"Clip ID {clipId} copied to clipboard");
            }
            catch
            {
                // Clipboard may be locked
            }
        }
    }

    private void HistoryDeleteButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button button && button.Tag is string clipId)
        {
            _historyStore.DeleteRecord(clipId);
            RefreshHistoryList();
        }
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

    private void UpdateMainPanelState()
    {
        if (_configStore.IsConfigured)
        {
            MainPanelPlaceholder.Visibility = Visibility.Collapsed;
            ClipboardPanel.Visibility = Visibility.Visible;
            RefreshClipboardPreview();
        }
        else
        {
            MainPanelPlaceholder.Visibility = Visibility.Visible;
            ClipboardPanel.Visibility = Visibility.Collapsed;
        }
    }

    // Refresh clipboard preview when window is activated
    protected override void OnActivated(EventArgs e)
    {
        base.OnActivated(e);
        if (_configStore.IsConfigured)
        {
            RefreshClipboardPreview();
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
        }
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        // Hide to tray instead of closing
        e.Cancel = true;
        Hide();
        ShowInTaskbar = false;
    }
}
