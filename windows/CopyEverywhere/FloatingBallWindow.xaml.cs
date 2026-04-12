using System;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using CopyEverywhere.Services;
using Microsoft.Toolkit.Uwp.Notifications;

namespace CopyEverywhere;

public partial class FloatingBallWindow : Window
{
    private readonly ConfigStore _configStore;
    private readonly ApiClient _apiClient;

    private const long ChunkedThreshold = 50L * 1024 * 1024; // 50MB
    private const int ChunkSize = 10 * 1024 * 1024; // 10MB

    public FloatingBallWindow(ConfigStore configStore, ApiClient apiClient)
    {
        InitializeComponent();

        _configStore = configStore;
        _apiClient = apiClient;

        // Restore saved position
        if (!double.IsNaN(_configStore.FloatingBallX) && !double.IsNaN(_configStore.FloatingBallY))
        {
            Left = _configStore.FloatingBallX;
            Top = _configStore.FloatingBallY;
        }
        else
        {
            // Default to bottom-right area
            var workArea = SystemParameters.WorkArea;
            Left = workArea.Right - 80;
            Top = workArea.Bottom - 80;
        }
    }

    // --- Drag to reposition ---

    private void Ball_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        DragMove();

        // Persist new position
        _configStore.FloatingBallX = Left;
        _configStore.FloatingBallY = Top;
        _configStore.PersistConfig();
    }

    // --- Drop handling ---

    private void Ball_DragEnter(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent(DataFormats.UnicodeText) || e.Data.GetDataPresent(DataFormats.Text))
        {
            e.Effects = DragDropEffects.Copy;
            BallEllipse.Fill = new SolidColorBrush(Color.FromRgb(34, 197, 94)); // green highlight
        }
        else
        {
            e.Effects = DragDropEffects.None;
        }
        e.Handled = true;
    }

    private void Ball_DragOver(object sender, DragEventArgs e)
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

    private void Ball_DragLeave(object sender, DragEventArgs e)
    {
        BallEllipse.Fill = new SolidColorBrush(Color.FromRgb(59, 130, 246)); // restore blue
    }

    private async void Ball_Drop(object sender, DragEventArgs e)
    {
        BallEllipse.Fill = new SolidColorBrush(Color.FromRgb(59, 130, 246)); // restore blue

        if (!_configStore.IsConfigured)
        {
            ShowToast("Not Configured", "Please configure the server connection first.");
            return;
        }

        // Handle file drops
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            var files = (string[])e.Data.GetData(DataFormats.FileDrop);
            foreach (var filePath in files)
            {
                if (File.Exists(filePath))
                {
                    await SendFileAsync(filePath);
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
            await SendTextAsync(text);
        }
    }

    private async System.Threading.Tasks.Task SendTextAsync(string text)
    {
        try
        {
            var clip = await _apiClient.SendTextClipAsync(text);
            if (clip != null)
            {
                ShowToast("Sent text", $"Sent text ({text.Length} chars)");
            }
            else
            {
                ShowToast("Send failed", "Failed to send: no response from server");
            }
        }
        catch (Exception ex)
        {
            ShowToast("Send failed", $"Failed to send: {ex.Message}");
        }
    }

    private async System.Threading.Tasks.Task SendFileAsync(string filePath)
    {
        var fileInfo = new FileInfo(filePath);
        var filename = fileInfo.Name;

        try
        {
            if (fileInfo.Length >= ChunkedThreshold)
            {
                // Chunked upload
                var initResult = await _apiClient.InitChunkedUploadAsync(filename, fileInfo.Length, ChunkSize);
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
                // Simple upload
                var clip = await _apiClient.SendFileAsync(filePath);
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
        catch (Exception ex)
        {
            ShowToast("Send failed", $"Failed to send: {ex.Message}");
        }
    }

    private static void ShowToast(string title, string message)
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
