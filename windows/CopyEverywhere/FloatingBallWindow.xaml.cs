using System;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using CopyEverywhere.Services;

namespace CopyEverywhere;

public partial class FloatingBallWindow : Window
{
    private readonly ConfigStore _configStore;
    private readonly SendService _sendService;

    public FloatingBallWindow(ConfigStore configStore, SendService sendService)
    {
        InitializeComponent();

        _configStore = configStore;
        _sendService = sendService;

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
            SendService.ShowToast("Not Configured", "Please configure the server connection first.");
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
                    try
                    {
                        await _sendService.SendFileAsync(filePath);
                    }
                    catch (Exception ex)
                    {
                        SendService.ShowToast("Send failed", $"Failed to send: {ex.Message}");
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
                await _sendService.SendTextAsync(text);
            }
            catch (Exception ex)
            {
                SendService.ShowToast("Send failed", $"Failed to send: {ex.Message}");
            }
        }
    }
}
