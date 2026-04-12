using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;

namespace CopyEverywhere.Services;

public class ServerConfig : INotifyPropertyChanged
{
    private static readonly string ConfigDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CopyEverywhere");
    private static readonly string ConfigFilePath = Path.Combine(ConfigDir, "server-config.json");

    public static readonly string DefaultStoragePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CopyEverywhere", "server-data");

    private int _port = 8080;
    private string _storagePath = DefaultStoragePath;
    private string _bindAddress = "0.0.0.0";
    private int _ttlHours = 24;
    private bool _authEnabled;
    private string _accessToken = "";
    private int _maxClipSizeMB = 50;
    private bool _serverEnabled;
    private bool _autoStartServer;
    private long _usedSpaceBytes;

    public event PropertyChangedEventHandler? PropertyChanged;

    public int Port
    {
        get => _port;
        set { if (_port != value) { _port = value; OnPropertyChanged(); } }
    }

    public string StoragePath
    {
        get => _storagePath;
        set { if (_storagePath != value) { _storagePath = value; OnPropertyChanged(); } }
    }

    public string BindAddress
    {
        get => _bindAddress;
        set { if (_bindAddress != value) { _bindAddress = value; OnPropertyChanged(); } }
    }

    public int TtlHours
    {
        get => _ttlHours;
        set { if (_ttlHours != value) { _ttlHours = value; OnPropertyChanged(); } }
    }

    public bool AuthEnabled
    {
        get => _authEnabled;
        set { if (_authEnabled != value) { _authEnabled = value; OnPropertyChanged(); } }
    }

    public string AccessToken
    {
        get => _accessToken;
        set { if (_accessToken != value) { _accessToken = value; OnPropertyChanged(); } }
    }

    public int MaxClipSizeMB
    {
        get => _maxClipSizeMB;
        set { if (_maxClipSizeMB != value) { _maxClipSizeMB = value; OnPropertyChanged(); } }
    }

    public bool ServerEnabled
    {
        get => _serverEnabled;
        set { if (_serverEnabled != value) { _serverEnabled = value; OnPropertyChanged(); } }
    }

    public bool AutoStartServer
    {
        get => _autoStartServer;
        set { if (_autoStartServer != value) { _autoStartServer = value; OnPropertyChanged(); } }
    }

    public long UsedSpaceBytes
    {
        get => _usedSpaceBytes;
        set { if (_usedSpaceBytes != value) { _usedSpaceBytes = value; OnPropertyChanged(); } }
    }

    public ServerConfig()
    {
        Load();
    }

    /// <summary>
    /// Returns environment variables to forward to the Go server subprocess.
    /// </summary>
    public Dictionary<string, string> GetEnvironment()
    {
        var env = new Dictionary<string, string>
        {
            ["PORT"] = Port.ToString(),
            ["BIND_ADDRESS"] = BindAddress,
            ["STORAGE_PATH"] = StoragePath,
            ["TTL_HOURS"] = TtlHours.ToString(),
            ["MAX_CLIP_SIZE_MB"] = MaxClipSizeMB.ToString(),
            ["AUTH_ENABLED"] = AuthEnabled ? "true" : "false",
        };
        if (AuthEnabled && !string.IsNullOrEmpty(AccessToken))
        {
            env["ACCESS_TOKEN"] = AccessToken;
        }
        return env;
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(ConfigDir);
            var data = new ServerConfigData
            {
                Port = Port,
                StoragePath = StoragePath,
                BindAddress = BindAddress,
                TtlHours = TtlHours,
                AuthEnabled = AuthEnabled,
                AccessToken = AccessToken,
                MaxClipSizeMB = MaxClipSizeMB,
                ServerEnabled = ServerEnabled,
                AutoStartServer = AutoStartServer,
            };
            var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(ConfigFilePath, json);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[ServerConfig] Failed to save: {ex.Message}");
        }
    }

    public void Load()
    {
        try
        {
            if (!File.Exists(ConfigFilePath)) return;

            var json = File.ReadAllText(ConfigFilePath);
            var data = JsonSerializer.Deserialize<ServerConfigData>(json);
            if (data == null) return;

            Port = data.Port;
            StoragePath = !string.IsNullOrEmpty(data.StoragePath) ? data.StoragePath : DefaultStoragePath;
            BindAddress = !string.IsNullOrEmpty(data.BindAddress) ? data.BindAddress : "0.0.0.0";
            TtlHours = data.TtlHours;
            AuthEnabled = data.AuthEnabled;
            AccessToken = data.AccessToken ?? "";
            MaxClipSizeMB = data.MaxClipSizeMB > 0 ? data.MaxClipSizeMB : 50;
            ServerEnabled = data.ServerEnabled;
            AutoStartServer = data.AutoStartServer;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[ServerConfig] Failed to load: {ex.Message}");
        }
    }

    public void RefreshUsedSpace()
    {
        var path = StoragePath;
        Task.Run(() =>
        {
            long total = 0;
            try
            {
                if (Directory.Exists(path))
                {
                    foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
                    {
                        try { total += new FileInfo(file).Length; } catch { }
                    }
                }
            }
            catch { }

            System.Windows.Application.Current?.Dispatcher.Invoke(() =>
            {
                UsedSpaceBytes = total;
            });
        });
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}

internal class ServerConfigData
{
    [JsonPropertyName("port")]
    public int Port { get; set; } = 8080;

    [JsonPropertyName("storagePath")]
    public string StoragePath { get; set; } = "";

    [JsonPropertyName("bindAddress")]
    public string BindAddress { get; set; } = "0.0.0.0";

    [JsonPropertyName("ttlHours")]
    public int TtlHours { get; set; } = 24;

    [JsonPropertyName("authEnabled")]
    public bool AuthEnabled { get; set; }

    [JsonPropertyName("accessToken")]
    public string? AccessToken { get; set; }

    [JsonPropertyName("maxClipSizeMB")]
    public int MaxClipSizeMB { get; set; } = 50;

    [JsonPropertyName("serverEnabled")]
    public bool ServerEnabled { get; set; }

    [JsonPropertyName("autoStartServer")]
    public bool AutoStartServer { get; set; }
}
