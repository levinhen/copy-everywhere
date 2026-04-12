import Foundation
import IOBluetooth

// MARK: - Constants

/// Shared RFCOMM Service UUID for CopyEverywhere across all platforms.
/// CE000001-1000-1000-8000-00805F9B34FB
let kCopyEverywhereServiceUUID = IOBluetoothSDPUUID(
    bytes: [
        0xCE, 0x00, 0x00, 0x01,
        0x10, 0x00,
        0x10, 0x00,
        0x80, 0x00,
        0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB,
    ] as [UInt8],
    length: 16
)

/// String representation of the UUID for cross-platform reference.
let kCopyEverywhereServiceUUIDString = "CE000001-1000-1000-8000-00805F9B34FB"

// MARK: - Delegate protocol

@MainActor
protocol BluetoothServiceDelegate: AnyObject {
    /// Raw connection accepted (server mode) — a BluetoothSession is created and handshake begins automatically.
    func bluetoothService(_ service: BluetoothService, didAcceptConnection channel: IOBluetoothRFCOMMChannel, from device: IOBluetoothDevice)
    /// Raw connection established (client mode) — a BluetoothSession is created and handshake begins automatically.
    func bluetoothService(_ service: BluetoothService, didConnectTo channel: IOBluetoothRFCOMMChannel, device: IOBluetoothDevice)
    func bluetoothService(_ service: BluetoothService, didFailWithError error: Error)
    /// A BluetoothSession completed its handshake and is ready for transfers.
    func bluetoothService(_ service: BluetoothService, sessionReady session: BluetoothSession, device: IOBluetoothDevice)
    /// A BluetoothSession handshake failed.
    func bluetoothService(_ service: BluetoothService, sessionHandshakeFailed session: BluetoothSession, error: Error)
}

// MARK: - Errors

enum BluetoothServiceError: LocalizedError {
    case serviceUUIDNotFound
    case sdpQueryFailed(String)
    case rfcommOpenFailed(IOReturn)
    case noChannelID
    case publishFailed
    case notReady

    var errorDescription: String? {
        switch self {
        case .serviceUUIDNotFound: return "CopyEverywhere RFCOMM service not found on remote device"
        case .sdpQueryFailed(let reason): return "SDP query failed: \(reason)"
        case .rfcommOpenFailed(let code): return "RFCOMM open failed with code: \(code)"
        case .noChannelID: return "Could not determine RFCOMM channel ID from SDP record"
        case .publishFailed: return "Failed to publish RFCOMM SDP service record"
        case .notReady: return "Bluetooth service is not ready"
        }
    }
}

// MARK: - BluetoothService

@MainActor
final class BluetoothService: NSObject, ObservableObject {

    @Published var isServerRunning = false
    @Published var isConnecting = false

    weak var delegate: BluetoothServiceDelegate?

    /// Active session (one at a time for now).
    @Published var activeSession: BluetoothSession?

    private var sdpServiceRecord: IOBluetoothSDPServiceRecord?
    private var serverChannelID: BluetoothRFCOMMChannelID = 0
    private var serverNotification: IOBluetoothUserNotification?

    /// Tracks the device for the pending session (used during handshake).
    private var pendingDevice: IOBluetoothDevice?

    // MARK: - Server mode

    /// Publish an RFCOMM SDP service record and begin accepting inbound connections.
    func startServer() throws {
        guard !isServerRunning else { return }

        // Build SDP service record dictionary
        let serviceName = "CopyEverywhere"
        let sdpDict: [String: Any] = [
            "0001 - ServiceClassIDList": [kCopyEverywhereServiceUUID] as [Any],
            "0004 - ProtocolDescriptorList": [
                [IOBluetoothSDPUUID(uuid16: 0x0100) as Any, // L2CAP
                 IOBluetoothSDPUUID(uuid16: 0x0003) as Any], // RFCOMM
            ] as [[Any]],
            "0100 - ServiceName*": serviceName,
        ]

        let result = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: sdpDict)
        guard let record = result else {
            throw BluetoothServiceError.publishFailed
        }

        sdpServiceRecord = record

        // Read the channel ID the system assigned
        var channelID: BluetoothRFCOMMChannelID = 0
        let status = record.getRFCOMMChannelID(&channelID)
        guard status == kIOReturnSuccess else {
            record.remove()
            sdpServiceRecord = nil
            throw BluetoothServiceError.noChannelID
        }
        serverChannelID = channelID

        // Register for incoming RFCOMM connections on this channel
        serverNotification = IOBluetoothRFCOMMChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(rfcommChannelOpened(_:channel:)),
            withChannelID: channelID,
            direction: kIOBluetoothUserNotificationChannelDirectionIncoming
        )

        isServerRunning = true
    }

    /// Stop accepting inbound connections and remove the SDP record.
    func stopServer() {
        serverNotification?.unregister()
        serverNotification = nil
        sdpServiceRecord?.remove()
        sdpServiceRecord = nil
        isServerRunning = false
    }

    // MARK: - Client mode

    /// Perform SDP query on a remote device to find the CopyEverywhere RFCOMM service,
    /// then establish an RFCOMM connection.
    func connect(to device: IOBluetoothDevice) {
        guard !isConnecting else { return }
        isConnecting = true

        // SDP query runs on IOBluetooth's thread. Use a nonisolated helper.
        let helper = SDPQueryHelper(service: self, device: device)
        helper.performQuery()
    }

    // MARK: - Internal callbacks

    @objc private func rfcommChannelOpened(
        _ notification: IOBluetoothUserNotification,
        channel: IOBluetoothRFCOMMChannel
    ) {
        guard let device = channel.getDevice() else { return }
        Task { @MainActor in
            self.delegate?.bluetoothService(self, didAcceptConnection: channel, from: device)
            self.createSession(channel: channel, device: device)
        }
    }

    nonisolated func notifyClientConnected(channel: IOBluetoothRFCOMMChannel, device: IOBluetoothDevice) {
        Task { @MainActor in
            self.isConnecting = false
            self.delegate?.bluetoothService(self, didConnectTo: channel, device: device)
            self.createSession(channel: channel, device: device)
        }
    }

    // MARK: - Session management

    /// Create a BluetoothSession for the given channel. The session starts the handshake automatically.
    func createSession(channel: IOBluetoothRFCOMMChannel, device: IOBluetoothDevice) {
        // Close any existing session
        activeSession?.close()
        pendingDevice = device
        let session = BluetoothSession(channel: channel)
        session.delegate = self
        activeSession = session
    }

    /// Disconnect the active session.
    func disconnectSession() {
        activeSession?.close()
        activeSession = nil
        pendingDevice = nil
    }

    nonisolated func notifyClientError(_ error: Error) {
        Task { @MainActor in
            self.isConnecting = false
            self.delegate?.bluetoothService(self, didFailWithError: error)
        }
    }

    deinit {
        serverNotification?.unregister()
        sdpServiceRecord?.remove()
    }
}

// MARK: - BluetoothSessionDelegate

extension BluetoothService: BluetoothSessionDelegate {

    func sessionDidComplete(handshake session: BluetoothSession) {
        guard let device = pendingDevice else { return }
        delegate?.bluetoothService(self, sessionReady: session, device: device)
    }

    func session(_ session: BluetoothSession, handshakeFailedWithError error: Error) {
        delegate?.bluetoothService(self, sessionHandshakeFailed: session, error: error)
        if activeSession === session {
            activeSession = nil
            pendingDevice = nil
        }
    }

    func session(_ session: BluetoothSession, didReceive payload: BluetoothTransferPayload) {
        // Forward to higher-level handler — will be wired in US-044 (receive content)
    }

    func session(_ session: BluetoothSession, didFailReceivingWithError error: Error) {
        // Forward to higher-level handler — will be wired in US-044
    }
}

// MARK: - SDP Query Helper

/// Bridges the IOBluetooth delegate-based SDP query to BluetoothService.
/// IOBluetoothDevice's performSDPQuery callback target must be an NSObject.
private class SDPQueryHelper: NSObject {

    private let service: BluetoothService
    private let device: IOBluetoothDevice

    init(service: BluetoothService, device: IOBluetoothDevice) {
        self.service = service
        self.device = device
    }

    func performQuery() {
        let status = device.performSDPQuery(self, uuids: [kCopyEverywhereServiceUUID])
        if status != kIOReturnSuccess {
            service.notifyClientError(
                BluetoothServiceError.sdpQueryFailed("IOReturn \(status)")
            )
        }
    }

    /// IOBluetooth calls this when the SDP query completes.
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard status == kIOReturnSuccess else {
            service.notifyClientError(
                BluetoothServiceError.sdpQueryFailed("IOReturn \(status)")
            )
            return
        }

        guard let records = device.services as? [IOBluetoothSDPServiceRecord] else {
            service.notifyClientError(BluetoothServiceError.serviceUUIDNotFound)
            return
        }

        var targetChannelID: BluetoothRFCOMMChannelID = 0
        var found = false

        for record in records {
            if record.hasService(from: [kCopyEverywhereServiceUUID]) {
                let result = record.getRFCOMMChannelID(&targetChannelID)
                if result == kIOReturnSuccess {
                    found = true
                    break
                }
            }
        }

        guard found else {
            service.notifyClientError(BluetoothServiceError.serviceUUIDNotFound)
            return
        }

        var channel: IOBluetoothRFCOMMChannel?
        let openStatus = device.openRFCOMMChannelAsync(
            &channel,
            withChannelID: targetChannelID,
            delegate: nil
        )

        guard openStatus == kIOReturnSuccess, let channel = channel else {
            service.notifyClientError(BluetoothServiceError.rfcommOpenFailed(openStatus))
            return
        }

        service.notifyClientConnected(channel: channel, device: device)
    }
}
