using System;
using System.Collections.Generic;
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

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool IsRunning
    {
        get => _isRunning;
        private set
        {
            if (_isRunning == value) return;
            _isRunning = value;
            OnPropertyChanged();
        }
    }

    public ObservableCollection<string> LogLines { get; } = new();

    /// <summary>
    /// Path to the Go server binary. Defaults to copyeverywhere-server.exe
    /// next to the client executable.
    /// </summary>
    public string BinaryPath { get; set; }

    /// <summary>
    /// Server configuration — environment variables are derived from this.
    /// </summary>
    public ServerConfig? Config { get; set; }

    public ServerProcess()
    {
        var exeDir = AppDomain.CurrentDomain.BaseDirectory;
        BinaryPath = Path.Combine(exeDir, "copyeverywhere-server.exe");

        // Register for app exit to kill the subprocess
        Application.Current.Exit += (_, _) => Stop();
    }

    public void Start()
    {
        if (IsRunning) return;

        var psi = new ProcessStartInfo
        {
            FileName = BinaryPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };

        // Merge current environment with server config overrides
        if (Config != null)
        {
            foreach (var kv in Config.GetEnvironment())
            {
                psi.Environment[kv.Key] = kv.Value;
            }
        }

        try
        {
            var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
            proc.OutputDataReceived += OnOutputData;
            proc.ErrorDataReceived += OnErrorData;
            proc.Exited += OnProcessExited;

            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();

            _process = proc;
            IsRunning = true;
            AppendLog($"[host] Server started (PID {proc.Id})");
        }
        catch (Exception ex)
        {
            AppendLog($"[host] Failed to start server: {ex.Message}");
        }
    }

    public void Stop()
    {
        if (_process == null || _process.HasExited) return;

        AppendLog("[host] Stopping server...");
        try
        {
            // Send Ctrl+C (SIGINT equivalent on Windows) for graceful shutdown
            // Fall back to Kill if the process doesn't have a console
            _process.Kill();
        }
        catch (Exception ex)
        {
            AppendLog($"[host] Error stopping server: {ex.Message}");
        }
    }

    public async Task RestartAsync()
    {
        Stop();

        // Wait for the process to actually exit (up to 5s)
        for (int i = 0; i < 50; i++)
        {
            if (!IsRunning) break;
            await Task.Delay(100);
        }

        Start();
    }

    public void Restart()
    {
        _ = RestartAsync();
    }

    private void OnOutputData(object sender, DataReceivedEventArgs e)
    {
        if (e.Data == null) return;
        Application.Current?.Dispatcher.Invoke(() => AppendLog(e.Data));
    }

    private void OnErrorData(object sender, DataReceivedEventArgs e)
    {
        if (e.Data == null) return;
        Application.Current?.Dispatcher.Invoke(() => AppendLog(e.Data));
    }

    private void OnProcessExited(object? sender, EventArgs e)
    {
        Application.Current?.Dispatcher.Invoke(() =>
        {
            var code = _process?.ExitCode ?? -1;
            IsRunning = false;
            _process = null;
            AppendLog($"[host] Server exited (code {code})");
        });
    }

    private void AppendLog(string line)
    {
        LogLines.Add(line);
        while (LogLines.Count > MaxLogLines)
        {
            LogLines.RemoveAt(0);
        }
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
