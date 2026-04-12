using System;
using System.Drawing;
using System.Windows;
using Hardcodet.Wpf.TaskbarNotification;

namespace CopyEverywhere;

public partial class App : Application
{
    private TaskbarIcon? _notifyIcon;
    private MainWindow? _mainWindow;
    private FloatingBallWindow? _floatingBall;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _notifyIcon = new TaskbarIcon
        {
            ToolTipText = "CopyEverywhere",
            Icon = LoadAppIcon(),
        };
        _notifyIcon.TrayLeftMouseDown += OnTrayLeftClick;

        var exitItem = new System.Windows.Controls.MenuItem { Header = "Exit" };
        exitItem.Click += (_, _) => Shutdown();
        _notifyIcon.ContextMenu = new System.Windows.Controls.ContextMenu();
        _notifyIcon.ContextMenu.Items.Add(exitItem);

        _mainWindow = new MainWindow();

        // Create floating ball window, sharing ConfigStore and SendService
        var sendService = new Services.SendService(_mainWindow.ApiClient, _mainWindow.ConfigStore);
        _mainWindow.SendService = sendService;
        _floatingBall = new FloatingBallWindow(_mainWindow.ConfigStore, sendService);
        if (_mainWindow.ConfigStore.ShowFloatingBall)
        {
            _floatingBall.Show();
        }

        // Listen for toggle changes from config UI
        _mainWindow.FloatingBallVisibilityChanged += OnFloatingBallVisibilityChanged;

        // Show on first launch so user can configure
        ShowMainWindow();
    }

    private void OnFloatingBallVisibilityChanged(bool visible)
    {
        if (_floatingBall == null) return;

        if (visible)
            _floatingBall.Show();
        else
            _floatingBall.Hide();
    }

    private void OnTrayLeftClick(object sender, RoutedEventArgs e)
    {
        ShowMainWindow();
    }

    private void ShowMainWindow()
    {
        if (_mainWindow == null) return;

        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.ShowInTaskbar = true;
        _mainWindow.Activate();
    }

    private static Icon LoadAppIcon()
    {
        // Use a default system icon; replace with custom .ico if available
        return SystemIcons.Application;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _notifyIcon?.Dispose();
        base.OnExit(e);
    }
}
