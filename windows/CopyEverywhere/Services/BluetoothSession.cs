using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;

namespace CopyEverywhere.Services;

// ── Protocol types ──────────────────────────────────────────────────

public enum BluetoothContentType
{
    Text,
    File
}

public class BluetoothTransferHeader
{
    [JsonPropertyName("type")]
    public string TypeString { get; set; } = "text";

    [JsonIgnore]
    public BluetoothContentType Type
    {
        get => TypeString == "file" ? BluetoothContentType.File : BluetoothContentType.Text;
        set => TypeString = value == BluetoothContentType.File ? "file" : "text";
    }

    [JsonPropertyName("filename")]
    public string Filename { get; set; } = "";

    [JsonPropertyName("size")]
    public int Size { get; set; }
}

public class BluetoothTransferPayload
{
    public BluetoothTransferHeader Header { get; }
    public byte[] Data { get; }

    public BluetoothTransferPayload(BluetoothTransferHeader header, byte[] data)
    {
        Header = header;
        Data = data;
    }
}

// ── Session ─────────────────────────────────────────────────────────

/// <summary>
/// Manages the app-layer protocol on top of a connected RFCOMM StreamSocket.
///
/// Lifecycle:
/// 1. Create with connected StreamSocket → automatically sends handshake
/// 2. HandshakeCompleted event fires on success
/// 3. Use SendTextAsync / SendFileAsync to push content
/// 4. TransferReceived event fires for incoming transfers
/// </summary>
public class BluetoothSession : INotifyPropertyChanged, IDisposable
{
    private static readonly byte[] HandshakeJson =
        Encoding.UTF8.GetBytes("{\"app\":\"CopyEverywhere\",\"version\":\"3.0\"}");
    private const byte Delimiter = 0x0A; // newline
    private const int ChunkSize = 16 * 1024; // 16 KB
    private static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(5);

    private readonly StreamSocket _socket;
    private readonly DataWriter _writer;
    private readonly DataReader _reader;
    private readonly BluetoothDevice? _device;

    private bool _isHandshakeComplete;
    private bool _handshakeSent;
    private bool _handshakeReceived;
    private CancellationTokenSource? _receiveCts;
    private bool _disposed;

    // Receive state machine
    private byte[] _receiveBuffer = Array.Empty<byte>();
    private BluetoothTransferHeader? _pendingHeader;
    private int _bytesRemaining;

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<BluetoothSession>? HandshakeCompleted;
    public event Action<BluetoothSession, Exception>? HandshakeFailed;
    public event Action<BluetoothSession, BluetoothTransferPayload>? TransferReceived;
    public event Action<BluetoothSession, double, BluetoothTransferHeader>? ReceiveProgress;
    public event Action<BluetoothSession, Exception>? ReceiveFailed;

    public bool IsHandshakeComplete
    {
        get => _isHandshakeComplete;
        private set { _isHandshakeComplete = value; OnPropertyChanged(); }
    }

    public BluetoothDevice? Device => _device;

    public BluetoothSession(StreamSocket socket, BluetoothDevice? device)
    {
        _socket = socket;
        _writer = new DataWriter(socket.OutputStream);
        _reader = new DataReader(socket.InputStream) { InputStreamOptions = InputStreamOptions.Partial };
        _device = device;
    }

    /// <summary>
    /// Start the handshake and receive loop. Call once after construction.
    /// </summary>
    public async Task StartAsync()
    {
        _receiveCts = new CancellationTokenSource();
        // Send handshake and start receive loop concurrently
        var sendTask = SendHandshakeAsync();
        var receiveTask = ReceiveLoopAsync(_receiveCts.Token);

        // Wait for handshake send with timeout
        try
        {
            await sendTask;
            _handshakeSent = true;
            CheckHandshakeComplete();
        }
        catch (Exception ex)
        {
            HandshakeFailed?.Invoke(this, ex);
            return;
        }

        // Apply handshake timeout — if not received within 5s, fail
        _ = Task.Run(async () =>
        {
            await Task.Delay(HandshakeTimeout);
            if (!_handshakeReceived && !_disposed)
            {
                _receiveCts?.Cancel();
                HandshakeFailed?.Invoke(this, new TimeoutException("Bluetooth handshake timed out"));
            }
        });

        // Let receive loop run in background (don't await)
        _ = receiveTask;
    }

    private async Task SendHandshakeAsync()
    {
        // Write handshake JSON + delimiter
        _writer.WriteBytes(HandshakeJson);
        _writer.WriteByte(Delimiter);
        await _writer.StoreAsync();
        await _writer.FlushAsync();
    }

    private void CheckHandshakeComplete()
    {
        if (_handshakeSent && _handshakeReceived && !_isHandshakeComplete)
        {
            IsHandshakeComplete = true;
            HandshakeCompleted?.Invoke(this);
        }
    }

    // ── Send ─────────────────────────────────────────────────────────

    /// <summary>
    /// Send a text string to the remote peer.
    /// </summary>
    public async Task SendTextAsync(string text, IProgress<double>? progress = null)
    {
        if (!IsHandshakeComplete)
            throw new InvalidOperationException("Handshake not complete");

        var contentBytes = Encoding.UTF8.GetBytes(text);
        var header = new BluetoothTransferHeader
        {
            Type = BluetoothContentType.Text,
            Filename = "clipboard.txt",
            Size = contentBytes.Length
        };

        var headerBytes = JsonSerializer.SerializeToUtf8Bytes(header);
        _writer.WriteBytes(headerBytes);
        _writer.WriteByte(Delimiter);
        _writer.WriteBytes(contentBytes);
        await _writer.StoreAsync();
        await _writer.FlushAsync();
        progress?.Report(1.0);
    }

    /// <summary>
    /// Send a file to the remote peer, streaming in chunks to avoid OOM.
    /// </summary>
    public async Task SendFileAsync(string filePath, IProgress<double>? progress = null)
    {
        if (!IsHandshakeComplete)
            throw new InvalidOperationException("Handshake not complete");

        var fileInfo = new FileInfo(filePath);
        if (!fileInfo.Exists)
            throw new FileNotFoundException("File not found", filePath);

        var totalSize = (int)fileInfo.Length;
        var header = new BluetoothTransferHeader
        {
            Type = BluetoothContentType.File,
            Filename = fileInfo.Name,
            Size = totalSize
        };

        // Send header + delimiter
        var headerBytes = JsonSerializer.SerializeToUtf8Bytes(header);
        _writer.WriteBytes(headerBytes);
        _writer.WriteByte(Delimiter);
        await _writer.StoreAsync();
        await _writer.FlushAsync();

        // Stream file content in chunks
        using var stream = File.OpenRead(filePath);
        var buffer = new byte[ChunkSize];
        var totalSent = 0;

        while (totalSent < totalSize)
        {
            var readSize = Math.Min(ChunkSize, totalSize - totalSent);
            var bytesRead = await stream.ReadAsync(buffer, 0, readSize);
            if (bytesRead == 0) break;

            _writer.WriteBytes(buffer.AsSpan(0, bytesRead).ToArray());
            await _writer.StoreAsync();

            totalSent += bytesRead;
            if (totalSize > 0)
                progress?.Report((double)totalSent / totalSize);
        }

        await _writer.FlushAsync();
        progress?.Report(1.0);
    }

    // ── Receive loop ─────────────────────────────────────────────────

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested && !_disposed)
            {
                var loaded = await _reader.LoadAsync(ChunkSize).AsTask(ct);
                if (loaded == 0) break; // Connection closed

                var chunk = new byte[loaded];
                _reader.ReadBytes(chunk);

                // Append to buffer
                var newBuffer = new byte[_receiveBuffer.Length + chunk.Length];
                Buffer.BlockCopy(_receiveBuffer, 0, newBuffer, 0, _receiveBuffer.Length);
                Buffer.BlockCopy(chunk, 0, newBuffer, _receiveBuffer.Length, chunk.Length);
                _receiveBuffer = newBuffer;

                ProcessReceivedData();
            }
        }
        catch (OperationCanceledException) { /* shutdown */ }
        catch (Exception ex)
        {
            if (!_disposed)
            {
                if (!_handshakeReceived)
                    HandshakeFailed?.Invoke(this, ex);
                else
                    ReceiveFailed?.Invoke(this, ex);
            }
        }
    }

    private void ProcessReceivedData()
    {
        if (!_handshakeReceived)
        {
            ProcessHandshakeData();
            return;
        }

        ProcessTransferData();
    }

    private void ProcessHandshakeData()
    {
        var delimiterIndex = Array.IndexOf(_receiveBuffer, Delimiter);
        if (delimiterIndex < 0) return; // Wait for complete handshake line

        var lineBytes = new byte[delimiterIndex];
        Buffer.BlockCopy(_receiveBuffer, 0, lineBytes, 0, delimiterIndex);

        // Remove consumed bytes (including delimiter)
        var remaining = _receiveBuffer.Length - delimiterIndex - 1;
        var newBuffer = new byte[remaining];
        if (remaining > 0)
            Buffer.BlockCopy(_receiveBuffer, delimiterIndex + 1, newBuffer, 0, remaining);
        _receiveBuffer = newBuffer;

        // Parse handshake
        try
        {
            using var doc = JsonDocument.Parse(lineBytes);
            var root = doc.RootElement;
            if (root.TryGetProperty("app", out var appProp) && appProp.GetString() == "CopyEverywhere")
            {
                _handshakeReceived = true;
                CheckHandshakeComplete();

                // Process any remaining data as transfer data
                if (_receiveBuffer.Length > 0)
                    ProcessTransferData();
                return;
            }
        }
        catch { /* fall through to failure */ }

        HandshakeFailed?.Invoke(this, new InvalidOperationException("Bluetooth handshake mismatch"));
    }

    private void ProcessTransferData()
    {
        // If we don't have a pending header yet, try to parse one
        if (_pendingHeader == null)
        {
            var delimiterIndex = Array.IndexOf(_receiveBuffer, Delimiter);
            if (delimiterIndex < 0) return; // Wait for complete header line

            var headerBytes = new byte[delimiterIndex];
            Buffer.BlockCopy(_receiveBuffer, 0, headerBytes, 0, delimiterIndex);

            // Remove consumed bytes
            var remaining = _receiveBuffer.Length - delimiterIndex - 1;
            var newBuffer = new byte[remaining];
            if (remaining > 0)
                Buffer.BlockCopy(_receiveBuffer, delimiterIndex + 1, newBuffer, 0, remaining);
            _receiveBuffer = newBuffer;

            try
            {
                _pendingHeader = JsonSerializer.Deserialize<BluetoothTransferHeader>(headerBytes);
                if (_pendingHeader == null)
                {
                    ReceiveFailed?.Invoke(this, new InvalidOperationException("Invalid transfer header"));
                    return;
                }
                _bytesRemaining = _pendingHeader.Size;
            }
            catch (Exception ex)
            {
                ReceiveFailed?.Invoke(this, ex);
                return;
            }
        }

        // Collect content bytes
        var header = _pendingHeader!;

        // Report receive progress
        if (header.Size > 0)
        {
            var received = header.Size - _bytesRemaining + Math.Min(_receiveBuffer.Length, _bytesRemaining);
            var prog = Math.Min((double)received / header.Size, 1.0);
            ReceiveProgress?.Invoke(this, prog, header);
        }

        if (_receiveBuffer.Length >= _bytesRemaining)
        {
            // We have all the content
            var contentData = new byte[_bytesRemaining];
            Buffer.BlockCopy(_receiveBuffer, 0, contentData, 0, _bytesRemaining);

            // Remove consumed bytes
            var leftover = _receiveBuffer.Length - _bytesRemaining;
            var leftoverBuffer = new byte[leftover];
            if (leftover > 0)
                Buffer.BlockCopy(_receiveBuffer, _bytesRemaining, leftoverBuffer, 0, leftover);
            _receiveBuffer = leftoverBuffer;

            _pendingHeader = null;
            _bytesRemaining = 0;

            // Verify size
            if (contentData.Length != header.Size)
            {
                ReceiveFailed?.Invoke(this,
                    new InvalidOperationException($"Size mismatch: expected {header.Size} bytes, received {contentData.Length} bytes"));
                return;
            }

            var payload = new BluetoothTransferPayload(header, contentData);
            TransferReceived?.Invoke(this, payload);

            // Process any remaining data (next transfer)
            if (_receiveBuffer.Length > 0)
                ProcessTransferData();
        }
    }

    // ── Cleanup ──────────────────────────────────────────────────────

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _receiveCts?.Cancel();
        _receiveCts?.Dispose();
        _writer.Dispose();
        _reader.Dispose();
        // Socket is owned by BluetoothService — not disposed here
    }
}
