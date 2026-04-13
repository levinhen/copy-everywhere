using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace CopyEverywhere.Services;

/// <summary>
/// Server configuration — full implementation in US-084.
/// Minimal stub so ServerProcess compiles.
/// </summary>
public class ServerConfig : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public string Port { get; set; } = "8080";
    public string BindAddress { get; set; } = "0.0.0.0";
    public string StoragePath { get; set; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CopyEverywhere", "server-data");
    public int TtlHours { get; set; } = 24;
    public bool AuthEnabled { get; set; }
    public string AccessToken { get; set; } = "";
    public int MaxClipSizeMB { get; set; } = 50;

    public Dictionary<string, string> GetEnvironment()
    {
        var env = new Dictionary<string, string>
        {
            ["PORT"] = Port,
            ["BIND_ADDRESS"] = BindAddress,
            ["STORAGE_PATH"] = StoragePath,
            ["TTL_HOURS"] = TtlHours.ToString(),
            ["AUTH_ENABLED"] = AuthEnabled.ToString().ToLower(),
            ["MAX_CLIP_SIZE_MB"] = MaxClipSizeMB.ToString(),
        };

        if (AuthEnabled && !string.IsNullOrEmpty(AccessToken))
            env["ACCESS_TOKEN"] = AccessToken;

        return env;
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
