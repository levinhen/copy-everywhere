using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;

namespace CopyEverywhere.Services;

/// <summary>
/// Bluetooth RFCOMM connection layer for CopyEverywhere.
/// Server mode: publishes SDP record via RfcommServiceProvider, accepts inbound StreamSocket connections.
/// Client mode: discovers peer CopyEverywhere RFCOMM service via DeviceInformation, connects via StreamSocket.
/// </summary>
public class BluetoothService : INotifyPropertyChanged, IDisposable
{
    /// Shared RFCOMM Service UUID — must match macOS kCopyEverywhereServiceUUID.
    public static readonly Guid CopyEverywhereServiceUuid =
        new Guid("CE000001-1000-1000-8000-00805F9B34FB");

    private RfcommServiceProvider? _serviceProvider;
    private StreamSocketListener? _socketListener;

    private bool _isServerRunning;
    private bool _isConnecting;

    // Active connection (one at a time)
    private StreamSocket? _activeSocket;
    private DataWriter? _activeWriter;
    private DataReader? _activeReader;
    private BluetoothDevice? _connectedDevice;
    private BluetoothSession? _activeSession;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// Fired when the server accepts an inbound RFCOMM connection.
    public event Action<StreamSocket, BluetoothDevice?>? ConnectionAccepted;
    /// Fired when a client-mode connection is established.
    public event Action<StreamSocket, BluetoothDevice?>? Connected;
    /// Fired when a connection attempt (server publish or client connect) fails.
    public event Action<Exception>? ConnectionFailed;
    /// Fired when the session handshake completes and the session is ready for transfers.
    public event Action<BluetoothSession>? SessionReady;
    /// Fired when the session handshake fails.
    public event Action<Exception>? SessionHandshakeFailed;

    public bool IsServerRunning
    {
        get => _isServerRunning;
        private set { _isServerRunning = value; OnPropertyChanged(); }
    }

    public bool IsConnecting
    {
        get => _isConnecting;
        private set { _isConnecting = value; OnPropertyChanged(); }
    }

    public StreamSocket? ActiveSocket => _activeSocket;
    public DataWriter? ActiveWriter => _activeWriter;
    public DataReader? ActiveReader => _activeReader;
    public BluetoothDevice? ConnectedDevice => _connectedDevice;
    public BluetoothSession? ActiveSession => _activeSession;
    public bool IsConnected => _activeSocket != null;

    // ── Server mode ──────────────────────────────────────────────────

    /// Publish an RFCOMM SDP service record and begin accepting inbound connections.
    public async Task StartServerAsync()
    {
        if (IsServerRunning) return;

        try
        {
            var rfcommId = RfcommServiceId.FromUuid(CopyEverywhereServiceUuid);
            _serviceProvider = await RfcommServiceProvider.CreateAsync(rfcommId);

            _socketListener = new StreamSocketListener();
            _socketListener.ConnectionReceived += OnConnectionReceived;
            await _socketListener.BindServiceNameAsync(
                _serviceProvider.ServiceId.AsString(),
                SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication);

            // Set SDP attributes — service name
            using var sdpWriter = new DataWriter();
            sdpWriter.WriteByte(0x25); // UTF-8 string type
            sdpWriter.WriteByte((byte)"CopyEverywhere".Length);
            sdpWriter.WriteString("CopyEverywhere");
            _serviceProvider.SdpRawAttributes[0x0100] = sdpWriter.DetachBuffer();

            _serviceProvider.StartAdvertising(_socketListener);
            IsServerRunning = true;
        }
        catch (Exception ex)
        {
            StopServer();
            ConnectionFailed?.Invoke(ex);
        }
    }

    /// Stop accepting inbound connections and remove the SDP record.
    public void StopServer()
    {
        try
        {
            _serviceProvider?.StopAdvertising();
        }
        catch { /* already stopped */ }

        _socketListener?.Dispose();
        _socketListener = null;
        _serviceProvider = null;
        IsServerRunning = false;
    }

    private async void OnConnectionReceived(
        StreamSocketListener sender,
        StreamSocketListenerConnectionReceivedEventArgs args)
    {
        var socket = args.Socket;

        try
        {
            // Resolve the remote Bluetooth device
            var remoteHost = socket.Information.RemoteHostName;
            BluetoothDevice? device = null;
            if (remoteHost != null)
            {
                try
                {
                    device = await BluetoothDevice.FromHostNameAsync(remoteHost);
                }
                catch
                {
                    // Could not resolve device — proceed with null
                }
            }

            SetActiveConnection(socket, device);
            ConnectionAccepted?.Invoke(socket, device);
        }
        catch (Exception ex)
        {
            ConnectionFailed?.Invoke(ex);
        }
    }

    // ── Client mode ──────────────────────────────────────────────────

    /// Discover peer CopyEverywhere RFCOMM service on the given device and connect.
    public async Task ConnectAsync(DeviceInformation deviceInfo)
    {
        if (IsConnecting) return;
        IsConnecting = true;

        try
        {
            var rfcommService = await RfcommDeviceService.FromIdAsync(deviceInfo.Id);
            if (rfcommService == null)
            {
                throw new InvalidOperationException(
                    "CopyEverywhere RFCOMM service not found on the selected device.");
            }

            var socket = new StreamSocket();
            await socket.ConnectAsync(
                rfcommService.ConnectionHostName,
                rfcommService.ConnectionServiceName,
                SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication);

            var device = rfcommService.Device;
            SetActiveConnection(socket, device);
            Connected?.Invoke(socket, device);
        }
        catch (Exception ex)
        {
            ConnectionFailed?.Invoke(ex);
        }
        finally
        {
            IsConnecting = false;
        }
    }

    /// Connect to a device by Bluetooth address (for reconnecting to known paired devices).
    public async Task ConnectByAddressAsync(ulong bluetoothAddress)
    {
        if (IsConnecting) return;
        IsConnecting = true;

        try
        {
            var device = await BluetoothDevice.FromBluetoothAddressAsync(bluetoothAddress);
            if (device == null)
            {
                throw new InvalidOperationException("Bluetooth device not found.");
            }

            var rfcommId = RfcommServiceId.FromUuid(CopyEverywhereServiceUuid);
            var rfcommServices = await device.GetRfcommServicesForIdAsync(rfcommId);
            if (rfcommServices.Services.Count == 0)
            {
                throw new InvalidOperationException(
                    "CopyEverywhere RFCOMM service not found on the device.");
            }

            var service = rfcommServices.Services[0];
            var socket = new StreamSocket();
            await socket.ConnectAsync(
                service.ConnectionHostName,
                service.ConnectionServiceName,
                SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication);

            SetActiveConnection(socket, device);
            Connected?.Invoke(socket, device);
        }
        catch (Exception ex)
        {
            ConnectionFailed?.Invoke(ex);
        }
        finally
        {
            IsConnecting = false;
        }
    }

    // ── Connection management ────────────────────────────────────────

    private void SetActiveConnection(StreamSocket socket, BluetoothDevice? device)
    {
        // Close any existing connection
        Disconnect();

        _activeSocket = socket;
        _activeWriter = new DataWriter(socket.OutputStream);
        _activeReader = new DataReader(socket.InputStream) { InputStreamOptions = InputStreamOptions.Partial };
        _connectedDevice = device;
        OnPropertyChanged(nameof(IsConnected));
        OnPropertyChanged(nameof(ActiveSocket));
        OnPropertyChanged(nameof(ConnectedDevice));

        // Create session and start handshake
        CreateSession(socket, device);
    }

    private async void CreateSession(StreamSocket socket, BluetoothDevice? device)
    {
        var session = new BluetoothSession(socket, device);
        session.HandshakeCompleted += s => SessionReady?.Invoke(s);
        session.HandshakeFailed += (s, ex) => SessionHandshakeFailed?.Invoke(ex);
        _activeSession = session;
        OnPropertyChanged(nameof(ActiveSession));

        try
        {
            await session.StartAsync();
        }
        catch (Exception ex)
        {
            SessionHandshakeFailed?.Invoke(ex);
        }
    }

    /// Disconnect the active RFCOMM connection.
    public void Disconnect()
    {
        _activeSession?.Dispose();
        _activeSession = null;
        _activeWriter?.Dispose();
        _activeWriter = null;
        _activeReader?.Dispose();
        _activeReader = null;
        _activeSocket?.Dispose();
        _activeSocket = null;
        _connectedDevice?.Dispose();
        _connectedDevice = null;
        OnPropertyChanged(nameof(IsConnected));
        OnPropertyChanged(nameof(ActiveSocket));
        OnPropertyChanged(nameof(ActiveSession));
        OnPropertyChanged(nameof(ConnectedDevice));
    }

    // ── Device discovery (static helpers) ────────────────────────────

    /// Find all nearby devices advertising the CopyEverywhere RFCOMM service.
    /// Returns DeviceInformation objects suitable for ConnectAsync().
    public static async Task<DeviceInformationCollection> FindDevicesAsync()
    {
        var selector = RfcommDeviceService.GetDeviceSelector(
            RfcommServiceId.FromUuid(CopyEverywhereServiceUuid));
        return await DeviceInformation.FindAllAsync(selector);
    }

    // ── INotifyPropertyChanged ───────────────────────────────────────

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    // ── IDisposable ──────────────────────────────────────────────────

    public void Dispose()
    {
        Disconnect();
        StopServer();
    }
}
