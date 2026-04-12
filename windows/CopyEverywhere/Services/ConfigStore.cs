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
        WriteCredential(CredentialTargetHost, HostUrl);
        WriteCredential(CredentialTargetToken, AccessToken);
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
}
