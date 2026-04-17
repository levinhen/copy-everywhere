using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.Toolkit.Uwp.Notifications;

namespace CopyEverywhere.Services;

public class SendService
{
    private readonly ApiClient _apiClient;
    private readonly ConfigStore _configStore;
    private readonly BluetoothService _bluetoothService;

    private const long ChunkedThreshold = 50L * 1024 * 1024; // 50MB
    private const int ChunkSize = 10 * 1024 * 1024; // 10MB

    public SendService(ApiClient apiClient, ConfigStore configStore, BluetoothService bluetoothService)
    {
        _apiClient = apiClient;
        _configStore = configStore;
        _bluetoothService = bluetoothService;
    }

    private string? SenderDeviceId => string.IsNullOrEmpty(_configStore.DeviceId) ? null : _configStore.DeviceId;
    private string? TargetDeviceId => string.IsNullOrEmpty(_configStore.TargetDeviceId) ? null : _configStore.TargetDeviceId;

    private string SendModeMessage()
    {
        if (string.IsNullOrEmpty(TargetDeviceId))
        {
            return "Queued for manual receive on any device";
        }

        return _configStore.TargetDeviceReceiverStatus switch
        {
            ReceiverStatus.Online => "Target receiver is online for automatic delivery",
            ReceiverStatus.Degraded => "Target receiver is degraded, so the clip may fall back to queue",
            _ => "Target receiver is offline, so the clip may fall back to queue",
        };
    }

    /// <summary>
    /// Progress callback for Bluetooth sends. UI can subscribe to show progress.
    /// Reports 0.0–1.0.
    /// </summary>
    public event Action<double>? BluetoothSendProgress;

    public async Task SendTextAsync(string text)
    {
        if (_configStore.TransferMode == TransferMode.Bluetooth)
        {
            await SendTextBluetoothAsync(text);
            return;
        }

        var clip = await _apiClient.SendTextClipAsync(text, SenderDeviceId, TargetDeviceId);
        if (clip != null)
        {
            ShowToast("Sent text", $"Sent text ({text.Length} chars). {SendModeMessage()}.");
        }
        else
        {
            ShowToast("Send failed", "Failed to send: no response from server");
        }
    }

    public async Task SendFileAsync(string filePath)
    {
        if (_configStore.TransferMode == TransferMode.Bluetooth)
        {
            await SendFileBluetoothAsync(filePath);
            return;
        }

        var fileInfo = new FileInfo(filePath);
        var filename = fileInfo.Name;

        if (fileInfo.Length >= ChunkedThreshold)
        {
            var initResult = await _apiClient.InitChunkedUploadAsync(filename, fileInfo.Length, ChunkSize, SenderDeviceId, TargetDeviceId);
            if (initResult == null)
            {
                ShowToast("Send failed", $"Failed to send: could not initialize upload for {filename}");
                return;
            }

            var totalChunks = initResult.ChunkCount;
            using var fileStream = new FileStream(filePath, FileMode.Open, FileAccess.Read);

            for (int i = 1; i <= totalChunks; i++)
            {
                fileStream.Seek((long)(i - 1) * ChunkSize, SeekOrigin.Begin);
                var remaining = fileInfo.Length - fileStream.Position;
                var readSize = (int)Math.Min(ChunkSize, remaining);
                var buffer = new byte[readSize];
                await fileStream.ReadAsync(buffer, 0, readSize);
                await _apiClient.UploadChunkAsync(initResult.UploadId, i, buffer);
            }

            var clip = await _apiClient.CompleteChunkedUploadAsync(initResult.UploadId);
            if (clip != null)
            {
                ShowToast("Sent file", $"Sent {filename}. {SendModeMessage()}.");
            }
            else
            {
                ShowToast("Send failed", $"Failed to send: could not complete upload for {filename}");
            }
        }
        else
        {
            var clip = await _apiClient.SendFileAsync(filePath, senderDeviceId: SenderDeviceId, targetDeviceId: TargetDeviceId);
            if (clip != null)
            {
                ShowToast("Sent file", $"Sent {filename}. {SendModeMessage()}.");
            }
            else
            {
                ShowToast("Send failed", $"Failed to send: no response for {filename}");
            }
        }
    }

    // ── Bluetooth send paths ────────────────────────────────────────

    private async Task SendTextBluetoothAsync(string text)
    {
        var session = _bluetoothService.ActiveSession;
        if (session == null || !session.IsHandshakeComplete)
        {
            ShowToast("Send failed", "Bluetooth is not connected");
            return;
        }

        try
        {
            var progress = new Progress<double>(p => BluetoothSendProgress?.Invoke(p));
            await session.SendTextAsync(text, progress);
            ShowToast("Sent text", $"Sent text via Bluetooth ({text.Length} chars)");
        }
        catch (Exception ex)
        {
            ShowToast("Send failed", $"Bluetooth send failed: {ex.Message}");
            throw;
        }
    }

    private async Task SendFileBluetoothAsync(string filePath)
    {
        var session = _bluetoothService.ActiveSession;
        if (session == null || !session.IsHandshakeComplete)
        {
            ShowToast("Send failed", "Bluetooth is not connected");
            return;
        }

        var filename = Path.GetFileName(filePath);

        try
        {
            var progress = new Progress<double>(p => BluetoothSendProgress?.Invoke(p));
            await session.SendFileAsync(filePath, progress);
            ShowToast("Sent file", $"Sent {filename} via Bluetooth");
        }
        catch (Exception ex)
        {
            ShowToast("Send failed", $"Bluetooth send failed: {ex.Message}");
            throw;
        }
    }

    public static void ShowToast(string title, string message)
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
            // Toast notifications may not be available
        }
    }
}
