using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.Toolkit.Uwp.Notifications;

namespace CopyEverywhere.Services;

public class SendService
{
    private readonly ApiClient _apiClient;
    private readonly ConfigStore _configStore;

    private const long ChunkedThreshold = 50L * 1024 * 1024; // 50MB
    private const int ChunkSize = 10 * 1024 * 1024; // 10MB

    public SendService(ApiClient apiClient, ConfigStore configStore)
    {
        _apiClient = apiClient;
        _configStore = configStore;
    }

    private string? SenderDeviceId => string.IsNullOrEmpty(_configStore.DeviceId) ? null : _configStore.DeviceId;
    private string? TargetDeviceId => string.IsNullOrEmpty(_configStore.TargetDeviceId) ? null : _configStore.TargetDeviceId;

    public async Task SendTextAsync(string text)
    {
        var clip = await _apiClient.SendTextClipAsync(text, SenderDeviceId, TargetDeviceId);
        if (clip != null)
        {
            ShowToast("Sent text", $"Sent text ({text.Length} chars)");
        }
        else
        {
            ShowToast("Send failed", "Failed to send: no response from server");
        }
    }

    public async Task SendFileAsync(string filePath)
    {
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
                ShowToast("Sent file", $"Sent {filename}");
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
                ShowToast("Sent file", $"Sent {filename}");
            }
            else
            {
                ShowToast("Send failed", $"Failed to send: no response for {filename}");
            }
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
