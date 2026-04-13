using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows;

namespace CopyEverywhere.Services;

public class ServerProcess : INotifyPropertyChanged
{
    private const int MaxLogLines = 500;

    private Process? _process;
    private bool _isRunning;
    private readonly ServerConfig _serverConfig;

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<string> LogLines { get; } = new();

    public string BinaryPath { get; set; } =
        Path.Combine(AppContext.BaseDirectory, "copyeverywhere-server.exe");

    public bool IsRunning
    {
        get => _isRunning;
        private set { _isRunning = value; OnPropertyChanged(); }
    }

    public ServerProcess(ServerConfig serverConfig)
    {
        _serverConfig = serverConfig;
        Application.Current.Exit += (_, _) => Stop();
    }

    public void Start()
    {
        if (_process != null && !_process.HasExited)
            return;

        if (!File.Exists(BinaryPath))
        {
            AppendLog($"[error] Server binary not found: {BinaryPath}");
            return;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = BinaryPath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        var env = _serverConfig.GetEnvironment();
        foreach (var kv in env)
            startInfo.Environment[kv.Key] = kv.Value;

        var proc = new Process { StartInfo = startInfo, EnableRaisingEvents = true };

        proc.OutputDataReceived += (_, e) =>
        {
            if (e.Data != null)
                AppendLog(e.Data);
        };

        proc.ErrorDataReceived += (_, e) =>
        {
            if (e.Data != null)
                AppendLog(e.Data);
        };

        proc.Exited += (_, _) =>
        {
            var exitCode = 0;
            try { exitCode = proc.ExitCode; } catch { /* process may be disposed */ }
            AppendLog($"[server] Process exited with code {exitCode}");
            Application.Current.Dispatcher.Invoke(() => IsRunning = false);
        };

        try
        {
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            _process = proc;
            IsRunning = true;
            AppendLog("[server] Started");
        }
        catch (Exception ex)
        {
            AppendLog($"[error] Failed to start server: {ex.Message}");
        }
    }

    public void Stop()
    {
        if (_process == null) return;

        try
        {
            if (!_process.HasExited)
                _process.Kill(entireProcessTree: true);
        }
        catch
        {
            // Process may have already exited
        }

        _process = null;
        IsRunning = false;
        AppendLog("[server] Stopped");
    }

    public async Task RestartAsync()
    {
        Stop();
        await Task.Delay(500);
        Start();
    }

    private void AppendLog(string line)
    {
        if (Application.Current?.Dispatcher == null) return;

        Application.Current.Dispatcher.Invoke(() =>
        {
            LogLines.Add(line);
            while (LogLines.Count > MaxLogLines)
                LogLines.RemoveAt(0);
        });
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
