using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using CredentialManagement;

namespace CopyEverywhere.Services;

// ── Transfer mode ────────────────────────────────────────────────────

public enum TransferMode
{
    LanServer,
    Bluetooth
}

// LAN discovery contract for this iteration lives in `tasks/lan-discovery-selection-contract.md`
// and is tracked by Ralph in `scripts/ralph/prd.json` / `scripts/ralph/progress.txt`.
public enum LanEndpointSource
{
    AutoDiscovered,
    RestoredSelection,
    ManualFallback
}

public class StoredLanServerSelection
{
    [JsonPropertyName("server_id")]
    public string ServerId { get; set; } = "";

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("host")]
    public string Host { get; set; } = "";

    [JsonPropertyName("port")]
    public int Port { get; set; }

    [JsonPropertyName("source")]
    public string Source { get; set; } = "manual_fallback";
}

// ── Paired device persistence model ─────────────────────────────────

public class PairedBluetoothDevice
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("address")]
    public ulong Address { get; set; }

    [JsonPropertyName("address_string")]
    public string AddressString { get; set; } = "";
}

// ── Bluetooth connection status ─────────────────────────────────────

public enum BluetoothConnectionStatus
{
    Disconnected,
    Connecting,
    Connected,
    Error
}

public enum ReceiverStatus
{
    Online,
    Degraded,
    Offline
}

public class ConfigStore : INotifyPropertyChanged
{
    private const string CredentialTargetHost = "CopyEverywhere_HostURL";
    private const string CredentialTargetToken = "CopyEverywhere_AccessToken";

    private static readonly string ConfigDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CopyEverywhere");
    private static readonly string ConfigFilePath = Path.Combine(ConfigDir, "config.json");

    private string _hostUrl = "";
    private string _accessToken = "";
    private string _deviceId = "";
    private string _deviceName = "";
    private string _targetDeviceId = "";
    private bool _showFloatingBall = true;
    private double _floatingBallX = double.NaN;
    private double _floatingBallY = double.NaN;
    private bool? _serverAuthRequired; // null = unknown, populated from mDNS TXT or /health

    // Bluetooth state
    private TransferMode _transferMode = TransferMode.LanServer;
    private List<PairedBluetoothDevice> _pairedDevices = new();
    private BluetoothConnectionStatus _bluetoothConnectionStatus = BluetoothConnectionStatus.Disconnected;
    private string? _bluetoothConnectedDeviceName;
    private string? _bluetoothErrorMessage;
    private ReceiverStatus _targetDeviceReceiverStatus = ReceiverStatus.Offline;
    private LanEndpointSource _lanEndpointSource = LanEndpointSource.ManualFallback;
    private StoredLanServerSelection? _selectedLanServer;

    public event PropertyChangedEventHandler? PropertyChanged;

    public string HostUrl
    {
        get => _hostUrl;
        set { _hostUrl = value; OnPropertyChanged(); }
    }

    public string AccessToken
    {
        get => _accessToken;
        set { _accessToken = value; OnPropertyChanged(); }
    }

    public string DeviceId
    {
        get => _deviceId;
        set { _deviceId = value; OnPropertyChanged(); }
    }

    public string DeviceName
    {
        get => _deviceName;
        set { _deviceName = value; OnPropertyChanged(); }
    }

    public string TargetDeviceId
    {
        get => _targetDeviceId;
        set { _targetDeviceId = value; OnPropertyChanged(); }
    }

    public bool ShowFloatingBall
    {
        get => _showFloatingBall;
        set { _showFloatingBall = value; OnPropertyChanged(); }
    }

    public double FloatingBallX
    {
        get => _floatingBallX;
        set { _floatingBallX = value; OnPropertyChanged(); }
    }

    public double FloatingBallY
    {
        get => _floatingBallY;
        set { _floatingBallY = value; OnPropertyChanged(); }
    }

    public bool? ServerAuthRequired
    {
        get => _serverAuthRequired;
        set { _serverAuthRequired = value; OnPropertyChanged(); }
    }

    public TransferMode TransferMode
    {
        get => _transferMode;
        set { _transferMode = value; OnPropertyChanged(); }
    }

    public List<PairedBluetoothDevice> PairedDevices
    {
        get => _pairedDevices;
        set { _pairedDevices = value; OnPropertyChanged(); }
    }

    public BluetoothConnectionStatus BluetoothConnectionStatus
    {
        get => _bluetoothConnectionStatus;
        set { _bluetoothConnectionStatus = value; OnPropertyChanged(); }
    }

    public string? BluetoothConnectedDeviceName
    {
        get => _bluetoothConnectedDeviceName;
        set { _bluetoothConnectedDeviceName = value; OnPropertyChanged(); }
    }

    public string? BluetoothErrorMessage
    {
        get => _bluetoothErrorMessage;
        set { _bluetoothErrorMessage = value; OnPropertyChanged(); }
    }

    public ReceiverStatus TargetDeviceReceiverStatus
    {
        get => _targetDeviceReceiverStatus;
        set { _targetDeviceReceiverStatus = value; OnPropertyChanged(); }
    }

    public LanEndpointSource LanEndpointSource
    {
        get => _lanEndpointSource;
        set { _lanEndpointSource = value; OnPropertyChanged(); }
    }

    public StoredLanServerSelection? SelectedLanServer
    {
        get => _selectedLanServer;
        set { _selectedLanServer = value; OnPropertyChanged(); }
    }

    public bool IsConfigured => !string.IsNullOrWhiteSpace(HostUrl);

    public bool IsSendReady =>
        TransferMode == TransferMode.LanServer
            ? IsConfigured
            : BluetoothConnectionStatus == BluetoothConnectionStatus.Connected;

    public ConfigStore()
    {
        Load();
    }

    public void Load()
    {
        HostUrl = ReadCredential(CredentialTargetHost) ?? "";
        AccessToken = ReadCredential(CredentialTargetToken) ?? "";
        LoadDeviceConfig();
    }

    public void Save()
    {
        NormalizeLanSelectionBeforeSave();
        WriteCredential(CredentialTargetHost, HostUrl);
        WriteCredential(CredentialTargetToken, AccessToken);
        PersistConfig();
    }

    public void SaveDeviceConfig(string deviceId, string deviceName)
    {
        DeviceId = deviceId;
        DeviceName = deviceName;
        PersistConfig();
    }

    public void PersistConfig()
    {
        Directory.CreateDirectory(ConfigDir);
        var config = new DeviceConfig
        {
            DeviceId = DeviceId,
            DeviceName = DeviceName,
            TargetDeviceId = TargetDeviceId,
            ShowFloatingBall = ShowFloatingBall,
            FloatingBallX = FloatingBallX,
            FloatingBallY = FloatingBallY,
            TransferMode = TransferMode.ToString(),
            PairedDevices = PairedDevices,
            LanEndpointSource = ToStorageValue(LanEndpointSource),
            SelectedLanServer = SelectedLanServer,
        };
        var json = JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(ConfigFilePath, json);
    }

    private void LoadDeviceConfig()
    {
        if (!File.Exists(ConfigFilePath)) return;

        try
        {
            var json = File.ReadAllText(ConfigFilePath);
            var config = JsonSerializer.Deserialize<DeviceConfig>(json);
            if (config != null)
            {
                DeviceId = config.DeviceId;
                DeviceName = config.DeviceName;
                TargetDeviceId = config.TargetDeviceId;
                ShowFloatingBall = config.ShowFloatingBall;
                if (!double.IsNaN(config.FloatingBallX)) FloatingBallX = config.FloatingBallX;
                if (!double.IsNaN(config.FloatingBallY)) FloatingBallY = config.FloatingBallY;
                if (Enum.TryParse<TransferMode>(config.TransferMode, out var mode))
                    TransferMode = mode;
                if (config.PairedDevices != null)
                    PairedDevices = config.PairedDevices;
                if (TryParseLanEndpointSource(config.LanEndpointSource, out var source))
                    LanEndpointSource = source;
                SelectedLanServer = config.SelectedLanServer;
            }
        }
        catch
        {
            // Corrupt config file — ignore
        }
    }

    public void AddPairedDevice(PairedBluetoothDevice device)
    {
        if (PairedDevices.Any(d => d.Address == device.Address)) return;
        PairedDevices = new List<PairedBluetoothDevice>(PairedDevices) { device };
        PersistConfig();
    }

    public void RemovePairedDevice(ulong address)
    {
        PairedDevices = PairedDevices.Where(d => d.Address != address).ToList();
        PersistConfig();
    }

    public void SelectDiscoveredServer(DiscoveredServer server, LanEndpointSource source = LanEndpointSource.RestoredSelection)
    {
        HostUrl = BuildServerUrl(server.Host, server.Port);
        ServerAuthRequired = server.AuthRequired;
        if (!string.IsNullOrWhiteSpace(server.ServerId))
        {
            SelectedLanServer = new StoredLanServerSelection
            {
                ServerId = server.ServerId,
                Name = server.Name,
                Host = server.Host,
                Port = server.Port,
                Source = ToStorageValue(source),
            };
        }
        else
        {
            SelectedLanServer = null;
        }

        if (!server.AuthRequired)
        {
            AccessToken = "";
        }

        LanEndpointSource = source;
    }

    public void UpdateManualHostUrl(string value)
    {
        HostUrl = value;

        if (SelectedLanServer == null)
        {
            LanEndpointSource = LanEndpointSource.ManualFallback;
            return;
        }

        var trimmedValue = NormalizeHostUrl(value);
        var selectedUrl = BuildServerUrl(SelectedLanServer.Host, SelectedLanServer.Port);
        if (!string.Equals(trimmedValue, NormalizeHostUrl(selectedUrl), StringComparison.OrdinalIgnoreCase))
        {
            SelectedLanServer = null;
            LanEndpointSource = LanEndpointSource.ManualFallback;
        }
    }

    public void UseManualLanFallback()
    {
        SelectedLanServer = null;
        LanEndpointSource = LanEndpointSource.ManualFallback;
    }

    public bool IsSelectedDiscoveredServer(DiscoveredServer server)
    {
        if (!string.IsNullOrWhiteSpace(server.ServerId) &&
            !string.IsNullOrWhiteSpace(SelectedLanServer?.ServerId))
        {
            return string.Equals(server.ServerId, SelectedLanServer.ServerId, StringComparison.Ordinal);
        }

        return string.Equals(
            NormalizeHostUrl(HostUrl),
            NormalizeHostUrl(BuildServerUrl(server.Host, server.Port)),
            StringComparison.OrdinalIgnoreCase);
    }

    private void NormalizeLanSelectionBeforeSave()
    {
        var trimmedHostUrl = NormalizeHostUrl(HostUrl);
        HostUrl = trimmedHostUrl;

        if (string.IsNullOrWhiteSpace(trimmedHostUrl))
        {
            SelectedLanServer = null;
            LanEndpointSource = LanEndpointSource.ManualFallback;
            return;
        }

        if (SelectedLanServer == null)
        {
            LanEndpointSource = LanEndpointSource.ManualFallback;
            return;
        }

        var selectedUrl = NormalizeHostUrl(BuildServerUrl(SelectedLanServer.Host, SelectedLanServer.Port));
        if (!string.Equals(trimmedHostUrl, selectedUrl, StringComparison.OrdinalIgnoreCase))
        {
            SelectedLanServer = null;
            LanEndpointSource = LanEndpointSource.ManualFallback;
            return;
        }

        SelectedLanServer = new StoredLanServerSelection
        {
            ServerId = SelectedLanServer.ServerId,
            Name = SelectedLanServer.Name,
            Host = SelectedLanServer.Host,
            Port = SelectedLanServer.Port,
            Source = ToStorageValue(LanEndpointSource),
        };
    }

    private static string NormalizeHostUrl(string value) =>
        value.Trim().TrimEnd('/');

    private static string BuildServerUrl(string host, int port) =>
        $"http://{host}:{port}";

    private static string ToStorageValue(LanEndpointSource source) => source switch
    {
        LanEndpointSource.AutoDiscovered => "auto_discovered",
        LanEndpointSource.RestoredSelection => "restored_selection",
        _ => "manual_fallback",
    };

    private static bool TryParseLanEndpointSource(string? value, out LanEndpointSource source)
    {
        switch (value)
        {
            case "auto_discovered":
            case nameof(LanEndpointSource.AutoDiscovered):
                source = LanEndpointSource.AutoDiscovered;
                return true;
            case "restored_selection":
            case nameof(LanEndpointSource.RestoredSelection):
                source = LanEndpointSource.RestoredSelection;
                return true;
            case "manual_fallback":
            case nameof(LanEndpointSource.ManualFallback):
                source = LanEndpointSource.ManualFallback;
                return true;
            default:
                source = LanEndpointSource.ManualFallback;
                return false;
        }
    }

    private static string? ReadCredential(string target)
    {
        var cred = new Credential { Target = target };
        if (cred.Load())
        {
            return cred.Password;
        }
        return null;
    }

    private static void WriteCredential(string target, string value)
    {
        var cred = new Credential
        {
            Target = target,
            Password = value,
            PersistanceType = PersistanceType.LocalComputer,
            Type = CredentialType.Generic,
        };
        cred.Save();
    }

    public static void DeleteCredentials()
    {
        new Credential { Target = CredentialTargetHost }.Delete();
        new Credential { Target = CredentialTargetToken }.Delete();
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}

internal class DeviceConfig
{
    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = "";

    [JsonPropertyName("target_device_id")]
    public string TargetDeviceId { get; set; } = "";

    [JsonPropertyName("show_floating_ball")]
    public bool ShowFloatingBall { get; set; } = true;

    [JsonPropertyName("floating_ball_x")]
    public double FloatingBallX { get; set; } = double.NaN;

    [JsonPropertyName("floating_ball_y")]
    public double FloatingBallY { get; set; } = double.NaN;

    [JsonPropertyName("transfer_mode")]
    public string TransferMode { get; set; } = "LanServer";

    [JsonPropertyName("paired_devices")]
    public List<PairedBluetoothDevice>? PairedDevices { get; set; }

    [JsonPropertyName("lan_endpoint_source")]
    public string LanEndpointSource { get; set; } = nameof(CopyEverywhere.Services.LanEndpointSource.ManualFallback);

    [JsonPropertyName("selected_lan_server")]
    public StoredLanServerSelection? SelectedLanServer { get; set; }
}
