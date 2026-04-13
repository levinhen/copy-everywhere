using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using System.Windows;

namespace CopyEverywhere.Services;

public class ServerConfig : INotifyPropertyChanged
{
    private static readonly string ConfigDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CopyEverywhere");
    private static readonly string ConfigFilePath = Path.Combine(ConfigDir, "server-config.json");

    private string _port = "8080";
    private string _bindAddress = "0.0.0.0";
    private string _storagePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CopyEverywhere", "server-data");
    private int _ttlHours = 24;
    private bool _authEnabled;
    private string _accessToken = "";
    private int _maxClipSizeMB = 50;
    private bool _serverEnabled;
    private bool _autoStartServer;
    private long _usedSpaceBytes;

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Port
    {
        get => _port;
        set { _port = value; OnPropertyChanged(); }
    }

    public string BindAddress
    {
        get => _bindAddress;
        set { _bindAddress = value; OnPropertyChanged(); }
    }

    public string StoragePath
    {
        get => _storagePath;
        set { _storagePath = value; OnPropertyChanged(); }
    }

    public int TtlHours
    {
        get => _ttlHours;
        set { _ttlHours = value; OnPropertyChanged(); }
    }

    public bool AuthEnabled
    {
        get => _authEnabled;
        set { _authEnabled = value; OnPropertyChanged(); }
    }

    public string AccessToken
    {
        get => _accessToken;
        set { _accessToken = value; OnPropertyChanged(); }
    }

    public int MaxClipSizeMB
    {
        get => _maxClipSizeMB;
        set { _maxClipSizeMB = value; OnPropertyChanged(); }
    }

    public bool ServerEnabled
    {
        get => _serverEnabled;
        set { _serverEnabled = value; OnPropertyChanged(); }
    }

    public bool AutoStartServer
    {
        get => _autoStartServer;
        set { _autoStartServer = value; OnPropertyChanged(); }
    }

    public long UsedSpaceBytes
    {
        get => _usedSpaceBytes;
        set { _usedSpaceBytes = value; OnPropertyChanged(); }
    }

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

    public void Save()
    {
        Directory.CreateDirectory(ConfigDir);

        var data = new ServerConfigData
        {
            Port = Port,
            BindAddress = BindAddress,
            StoragePath = StoragePath,
            TtlHours = TtlHours,
            AuthEnabled = AuthEnabled,
            AccessToken = AccessToken,
            MaxClipSizeMB = MaxClipSizeMB,
            ServerEnabled = ServerEnabled,
            AutoStartServer = AutoStartServer,
        };

        var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
        var tmpPath = ConfigFilePath + ".tmp";
        File.WriteAllText(tmpPath, json);

        if (File.Exists(ConfigFilePath))
            File.Replace(tmpPath, ConfigFilePath, null);
        else
            File.Move(tmpPath, ConfigFilePath);
    }

    public void Load()
    {
        if (!File.Exists(ConfigFilePath))
            return;

        try
        {
            var json = File.ReadAllText(ConfigFilePath);
            var data = JsonSerializer.Deserialize<ServerConfigData>(json);
            if (data == null) return;

            Port = data.Port;
            BindAddress = data.BindAddress;
            StoragePath = data.StoragePath;
            TtlHours = data.TtlHours;
            AuthEnabled = data.AuthEnabled;
            AccessToken = data.AccessToken;
            MaxClipSizeMB = data.MaxClipSizeMB;
            ServerEnabled = data.ServerEnabled;
            AutoStartServer = data.AutoStartServer;
        }
        catch
        {
            // Missing or corrupt file — keep defaults
        }
    }

    public async Task RefreshUsedSpaceAsync()
    {
        var path = StoragePath;
        var bytes = await Task.Run(() =>
        {
            if (!Directory.Exists(path))
                return 0L;

            long total = 0;
            try
            {
                foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
                {
                    try
                    {
                        total += new FileInfo(file).Length;
                    }
                    catch
                    {
                        // Skip inaccessible files
                    }
                }
            }
            catch
            {
                // Directory may have become inaccessible
            }
            return total;
        });

        Application.Current?.Dispatcher?.Invoke(() => UsedSpaceBytes = bytes);
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private class ServerConfigData
    {
        [JsonPropertyName("port")]
        public string Port { get; set; } = "8080";

        [JsonPropertyName("bind_address")]
        public string BindAddress { get; set; } = "0.0.0.0";

        [JsonPropertyName("storage_path")]
        public string StoragePath { get; set; } = "";

        [JsonPropertyName("ttl_hours")]
        public int TtlHours { get; set; } = 24;

        [JsonPropertyName("auth_enabled")]
        public bool AuthEnabled { get; set; }

        [JsonPropertyName("access_token")]
        public string AccessToken { get; set; } = "";

        [JsonPropertyName("max_clip_size_mb")]
        public int MaxClipSizeMB { get; set; } = 50;

        [JsonPropertyName("server_enabled")]
        public bool ServerEnabled { get; set; }

        [JsonPropertyName("auto_start_server")]
        public bool AutoStartServer { get; set; }
    }
}
