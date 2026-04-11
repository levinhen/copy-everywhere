using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CopyEverywhere.Services;
using Microsoft.Toolkit.Uwp.Notifications;

namespace CopyEverywhere;

public partial class MainWindow : Window
{
    private readonly ConfigStore _configStore;
    private readonly ApiClient _apiClient;

    public MainWindow()
    {
        InitializeComponent();

        _configStore = new ConfigStore();
        _apiClient = new ApiClient(_configStore);

        DataContext = _configStore;

        // PasswordBox doesn't support binding, so set manually
        AccessTokenBox.Password = _configStore.AccessToken;

        UpdateMainPanelState();
        RefreshClipboardPreview();
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
