using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CopyEverywhere.Services;

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

    private void UpdateMainPanelState()
    {
        if (_configStore.IsConfigured)
        {
            MainPanelPlaceholder.Text = "Server configured. Ready to send and receive.";
        }
        else
        {
            MainPanelPlaceholder.Text = "Configure server connection above to get started.";
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
