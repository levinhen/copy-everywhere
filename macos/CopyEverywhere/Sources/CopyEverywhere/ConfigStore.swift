import AppKit
import Combine
import Foundation
import IOBluetooth
import Network
import UserNotifications

struct ClipResult {
    let id: String
    let expiresAt: Date
}

struct DeviceInfo: Identifiable, Equatable, Hashable {
    enum ReceiverStatus: String, Equatable, Hashable {
        case online
        case degraded
        case offline

        init(serverValue: String?) {
            switch serverValue {
            case "online":
                self = .online
            case "degraded":
                self = .degraded
            default:
                self = .offline
            }
        }

        var label: String {
            switch self {
            case .online:
                return "Online"
            case .degraded:
                return "Degraded"
            case .offline:
                return "Offline"
            }
        }
    }

    let id: String
    let name: String
    let platform: String
    let lastSeenAt: Date
    let receiverStatus: ReceiverStatus
}

enum SSEConnectionState: Equatable {
    case disconnected
    case reconnecting
    case connected
}

struct QueueItem: Identifiable, Equatable {
    enum DeliveryState: Equatable {
        case queue
        case targetedFallback

        init(serverValue: String?) {
            switch serverValue {
            case "targeted_fallback":
                self = .targetedFallback
            default:
                self = .queue
            }
        }

        var badgeLabel: String? {
            switch self {
            case .queue:
                return nil
            case .targetedFallback:
                return "Queue fallback"
            }
        }
    }

    let id: String
    let type: String
    let filename: String?
    let sizeBytes: Int64
    let createdAt: Date
    let expiresAt: Date
    let deliveryState: DeliveryState
    let targetDeviceID: String?

    var typeIcon: String {
        switch type {
        case "text": return "doc.text"
        case "image": return "photo"
        default: return "doc"
        }
    }

    var preview: String {
        if let filename = filename, filename != "clipboard.txt" {
            return filename
        }
        if type == "text" { return "Text clip" }
        if type == "image" { return "Image" }
        return filename ?? "File"
    }

    var age: String {
        let interval = Date().timeIntervalSince(createdAt)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}

// MARK: - Transfer Mode

enum TransferMode: String, CaseIterable {
    case lanServer = "LAN Server"
    case bluetooth = "Bluetooth Direct"
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published var hostURL: String = ""
    @Published var accessToken: String = ""
    @Published var isConfigured: Bool = false
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var sendStatus: SendStatus = .idle
    @Published var receiveStatus: ReceiveStatus = .idle
    @Published var fileUploadStatus: FileUploadStatus = .idle
    @Published var fileUploadProgress: Double = 0
    @Published var fileUploadSpeed: String = ""
    @Published var fileDownloadStatus: FileDownloadStatus = .idle
    @Published var fileDownloadProgress: Double = 0
    @Published var fileDownloadSpeed: String = ""
    @Published var deviceID: String = ""
    @Published var deviceName: String = ""
    @Published var toastMessage: String? = nil
    @Published var queueItems: [QueueItem] = []
    @Published var queueError: String? = nil
    @Published var autoReceiveWarning: String? = nil
    @Published var availableDevices: [DeviceInfo] = []
    @Published var targetDeviceID: String? = nil  // nil means "Queue — any device"
    @Published var serverAuthRequired: Bool? = nil  // nil = unknown, from mDNS TXT or /health
    @Published var lanEndpointSource: LanEndpointSource = .manualFallback
    @Published var selectedLanServer: StoredLanServerSelection? = nil
    @Published var sseConnectionState: SSEConnectionState = .disconnected
    @Published var sseStatusDetail: String = "Configure a LAN server to enable targeted auto-delivery."
    @Published var localServerEnabled: Bool = false
    @Published var localServerStatus: LocalServerStatus = .stopped
    @Published var localServerLogs: [String] = []

    // Bluetooth state
    @Published var transferMode: TransferMode = .lanServer
    @Published var pairedDevices: [PairedBluetoothDevice] = []
    @Published var bluetoothConnectionStatus: BluetoothConnectionStatus = .disconnected
    @Published var bluetoothConnectedDeviceName: String?
    @Published var bluetoothReceiveProgress: Double = 0
    @Published var bluetoothReceiveFilename: String?

    let bonjourBrowser = BonjourBrowser()
    let bluetoothDiscovery = BluetoothDiscovery()
    let bluetoothService = BluetoothService()

    /// Whether the app is ready to send content (LAN configured or Bluetooth connected).
    var isSendReady: Bool {
        switch transferMode {
        case .lanServer:
            return isConfigured
        case .bluetooth:
            return bluetoothConnectionStatus == .connected
                && bluetoothService.activeSession?.isHandshakeComplete == true
        }
    }

    var selectedTargetDevice: DeviceInfo? {
        guard let targetDeviceID else { return nil }
        return availableDevices.first { $0.id == targetDeviceID }
    }

    var selectedTargetFallbackWarning: String? {
        guard transferMode == .lanServer, let device = selectedTargetDevice else { return nil }

        switch device.receiverStatus {
        case .online:
            return nil
        case .degraded:
            return "\(device.name) is reconnecting or stale. This send may fall back to the queue instead of auto-delivering."
        case .offline:
            return "\(device.name) is offline for targeted auto-delivery. This send will likely wait in the queue until they reconnect or receive it manually."
        }
    }

    var lanDeliveryModeTitle: String {
        guard transferMode == .lanServer else { return "Bluetooth direct" }
        return selectedTargetDevice == nil ? "Queue mode" : "Targeted auto-delivery"
    }

    var lanDeliveryModeDetail: String {
        guard transferMode == .lanServer else {
            return "Bluetooth sends transfer directly to the connected device."
        }

        guard let device = selectedTargetDevice else {
            return "Sends stay in queue mode and remain available for manual receive on any registered device."
        }

        switch device.receiverStatus {
        case .online:
            return "\(device.name) is online. The clip will wait for that device to auto-receive it first."
        case .degraded:
            return "\(device.name) looks degraded. Automatic delivery may miss and then fall back to the queue."
        case .offline:
            return "\(device.name) is offline. Automatic delivery will likely miss and then fall back to the queue."
        }
    }

    var sendSuccessDetail: String {
        guard transferMode == .lanServer else {
            return "Bluetooth direct transfer completed to the connected device."
        }

        guard let device = selectedTargetDevice else {
            return "Queue mode: the clip is available for manual receive on any device."
        }

        switch device.receiverStatus {
        case .online:
            return "Targeted auto-delivery is waiting for \(device.name) to auto-receive the clip."
        case .degraded:
            return "Targeted auto-delivery notified \(device.name), but the clip may fall back to the queue."
        case .offline:
            return "Targeted auto-delivery targeted \(device.name), but the clip will likely fall back to the queue."
        }
    }

    enum BluetoothConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    // SSE state
    private var sseTask: Task<Void, Never>?
    private var sseRetryDelay: TimeInterval = 1.0
    private let sseMaxRetryDelay: TimeInterval = 30.0
    @Published var sseStatusDescription: String = "Disconnected"
    private var queueAutoReceiveTask: Task<Void, Never>?
    private var queueAutoReceiveInFlight = Set<String>()

    private let service = "com.copyeverywhere.relay"
    private let maxSmallFileSize: Int64 = 50 * 1024 * 1024 // 50MB
    private let chunkSize: Int64 = 10 * 1024 * 1024 // 10MB chunks
    private let hostKey = "com.copyeverywhere.hostURL"
    private let tokenKey = "com.copyeverywhere.accessToken"
    private let selectedLanServerKey = "com.copyeverywhere.selectedLanServer"
    private let lanEndpointSourceKey = "com.copyeverywhere.lanEndpointSource"
    private let localServerEnabledKey = "com.copyeverywhere.localServerEnabled"
    private static let localServerConfigURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("CopyEverywhereServer")
            .appendingPathComponent("config.json")
    }()

    // Chunked upload state
    private var chunkedUploadID: String?
    private var chunkedUploadFileURL: URL?
    private var chunkedUploadTask: Task<Void, Never>?
    private var chunkedIsPaused = false

    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case success(latencyMs: Int)
        case error(String)
    }

    enum SendStatus: Equatable {
        case idle
        case sending
        case success(clipID: String, expiresAt: String)
        case error(String)
    }

    enum ReceiveStatus: Equatable {
        case idle
        case receiving
        case success(String)
        case noContent
        case error(String)
    }

    enum FileUploadStatus: Equatable {
        case idle
        case uploading(filename: String)
        case chunkedUploading(filename: String, currentChunk: Int, totalChunks: Int)
        case chunkedPaused(filename: String, currentChunk: Int, totalChunks: Int)
        case success(clipID: String, filename: String, fileSize: String, expiresAt: String)
        case error(String)
    }

    struct ClipMetadata: Equatable {
        let id: String
        let type: String
        let filename: String?
        let sizeBytes: Int64
        let createdAt: String
        let expiresAt: String
    }

    enum FileDownloadStatus: Equatable {
        case idle
        case fetchingMetadata
        case metadataLoaded(ClipMetadata)
        case downloading(filename: String)
        case success(savedPath: String)
        case uploadIncomplete
        case error(String)
    }

    enum LocalServerStatus: Equatable {
        case stopped
        case starting
        case running(pid: Int32)
        case error(String)
    }

    private let pairedDevicesKey = "com.copyeverywhere.pairedBluetoothDevices"
    private let transferModeKey = "com.copyeverywhere.transferMode"
    private let maxLocalServerLogLines = 200
    private var localServerProcess: Process?
    private var localServerStopRequested = false
    private var localServerRestartRequested = false
    private var bonjourServersObserver: AnyCancellable?

    init() {
        loadPersistedConfig()
        deviceID = UserDefaults.standard.string(forKey: "com.copyeverywhere.deviceID") ?? ""
        deviceName = UserDefaults.standard.string(forKey: "com.copyeverywhere.deviceName") ?? ""
        loadPairedDevices()
        loadTransferMode()
        observeLanDiscovery()
        if transferMode == .lanServer {
            startLanDiscoveryIfNeeded()
        }
        bluetoothService.delegate = self
        startQueueAutoReceivePollingIfNeeded()
    }

    func loadLocalServerPreset() -> (hostURL: String, authEnabled: Bool, accessToken: String)? {
        guard localServerEnabled else { return nil }
        let config = loadEffectiveLocalServerConfig()
        let port = config.port.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPort = port.isEmpty ? "8080" : port
        return (
            hostURL: "http://localhost:\(resolvedPort)",
            authEnabled: config.authEnabled,
            accessToken: config.authEnabled ? config.accessToken : ""
        )
    }

    func applyLocalServerPreset() {
        guard localServerEnabled else { return }
        guard let preset = loadLocalServerPreset() else { return }
        hostURL = preset.hostURL
        serverAuthRequired = preset.authEnabled
        accessToken = preset.accessToken
        isConfigured = true
        restartSSEConnection(reason: "local server preset applied")
    }

    var localServerStatusDescription: String {
        switch localServerStatus {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting..."
        case .running(let pid):
            return "Running (pid \(pid))"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    func selectDiscoveredServer(_ server: DiscoveredServer) {
        hostURL = server.endpointURLString
        serverAuthRequired = server.authRequired
        if let serverID = server.serverID {
            selectedLanServer = StoredLanServerSelection(
                serverID: serverID,
                name: server.name,
                host: server.host,
                port: server.port,
                source: .restoredSelection
            )
        }
        if !server.authRequired {
            accessToken = ""
        }
        lanEndpointSource = .restoredSelection
    }

    func useManualLanFallback() {
        selectedLanServer = nil
        lanEndpointSource = .manualFallback
    }

    func updateManualHostURL(_ value: String) {
        hostURL = value

        guard let selectedLanServer else {
            lanEndpointSource = .manualFallback
            return
        }

        let trimmedValue = normalizedHostURL(value)
        let selectedURL = normalizedHostURL("http://\(selectedLanServer.host):\(selectedLanServer.port)")
        if trimmedValue != selectedURL {
            self.selectedLanServer = nil
            lanEndpointSource = .manualFallback
        }
    }

    func isSelectedDiscoveredServer(_ server: DiscoveredServer) -> Bool {
        if let serverID = server.serverID,
           let selectedServerID = selectedLanServer?.serverID {
            return serverID == selectedServerID
        }
        return normalizedHostURL(hostURL) == normalizedHostURL(server.endpointURLString)
    }

    var lanEndpointSourceTitle: String {
        switch lanEndpointSource {
        case .autoDiscovered:
            return "Auto-discovered server"
        case .restoredSelection:
            return selectedLanServer == nil ? "Discovered server selected" : "Restored server selection"
        case .manualFallback:
            return "Manual URL fallback"
        }
    }

    var lanEndpointSourceDetail: String {
        switch lanEndpointSource {
        case .autoDiscovered:
            if let selectedLanServer {
                return "Exactly one LAN server was found, so CopyEverywhere auto-selected \(selectedLanServer.name)."
            }
            return "Exactly one LAN server was found, so CopyEverywhere auto-selected it."
        case .restoredSelection:
            if let selectedLanServer {
                return "CopyEverywhere is using the discovered server \(selectedLanServer.name) by stable server ID instead of a stale IP."
            }
            return "CopyEverywhere is using a discovered LAN server selected by stable server ID."
        case .manualFallback:
            let trimmedHost = normalizedHostURL(hostURL)
            if trimmedHost.isEmpty {
                return "No server is selected yet. Enter a Host URL below or choose a discovered server."
            }
            return "The current LAN endpoint comes from the manual Host URL field, so discovery failures stay non-fatal."
        }
    }

    var lanDiscoveryGuidance: String? {
        let discoveredServers = bonjourBrowser.discoveredServers
        if discoveredServers.count > 1,
           selectedLanServer == nil,
           normalizedHostURL(hostURL).isEmpty {
            return "Multiple LAN servers were found. Choose one below or keep using a manual URL fallback."
        }

        if discoveredServers.isEmpty, !bonjourBrowser.isSearching {
            return "No LAN servers are currently visible. A saved manual URL can still be used below."
        }

        return nil
    }

    // MARK: - Bluetooth Pairing & Connection

    /// Pair with a discovered Bluetooth device. Triggers system pairing dialog if needed.
    func pairBluetoothDevice(_ discovered: DiscoveredBluetoothDevice) {
        bluetoothConnectionStatus = .connecting

        let device = discovered.device

        // IOBluetoothDevice.openConnection triggers system-level pairing if not already paired
        let pairHelper = BluetoothPairHelper(configStore: self, device: device, discoveredDevice: discovered)
        currentPairHelper = pairHelper
        pairHelper.startPairing()
    }

    /// Called after system pairing + RFCOMM connection + handshake succeeds.
    fileprivate func bluetoothPairingSucceeded(device: IOBluetoothDevice, discovered: DiscoveredBluetoothDevice) {
        let paired = PairedBluetoothDevice(
            id: discovered.id,
            name: discovered.name,
            address: discovered.address
        )
        if !pairedDevices.contains(where: { $0.id == paired.id }) {
            pairedDevices.append(paired)
            savePairedDevices()
        }
        bluetoothConnectionStatus = .connected
        bluetoothConnectedDeviceName = discovered.name
    }

    /// Disconnect from the active Bluetooth session.
    func disconnectBluetooth() {
        bluetoothService.disconnectSession()
        bluetoothConnectionStatus = .disconnected
        bluetoothConnectedDeviceName = nil
    }

    /// Forget a paired device (remove from saved list and disconnect if active).
    func forgetBluetoothDevice(_ device: PairedBluetoothDevice) {
        if bluetoothConnectedDeviceName == device.name {
            disconnectBluetooth()
        }
        pairedDevices.removeAll { $0.id == device.id }
        savePairedDevices()
    }

    /// Reconnect to a previously paired device.
    func reconnectBluetoothDevice(_ paired: PairedBluetoothDevice) {
        guard let device = IOBluetoothDevice(addressString: paired.address) else {
            bluetoothConnectionStatus = .error("Could not find device: \(paired.name)")
            return
        }
        bluetoothConnectionStatus = .connecting
        bluetoothService.connect(to: device)
    }

    /// Auto-reconnect to the first paired device on launch (if in Bluetooth mode).
    func autoReconnectBluetooth() {
        guard transferMode == .bluetooth else { return }
        // Always start RFCOMM server in Bluetooth mode so we can receive inbound connections
        startBluetoothServerIfNeeded()
        guard !pairedDevices.isEmpty else { return }
        guard case .disconnected = bluetoothConnectionStatus else { return }
        reconnectBluetoothDevice(pairedDevices[0])
    }

    // MARK: - Bluetooth Persistence

    private func savePairedDevices() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            UserDefaults.standard.set(data, forKey: pairedDevicesKey)
        }
    }

    private func loadPairedDevices() {
        guard let data = UserDefaults.standard.data(forKey: pairedDevicesKey),
              let devices = try? JSONDecoder().decode([PairedBluetoothDevice].self, from: data) else { return }
        pairedDevices = devices
    }

    private func saveTransferMode() {
        UserDefaults.standard.set(transferMode.rawValue, forKey: transferModeKey)
    }

    private func loadTransferMode() {
        if let raw = UserDefaults.standard.string(forKey: transferModeKey),
           let mode = TransferMode(rawValue: raw) {
            transferMode = mode
        }
    }

    func setTransferMode(_ mode: TransferMode) {
        transferMode = mode
        saveTransferMode()

        if mode == .bluetooth {
            // Stop LAN services, start Bluetooth
            bonjourBrowser.stopBrowsing()
            stopSSE()
            stopQueueAutoReceivePolling()
            startBluetoothServerIfNeeded()
        } else {
            // Stop Bluetooth, restart LAN services
            bluetoothService.stopServer()
            startLanDiscoveryIfNeeded()
            startSSE()
            startQueueAutoReceivePollingIfNeeded()
            // Resume queue polling if panel is open
            Task { await fetchQueue() }
        }
    }

    /// Start the RFCOMM server so this device can accept inbound Bluetooth connections.
    private func startBluetoothServerIfNeeded() {
        guard !bluetoothService.isServerRunning else { return }
        do {
            try bluetoothService.startServer()
        } catch {
            print("Failed to start Bluetooth RFCOMM server: \(error)")
        }
    }

    /// Helper retained during pairing flow.
    fileprivate var currentPairHelper: BluetoothPairHelper?

    // MARK: - Keychain Operations

    func save() {
        normalizeLanSelectionBeforeSave()
        UserDefaults.standard.set(hostURL, forKey: hostKey)
        UserDefaults.standard.set(accessToken, forKey: tokenKey)
        UserDefaults.standard.set(lanEndpointSource.rawValue, forKey: lanEndpointSourceKey)
        if let selectedLanServer,
           let data = try? JSONEncoder().encode(selectedLanServer) {
            UserDefaults.standard.set(data, forKey: selectedLanServerKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedLanServerKey)
        }
        isConfigured = !hostURL.isEmpty
        if !isConfigured {
            sseConnectionState = .disconnected
            sseStatusDetail = "Configure a LAN server to enable targeted auto-delivery."
        }
        if isConfigured {
            Task {
                await registerDevice()
                // Restart SSE with new credentials
                stopSSE()
                startSSE()
                startQueueAutoReceivePollingIfNeeded()
            }
        } else {
            stopQueueAutoReceivePolling()
        }
    }

    func registerDevice() async {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(urlString)/api/v1/devices/register") else { return }

        let name = Host.current().localizedName ?? "Mac"
        let payload: [String: String] = ["name": name, "platform": "macos"]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        setAuthHeader(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = json["device_id"] as? String {
                deviceID = id
                deviceName = name
                UserDefaults.standard.set(id, forKey: "com.copyeverywhere.deviceID")
                UserDefaults.standard.set(name, forKey: "com.copyeverywhere.deviceName")
            }
        } catch {
            // Registration is best-effort — don't block the save flow
        }
    }

    func clearConfig() {
        stopSSE()
        UserDefaults.standard.removeObject(forKey: hostKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: selectedLanServerKey)
        UserDefaults.standard.removeObject(forKey: lanEndpointSourceKey)
        hostURL = ""
        accessToken = ""
        selectedLanServer = nil
        lanEndpointSource = .manualFallback
        isConfigured = false
        connectionStatus = .idle
        sseConnectionState = .disconnected
        sseStatusDetail = "Configure a LAN server to enable targeted auto-delivery."
        stopQueueAutoReceivePolling()
        stopSSE()
        stopQueueAutoReceivePolling()
        sseStatusDescription = "Disconnected"
    }

    private func loadPersistedConfig() {
        hostURL = UserDefaults.standard.string(forKey: hostKey) ?? ""
        accessToken = UserDefaults.standard.string(forKey: tokenKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: selectedLanServerKey),
           let selection = try? JSONDecoder().decode(StoredLanServerSelection.self, from: data) {
            selectedLanServer = selection
        }
        if let rawSource = UserDefaults.standard.string(forKey: lanEndpointSourceKey),
           let source = LanEndpointSource(rawValue: rawSource) {
            lanEndpointSource = source
        } else if let selection = selectedLanServer {
            lanEndpointSource = selection.source
        }
        isConfigured = !hostURL.isEmpty
        if isConfigured {
            sseStatusDetail = "Waiting to connect targeted auto-delivery."
        }
    }

    private func observeLanDiscovery() {
        bonjourServersObserver = bonjourBrowser.$discoveredServers
            .sink { [weak self] servers in
                self?.handleLanDiscoveryResults(servers)
            }
    }

    private func startLanDiscoveryIfNeeded() {
        bonjourBrowser.startBrowsing()
        handleLanDiscoveryResults(bonjourBrowser.discoveredServers)
    }

    private func handleLanDiscoveryResults(_ servers: [DiscoveredServer]) {
        guard transferMode == .lanServer else { return }

        if restorePersistedLanSelection(from: servers) {
            return
        }

        if selectedLanServer != nil {
            if lanEndpointSource != .manualFallback {
                lanEndpointSource = .manualFallback
                persistLanSelectionState()
                appendLocalServerLog("LAN discovery: selected server not found; keeping manual fallback URL")
            }
            return
        }

        let trimmedHostURL = normalizedHostURL(hostURL)
        guard trimmedHostURL.isEmpty else { return }

        if servers.count == 1, let server = servers.first {
            applyDiscoveredLanServer(server, source: .autoDiscovered, reason: "unique discovered server auto-selected")
        } else if servers.count > 1 {
            appendLocalServerLog("LAN discovery: multiple servers found; waiting for explicit selection")
        }
    }

    @discardableResult
    private func restorePersistedLanSelection(from servers: [DiscoveredServer]) -> Bool {
        guard let storedSelection = selectedLanServer else { return false }
        guard let server = servers.first(where: { $0.serverID == storedSelection.serverID }) else { return false }

        applyDiscoveredLanServer(server, source: .restoredSelection, reason: "persisted server restored from discovery")
        return true
    }

    private func applyDiscoveredLanServer(
        _ server: DiscoveredServer,
        source: LanEndpointSource,
        reason: String
    ) {
        let previousHostURL = normalizedHostURL(hostURL)
        let nextHostURL = normalizedHostURL(server.endpointURLString)
        let previousSource = lanEndpointSource
        let previousSelection = selectedLanServer

        hostURL = server.endpointURLString
        serverAuthRequired = server.authRequired
        if let serverID = server.serverID {
            selectedLanServer = StoredLanServerSelection(
                serverID: serverID,
                name: server.name,
                host: server.host,
                port: server.port,
                source: source
            )
        }
        if !server.authRequired {
            accessToken = ""
        }
        lanEndpointSource = source
        isConfigured = !hostURL.isEmpty
        persistLanSelectionState()

        let selectionChanged = previousSelection != selectedLanServer
        let shouldReconnect = previousHostURL != nextHostURL || previousSource != source || selectionChanged
        guard shouldReconnect else { return }

        appendLocalServerLog("LAN discovery: \(reason) -> \(server.host):\(server.port)")
        Task {
            await registerDevice()
            restartSSEConnection(reason: reason)
            startQueueAutoReceivePollingIfNeeded()
            await fetchQueue()
        }
    }

    private func persistLanSelectionState() {
        UserDefaults.standard.set(hostURL, forKey: hostKey)
        UserDefaults.standard.set(lanEndpointSource.rawValue, forKey: lanEndpointSourceKey)
        if let selectedLanServer,
           let data = try? JSONEncoder().encode(selectedLanServer) {
            UserDefaults.standard.set(data, forKey: selectedLanServerKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedLanServerKey)
        }
    }

    private func normalizeLanSelectionBeforeSave() {
        let trimmedHostURL = normalizedHostURL(hostURL)
        if trimmedHostURL.isEmpty {
            selectedLanServer = nil
            lanEndpointSource = .manualFallback
            return
        }

        guard let selectedLanServer else {
            lanEndpointSource = .manualFallback
            return
        }

        let selectedURL = normalizedHostURL("http://\(selectedLanServer.host):\(selectedLanServer.port)")
        guard trimmedHostURL == selectedURL else {
            self.selectedLanServer = nil
            lanEndpointSource = .manualFallback
            return
        }

        self.selectedLanServer = StoredLanServerSelection(
            serverID: selectedLanServer.serverID,
            name: selectedLanServer.name,
            host: selectedLanServer.host,
            port: selectedLanServer.port,
            source: lanEndpointSource
        )
    }

    private func normalizedHostURL(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func applyLocalServerConfigIfNeeded() {
        let trimmedHost = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard localServerEnabled, trimmedHost.isEmpty else { return }
        applyLocalServerPreset()
    }

    func setLocalServerEnabled(_ enabled: Bool) {
        localServerEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: localServerEnabledKey)

        if enabled {
            ensureLocalServerConfigExists()
            applyLocalServerConfigIfNeeded()
            startLocalServerIfNeeded()
        } else {
            stopLocalServer()
        }
    }

    func shutdown() {
        stopQueueAutoReceivePolling()
        stopSSE()
        stopLocalServer()
        bluetoothService.stopServer()
        bluetoothService.disconnectSession()
    }

    private func startQueueAutoReceivePollingIfNeeded() {
        guard transferMode == .lanServer, isConfigured, !deviceID.isEmpty else { return }
        guard queueAutoReceiveTask == nil else { return }
        queueAutoReceiveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchQueue()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func stopQueueAutoReceivePolling() {
        queueAutoReceiveTask?.cancel()
        queueAutoReceiveTask = nil
        queueAutoReceiveInFlight.removeAll()
    }

    private func ensureLocalServerConfigExists() {
        let configURL = Self.localServerConfigURL
        let directoryURL = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        let config = LocalServerConfigData.defaultConfig(baseDirectory: directoryURL)
        persistLocalServerConfig(config)
    }

    private func persistLocalServerConfig(_ config: LocalServerConfigData) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: Self.localServerConfigURL, options: .atomic)
        }
    }

    private func loadEffectiveLocalServerConfig() -> LocalServerConfigData {
        let directoryURL = Self.localServerConfigURL.deletingLastPathComponent()
        let fallback = LocalServerConfigData.defaultConfig(baseDirectory: directoryURL)
        guard
            let data = try? Data(contentsOf: Self.localServerConfigURL),
            let config = try? JSONDecoder().decode(LocalServerConfigData.self, from: data)
        else {
            return fallback
        }
        return config.merged(with: fallback)
    }

    func startLocalServerIfNeeded() {
        guard localServerEnabled else { return }
        switch localServerStatus {
        case .starting, .running:
            return
        case .stopped, .error:
            break
        }
        startLocalServer()
    }

    func restartLocalServer() {
        guard localServerEnabled else { return }
        if localServerProcess == nil {
            startLocalServer()
            return
        }
        localServerRestartRequested = true
        stopLocalServer()
    }

    func stopLocalServer() {
        localServerRestartRequested = false
        guard let process = localServerProcess else {
            localServerStatus = .stopped
            return
        }

        localServerStopRequested = true
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
        }
        process.standardOutput = nil
        process.standardError = nil
        localServerProcess = nil
        localServerStatus = .stopped
        appendLocalServerLog("Local server stopped")
    }

    private func startLocalServer() {
        let config = loadEffectiveLocalServerConfig()
        guard let launch = resolveLocalServerLaunch() else {
            localServerStatus = .error("Could not find copyeverywhere-server binary")
            appendLocalServerLog("Failed to start local server: binary not found")
            return
        }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectoryURL

        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = config.port
        environment["BIND_ADDRESS"] = config.bindAddress
        environment["STORAGE_PATH"] = config.storagePath
        environment["TTL_HOURS"] = String(config.ttlHours)
        environment["MAX_CLIP_SIZE_MB"] = String(config.maxClipSizeMB)
        environment["AUTH_ENABLED"] = config.authEnabled ? "true" : "false"
        if config.authEnabled {
            environment["ACCESS_TOKEN"] = config.accessToken
        } else {
            environment.removeValue(forKey: "ACCESS_TOKEN")
        }
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLocalServerLog(output)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                self?.handleLocalServerTermination(process: terminatedProcess)
            }
        }

        localServerStopRequested = false
        localServerStatus = .starting

        do {
            try process.run()
            localServerProcess = process
            localServerStatus = .running(pid: process.processIdentifier)
            appendLocalServerLog("Local server started on \(config.bindAddress):\(config.port)")
            if hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                applyLocalServerConfigIfNeeded()
            }
            if transferMode == .lanServer {
                Task { @MainActor in
                    await registerDevice()
                    restartSSEConnection(reason: "local server started")
                }
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            localServerProcess = nil
            localServerStatus = .error(error.localizedDescription)
            appendLocalServerLog("Failed to start local server: \(error.localizedDescription)")
        }
    }

    private func handleLocalServerTermination(process: Process) {
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        localServerProcess = nil

        let restartRequested = localServerRestartRequested
        localServerRestartRequested = false

        if localServerStopRequested {
            localServerStopRequested = false
            localServerStatus = .stopped
            if restartRequested {
                startLocalServer()
            }
            return
        }

        if process.terminationStatus == 0 {
            localServerStatus = .stopped
            appendLocalServerLog("Local server exited normally")
        } else {
            let message = "Exited with status \(process.terminationStatus)"
            localServerStatus = .error(message)
            appendLocalServerLog("Local server crashed: \(message)")
        }
    }

    private func appendLocalServerLog(_ text: String) {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        localServerLogs.append(contentsOf: lines)
        if localServerLogs.count > maxLocalServerLogLines {
            localServerLogs.removeFirst(localServerLogs.count - maxLocalServerLogLines)
        }
    }

    private func resolveLocalServerLaunch() -> (executableURL: URL, arguments: [String], workingDirectoryURL: URL)? {
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDirectory = executablePath.deletingLastPathComponent()
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let binaryCandidates = [
            executableDirectory.appendingPathComponent("copyeverywhere-server"),
            currentDirectory.appendingPathComponent("../../server/copyeverywhere-server").standardizedFileURL,
            currentDirectory.appendingPathComponent("../server/copyeverywhere-server").standardizedFileURL,
        ]

        for candidate in binaryCandidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return (candidate, [], candidate.deletingLastPathComponent())
        }

        if let repoServerDirectory = findRepoServerDirectory(startingFrom: [currentDirectory, executableDirectory]) {
            let goExecutable = URL(fileURLWithPath: "/usr/bin/env")
            return (goExecutable, ["go", "run", "."], repoServerDirectory)
        }

        return nil
    }

    private func findRepoServerDirectory(startingFrom roots: [URL]) -> URL? {
        for root in roots {
            var current = root.standardizedFileURL
            for _ in 0..<6 {
                let candidate = current.appendingPathComponent("server")
                let mainGo = candidate.appendingPathComponent("main.go")
                if FileManager.default.fileExists(atPath: mainGo.path) {
                    return candidate
                }
                let parent = current.deletingLastPathComponent()
                if parent == current {
                    break
                }
                current = parent
            }
        }
        return nil
    }

    private func setAuthHeader(_ request: inout URLRequest) {
        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - Test Connection

    func testConnection() async {
        connectionStatus = .testing

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/health") else {
            connectionStatus = .error("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 10

        let start = Date()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                connectionStatus = .error("Invalid response")
                return
            }

            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

            switch httpResponse.statusCode {
            case 200:
                connectionStatus = .success(latencyMs: latencyMs)
                // Read auth requirement from /health response
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let auth = json["auth"] as? Bool {
                    serverAuthRequired = auth
                }
            case 401:
                connectionStatus = .error("Authentication failed (401) - check your access token")
            default:
                connectionStatus = .error("Server returned status \(httpResponse.statusCode)")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                connectionStatus = .error("Connection refused - check the server URL")
            case .timedOut:
                connectionStatus = .error("Connection timed out - server may be unreachable")
            case .secureConnectionFailed:
                connectionStatus = .error("TLS/SSL connection failed - check server certificate")
            default:
                connectionStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            connectionStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Bluetooth Send

    /// Send clipboard text via Bluetooth RFCOMM.
    private func sendClipboardTextBluetooth() async {
        guard let text = getClipboardText(), !text.isEmpty else {
            sendStatus = .error("Clipboard is empty")
            return
        }
        guard let session = bluetoothService.activeSession, session.isHandshakeComplete else {
            sendStatus = .error("Bluetooth not connected")
            return
        }

        sendStatus = .sending
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let progressStream = session.sendText(text) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.sendStatus = .error("Bluetooth send failed: \(error.localizedDescription)")
                } else {
                    self.sendStatus = .success(clipID: "BT", expiresAt: "N/A")
                }
                continuation.resume()
            }
            // Track progress on file upload progress (reuse existing UI)
            Task {
                for await progress in progressStream {
                    self.fileUploadProgress = progress
                }
            }
        }
    }

    /// Fire-and-forget text send via Bluetooth.
    private func sendTextBluetooth(_ text: String) async -> (success: Bool, message: String) {
        guard let session = bluetoothService.activeSession, session.isHandshakeComplete else {
            return (false, "Bluetooth not connected")
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String), Never>) in
            let _ = session.sendText(text) { error in
                if let error {
                    continuation.resume(returning: (false, "Bluetooth: \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: (true, "text (\(text.count) chars)"))
                }
            }
        }
    }

    /// Send a file via Bluetooth RFCOMM with progress.
    private func sendFileBluetooth(url fileURL: URL) async {
        guard let session = bluetoothService.activeSession, session.isHandshakeComplete else {
            fileUploadStatus = .error("Bluetooth not connected")
            return
        }

        let filename = fileURL.lastPathComponent
        fileUploadStatus = .uploading(filename: filename)
        fileUploadProgress = 0
        fileUploadSpeed = ""

        let startTime = Date()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            fileUploadStatus = .error("Cannot read file")
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let progressStream = session.sendFile(url: fileURL) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.fileUploadStatus = .error("Bluetooth send failed: \(error.localizedDescription)")
                } else {
                    self.fileUploadProgress = 1.0
                    self.fileUploadStatus = .success(
                        clipID: "BT",
                        filename: filename,
                        fileSize: self.formatBytes(fileSize),
                        expiresAt: "N/A"
                    )
                }
                continuation.resume()
            }
            Task {
                for await progress in progressStream {
                    self.fileUploadProgress = progress
                    let elapsed = Date().timeIntervalSince(startTime)
                    let bytesSent = Int64(Double(fileSize) * progress)
                    let speed = elapsed > 0 ? Double(bytesSent) / elapsed : 0
                    self.fileUploadSpeed = "\(self.formatBytes(Int64(speed)))/s"
                }
            }
        }
    }

    // MARK: - Clipboard Operations

    func getClipboardText() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }

    func sendClipboardText() async {
        if transferMode == .bluetooth {
            await sendClipboardTextBluetooth()
            return
        }

        guard let text = getClipboardText(), !text.isEmpty else {
            sendStatus = .error("Clipboard is empty")
            return
        }

        sendStatus = .sending

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/api/v1/clips") else {
            sendStatus = .error("Invalid server URL")
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        setAuthHeader(&request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Build multipart body
        var body = Data()
        let textData = Data(text.utf8)

        // "type" field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"type\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        // "content" file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"content\"; filename=\"clipboard.txt\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/plain\r\n\r\n".data(using: .utf8)!)
        body.append(textData)
        body.append("\r\n".data(using: .utf8)!)

        // Device ID fields
        appendDeviceFields(to: &body, boundary: boundary)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                sendStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 201:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let clipID = json["id"] as? String,
                   let expiresAtStr = json["expires_at"] as? String {
                    // Format the expiry for display
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let displayFormatter = DateFormatter()
                    displayFormatter.dateStyle = .none
                    displayFormatter.timeStyle = .short

                    var expiryDisplay = expiresAtStr
                    var expiryDate = Date().addingTimeInterval(3600) // fallback
                    if let date = formatter.date(from: expiresAtStr) {
                        displayFormatter.timeZone = .current
                        expiryDisplay = displayFormatter.string(from: date)
                        expiryDate = date
                    }
                    sendStatus = .success(clipID: clipID, expiresAt: expiryDisplay)
                } else {
                    sendStatus = .error("Unexpected response format")
                }
            case 401:
                sendStatus = .error("Authentication failed (401)")
            case 413:
                sendStatus = .error("Content too large")
            default:
                sendStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                sendStatus = .error("Connection refused - check server URL")
            case .timedOut:
                sendStatus = .error("Request timed out")
            default:
                sendStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            sendStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    /// Fire-and-forget text send for drag-and-drop (does not touch sendStatus).
    func sendText(_ text: String) async -> (success: Bool, message: String) {
        if transferMode == .bluetooth {
            return await sendTextBluetooth(text)
        }
        guard isConfigured else { return (false, "Not configured") }

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(urlString)/api/v1/clips") else {
            return (false, "Invalid server URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        setAuthHeader(&request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        let textData = Data(text.utf8)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"type\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"content\"; filename=\"clipboard.txt\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/plain\r\n\r\n".data(using: .utf8)!)
        body.append(textData)
        body.append("\r\n".data(using: .utf8)!)

        // Device ID fields
        appendDeviceFields(to: &body, boundary: boundary)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Invalid response")
            }
            if httpResponse.statusCode == 201 {
                return (true, "text (\(text.count) chars)")
            }
            return (false, "Server error (\(httpResponse.statusCode))")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Receive Operations

    func receiveLatest() async {
        receiveStatus = .receiving

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let metaURL = URL(string: "\(urlString)/api/v1/clips/latest") else {
            receiveStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: metaURL)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                receiveStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let clipID = json["id"] as? String,
                      let clipType = json["type"] as? String else {
                    receiveStatus = .error("Unexpected response format")
                    return
                }

                if clipType == "text" {
                    await fetchAndCopyText(clipID: clipID)
                } else {
                    receiveStatus = .error("Latest clip is a \(clipType), not text")
                }
            case 404:
                receiveStatus = .noContent
            case 401:
                receiveStatus = .error("Authentication failed (401)")
            default:
                receiveStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                receiveStatus = .error("Connection refused - check server URL")
            case .timedOut:
                receiveStatus = .error("Request timed out")
            default:
                receiveStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            receiveStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    func receiveByID(_ clipID: String) async {
        receiveStatus = .receiving

        let trimmedID = clipID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            receiveStatus = .error("Please enter a Clip ID")
            return
        }

        await fetchAndCopyText(clipID: trimmedID)
    }

    // MARK: - File Upload

    func sendFile(url fileURL: URL) async {
        if transferMode == .bluetooth {
            await sendFileBluetooth(url: fileURL)
            return
        }

        let filename = fileURL.lastPathComponent

        // Check file size
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            fileUploadStatus = .error("Cannot read file")
            return
        }

        if fileSize >= maxSmallFileSize {
            await sendFileChunked(url: fileURL, filename: filename, fileSize: fileSize)
            return
        }

        guard let fileData = try? Data(contentsOf: fileURL) else {
            fileUploadStatus = .error("Cannot read file data")
            return
        }

        fileUploadStatus = .uploading(filename: filename)
        fileUploadProgress = 0
        fileUploadSpeed = ""

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let uploadURL = URL(string: "\(urlString)/api/v1/clips") else {
            fileUploadStatus = .error("Invalid server URL")
            return
        }

        // Determine type
        let clipType: String
        let mimeType: String
        let ext = fileURL.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "heic"].contains(ext) {
            clipType = "image"
            mimeType = "image/\(ext == "jpg" ? "jpeg" : ext)"
        } else {
            clipType = "file"
            mimeType = "application/octet-stream"
        }

        let boundary = UUID().uuidString
        var body = Data()

        // "type" field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"type\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(clipType)\r\n".data(using: .utf8)!)

        // "content" file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"content\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        // Device ID fields
        appendDeviceFields(to: &body, boundary: boundary)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        // Write body to temp file for upload task (enables progress tracking)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try body.write(to: tempURL)
        } catch {
            fileUploadStatus = .error("Failed to prepare upload")
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        setAuthHeader(&request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let delegate = UploadProgressDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let startTime = Date()
        let totalSize = Int64(body.count)

        // Progress tracking task
        let progressTask = Task {
            for await progress in delegate.progressStream {
                let elapsed = Date().timeIntervalSince(startTime)
                let bytesUploaded = Int64(Double(totalSize) * progress)
                let speed = elapsed > 0 ? Double(bytesUploaded) / elapsed : 0
                self.fileUploadProgress = progress
                self.fileUploadSpeed = "\(self.formatBytes(Int64(speed)))/s"
            }
        }

        do {
            let (data, response) = try await session.upload(for: request, fromFile: tempURL)
            progressTask.cancel()
            session.invalidateAndCancel()

            guard let httpResponse = response as? HTTPURLResponse else {
                fileUploadStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 201:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let clipID = json["id"] as? String,
                   let expiresAtStr = json["expires_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let displayFormatter = DateFormatter()
                    displayFormatter.dateStyle = .none
                    displayFormatter.timeStyle = .short

                    var expiryDisplay = expiresAtStr
                    var expiryDate = Date().addingTimeInterval(3600)
                    if let date = formatter.date(from: expiresAtStr) {
                        displayFormatter.timeZone = .current
                        expiryDisplay = displayFormatter.string(from: date)
                        expiryDate = date
                    }
                    fileUploadProgress = 1.0
                    fileUploadStatus = .success(
                        clipID: clipID,
                        filename: filename,
                        fileSize: formatBytes(fileSize),
                        expiresAt: expiryDisplay
                    )
                } else {
                    fileUploadStatus = .error("Unexpected response format")
                }
            case 401:
                fileUploadStatus = .error("Authentication failed (401)")
            case 413:
                fileUploadStatus = .error("File too large for server")
            default:
                fileUploadStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            progressTask.cancel()
            session.invalidateAndCancel()
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                fileUploadStatus = .error("Connection refused - check server URL")
            case .timedOut:
                fileUploadStatus = .error("Upload timed out")
            default:
                fileUploadStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            progressTask.cancel()
            session.invalidateAndCancel()
            fileUploadStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Chunked Upload

    func sendFileChunked(url fileURL: URL, filename: String, fileSize: Int64) async {
        chunkedIsPaused = false
        chunkedUploadFileURL = fileURL

        let totalChunks = Int((fileSize + chunkSize - 1) / chunkSize)

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Step 1: Init upload
        guard let initURL = URL(string: "\(urlString)/api/v1/uploads/init") else {
            fileUploadStatus = .error("Invalid server URL")
            return
        }

        var initRequest = URLRequest(url: initURL)
        initRequest.httpMethod = "POST"
        setAuthHeader(&initRequest)
        initRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initRequest.timeoutInterval = 30

        var initBody: [String: Any] = [
            "filename": filename,
            "size_bytes": fileSize,
            "chunk_size": chunkSize
        ]
        if !deviceID.isEmpty {
            initBody["sender_device_id"] = deviceID
        }
        if let targetID = targetDeviceID {
            initBody["target_device_id"] = targetID
        }
        initRequest.httpBody = try? JSONSerialization.data(withJSONObject: initBody)

        do {
            let (data, response) = try await URLSession.shared.data(for: initRequest)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 401 {
                    fileUploadStatus = .error("Authentication failed (401)")
                } else if statusCode == 413 {
                    fileUploadStatus = .error("File too large for server")
                } else {
                    fileUploadStatus = .error("Failed to init upload (status \(statusCode))")
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploadID = json["upload_id"] as? String else {
                fileUploadStatus = .error("Invalid init response")
                return
            }

            chunkedUploadID = uploadID
            await uploadChunks(uploadID: uploadID, fileURL: fileURL, filename: filename, fileSize: fileSize, totalChunks: totalChunks, startChunk: 1)
        } catch {
            fileUploadStatus = .error("Network error: \(error.localizedDescription)")
        }
    }

    func pauseChunkedUpload() {
        chunkedIsPaused = true
        chunkedUploadTask?.cancel()
        chunkedUploadTask = nil
        if case .chunkedUploading(let filename, let chunk, let total) = fileUploadStatus {
            fileUploadStatus = .chunkedPaused(filename: filename, currentChunk: chunk, totalChunks: total)
        }
    }

    func resumeChunkedUpload() async {
        guard let uploadID = chunkedUploadID,
              let fileURL = chunkedUploadFileURL else {
            fileUploadStatus = .error("No upload to resume")
            return
        }

        let filename = fileURL.lastPathComponent
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            fileUploadStatus = .error("Cannot read file")
            return
        }

        let totalChunks = Int((fileSize + chunkSize - 1) / chunkSize)

        // Query server for received parts
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let statusURL = URL(string: "\(urlString)/api/v1/uploads/\(uploadID)/status") else {
            fileUploadStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: statusURL)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                fileUploadStatus = .error("Failed to check upload status (\(statusCode))")
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let receivedParts = json["received_parts"] as? [Int] else {
                fileUploadStatus = .error("Invalid status response")
                return
            }

            let receivedSet = Set(receivedParts)
            // Find first missing chunk (1-indexed)
            var startChunk = 1
            for i in 1...totalChunks {
                if !receivedSet.contains(i) {
                    startChunk = i
                    break
                }
            }

            chunkedIsPaused = false
            await uploadChunks(uploadID: uploadID, fileURL: fileURL, filename: filename, fileSize: fileSize, totalChunks: totalChunks, startChunk: startChunk, receivedParts: receivedSet)
        } catch {
            fileUploadStatus = .error("Network error: \(error.localizedDescription)")
        }
    }

    private func uploadChunks(uploadID: String, fileURL: URL, filename: String, fileSize: Int64, totalChunks: Int, startChunk: Int, receivedParts: Set<Int> = []) async {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            fileUploadStatus = .error("Cannot open file")
            return
        }
        defer { try? fileHandle.close() }

        let startTime = Date()

        for chunkIndex in startChunk...totalChunks {
            if chunkedIsPaused || Task.isCancelled {
                return
            }

            // Skip already-received parts
            if receivedParts.contains(chunkIndex) {
                continue
            }

            fileUploadStatus = .chunkedUploading(filename: filename, currentChunk: chunkIndex, totalChunks: totalChunks)
            fileUploadProgress = Double(chunkIndex - 1) / Double(totalChunks)

            // Read chunk data
            let offset = Int64(chunkIndex - 1) * chunkSize
            try? fileHandle.seek(toOffset: UInt64(offset))
            let readSize = min(chunkSize, fileSize - offset)
            guard let chunkData = try? fileHandle.read(upToCount: Int(readSize)), !chunkData.isEmpty else {
                fileUploadStatus = .error("Failed to read chunk \(chunkIndex)")
                return
            }

            // Upload chunk
            guard let partURL = URL(string: "\(urlString)/api/v1/uploads/\(uploadID)/parts/\(chunkIndex)") else {
                fileUploadStatus = .error("Invalid server URL")
                return
            }

            var request = URLRequest(url: partURL)
            request.httpMethod = "PUT"
            setAuthHeader(&request)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            request.httpBody = chunkData

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    fileUploadStatus = .error("Invalid response for chunk \(chunkIndex)")
                    return
                }

                if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 && httpResponse.statusCode != 409 {
                    fileUploadStatus = .error("Failed to upload chunk \(chunkIndex) (status \(httpResponse.statusCode))")
                    return
                }

                // Update speed
                let elapsed = Date().timeIntervalSince(startTime)
                let bytesUploaded = Int64(chunkIndex) * chunkSize
                let speed = elapsed > 0 ? Double(bytesUploaded) / elapsed : 0
                fileUploadSpeed = "\(formatBytes(Int64(speed)))/s"
                fileUploadProgress = Double(chunkIndex) / Double(totalChunks)
            } catch {
                if chunkedIsPaused || Task.isCancelled {
                    return
                }
                fileUploadStatus = .error("Network error on chunk \(chunkIndex): \(error.localizedDescription)")
                return
            }
        }

        if chunkedIsPaused || Task.isCancelled {
            return
        }

        // Step 3: Complete upload
        guard let completeURL = URL(string: "\(urlString)/api/v1/uploads/\(uploadID)/complete") else {
            fileUploadStatus = .error("Invalid server URL")
            return
        }

        var completeRequest = URLRequest(url: completeURL)
        completeRequest.httpMethod = "POST"
        setAuthHeader(&completeRequest)
        completeRequest.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: completeRequest)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                fileUploadStatus = .error("Failed to complete upload (status \(statusCode))")
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let clipID = json["id"] as? String,
               let expiresAtStr = json["expires_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let displayFormatter = DateFormatter()
                displayFormatter.dateStyle = .none
                displayFormatter.timeStyle = .short

                var expiryDisplay = expiresAtStr
                var expiryDate = Date().addingTimeInterval(3600)
                if let date = formatter.date(from: expiresAtStr) {
                    displayFormatter.timeZone = .current
                    expiryDisplay = displayFormatter.string(from: date)
                    expiryDate = date
                }
                fileUploadProgress = 1.0
                fileUploadStatus = .success(
                    clipID: clipID,
                    filename: filename,
                    fileSize: formatBytes(fileSize),
                    expiresAt: expiryDisplay
                )
            } else {
                fileUploadStatus = .error("Unexpected complete response format")
            }
        } catch {
            fileUploadStatus = .error("Network error completing upload: \(error.localizedDescription)")
        }

        // Clear chunked state on success
        chunkedUploadID = nil
        chunkedUploadFileURL = nil
    }

    // MARK: - File Download

    func fetchClipMetadata(_ clipID: String) async {
        let trimmedID = clipID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            fileDownloadStatus = .error("Please enter a Clip ID")
            return
        }

        fileDownloadStatus = .fetchingMetadata

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let metaURL = URL(string: "\(urlString)/api/v1/clips/\(trimmedID)") else {
            fileDownloadStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: metaURL)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                fileDownloadStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String,
                      let type = json["type"] as? String,
                      let sizeBytes = json["size_bytes"] as? Int64,
                      let createdAtStr = json["created_at"] as? String,
                      let expiresAtStr = json["expires_at"] as? String else {
                    fileDownloadStatus = .error("Unexpected response format")
                    return
                }

                let filename = json["filename"] as? String

                // Format dates for display
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let displayFormatter = DateFormatter()
                displayFormatter.dateStyle = .short
                displayFormatter.timeStyle = .short
                displayFormatter.timeZone = .current

                var createdDisplay = createdAtStr
                if let date = isoFormatter.date(from: createdAtStr) {
                    createdDisplay = displayFormatter.string(from: date)
                }

                var expiresDisplay = expiresAtStr
                if let date = isoFormatter.date(from: expiresAtStr) {
                    expiresDisplay = displayFormatter.string(from: date)
                }

                fileDownloadStatus = .metadataLoaded(ClipMetadata(
                    id: id,
                    type: type,
                    filename: filename,
                    sizeBytes: sizeBytes,
                    createdAt: createdDisplay,
                    expiresAt: expiresDisplay
                ))
            case 404:
                fileDownloadStatus = .error("Clip not found or expired")
            case 401:
                fileDownloadStatus = .error("Authentication failed (401)")
            default:
                fileDownloadStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                fileDownloadStatus = .error("Connection refused - check server URL")
            case .timedOut:
                fileDownloadStatus = .error("Request timed out")
            default:
                fileDownloadStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            fileDownloadStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    func downloadFile(clipID: String, saveURL: URL) async {
        guard case .metadataLoaded(let meta) = fileDownloadStatus else { return }

        let filename = meta.filename ?? "\(clipID)"
        fileDownloadStatus = .downloading(filename: filename)
        fileDownloadProgress = 0
        fileDownloadSpeed = ""

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let rawURL = URL(string: "\(urlString)/api/v1/clips/\(clipID)/raw") else {
            fileDownloadStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: rawURL)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 300

        let delegate = DownloadProgressDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let startTime = Date()

        // Progress tracking task
        let progressTask = Task {
            for await (written, total) in delegate.progressStream {
                let elapsed = Date().timeIntervalSince(startTime)
                let speed = elapsed > 0 ? Double(written) / elapsed : 0
                if total > 0 {
                    self.fileDownloadProgress = Double(written) / Double(total)
                }
                self.fileDownloadSpeed = "\(self.formatBytes(Int64(speed)))/s"
            }
        }

        do {
            let (tempURL, response) = try await session.download(for: request)
            progressTask.cancel()
            session.invalidateAndCancel()

            guard let httpResponse = response as? HTTPURLResponse else {
                fileDownloadStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 200:
                // Move downloaded file to save location
                let fileManager = FileManager.default
                // Remove existing file if present
                if fileManager.fileExists(atPath: saveURL.path) {
                    try fileManager.removeItem(at: saveURL)
                }
                try fileManager.moveItem(at: tempURL, to: saveURL)

                fileDownloadProgress = 1.0
                fileDownloadStatus = .success(savedPath: saveURL.path)

                // Reveal in Finder
                NSWorkspace.shared.activateFileViewerSelecting([saveURL])
            case 403:
                fileDownloadStatus = .uploadIncomplete
            case 404:
                fileDownloadStatus = .error("Clip not found or expired")
            case 401:
                fileDownloadStatus = .error("Authentication failed (401)")
            default:
                fileDownloadStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            progressTask.cancel()
            session.invalidateAndCancel()
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                fileDownloadStatus = .error("Connection refused - check server URL")
            case .timedOut:
                fileDownloadStatus = .error("Download timed out")
            default:
                fileDownloadStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            progressTask.cancel()
            session.invalidateAndCancel()
            fileDownloadStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Queue Operations

    func fetchQueue() async {
        guard isConfigured, !deviceID.isEmpty else { return }

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/api/v1/clips?device_id=\(deviceID)") else {
            queueError = "Invalid server URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                queueError = "Invalid response"
                return
            }

            if httpResponse.statusCode == 200 {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    queueError = "Unexpected response format"
                    return
                }

                var items: [QueueItem] = []
                for json in jsonArray {
                    guard let id = json["id"] as? String,
                          let type = json["type"] as? String,
                          let sizeBytes = json["size_bytes"] as? Int64,
                          let createdAtStr = json["created_at"] as? String,
                          let expiresAtStr = json["expires_at"] as? String else { continue }

                    let filename = json["filename"] as? String
                    let targetDeviceID = json["target_device_id"] as? String
                    let createdAt = isoFormatter.date(from: createdAtStr) ?? Date()
                    let expiresAt = isoFormatter.date(from: expiresAtStr) ?? Date()
                    let deliveryState = QueueItem.DeliveryState(serverValue: json["delivery_state"] as? String)

                    items.append(QueueItem(
                        id: id, type: type, filename: filename,
                        sizeBytes: sizeBytes, createdAt: createdAt, expiresAt: expiresAt,
                        deliveryState: deliveryState,
                        targetDeviceID: targetDeviceID
                    ))
                }
                queueItems = items
                queueError = nil
                await autoReceiveTargetedQueueItems(items)
            } else if httpResponse.statusCode == 401 {
                queueError = "Authentication failed (401)"
            } else {
                queueError = "Server error (\(httpResponse.statusCode))"
            }
        } catch {
            queueError = "Network error: \(error.localizedDescription)"
        }
    }

    private func autoReceiveTargetedQueueItems(_ items: [QueueItem]) async {
        let targeted = items.filter { $0.targetDeviceID == deviceID && !queueAutoReceiveInFlight.contains($0.id) }
        guard !targeted.isEmpty else { return }

        for item in targeted {
            queueAutoReceiveInFlight.insert(item.id)
            appendLocalServerLog("Queue fallback: auto-receiving targeted clip \(item.id)")
            await receiveQueueItem(item)
            queueAutoReceiveInFlight.remove(item.id)
        }
    }

    func receiveQueueItem(_ item: QueueItem) async {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let rawURL = rawClipURL(for: item.id, baseURLString: urlString) else { return }

        var request = URLRequest(url: rawURL)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 60

        do {
            if item.type == "text" || item.type == "image" {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return }

                if httpResponse.statusCode == 200 {
                    if item.type == "text" {
                        if let text = String(data: data, encoding: .utf8) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            toastMessage = "Copied text to clipboard"
                        }
                    } else {
                        // image
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setData(data, forType: .png)
                        toastMessage = "Copied image to clipboard"
                    }
                    // Remove from local queue (server already deleted it)
                    queueItems.removeAll { $0.id == item.id }
                    dismissToastAfterDelay()
                } else if httpResponse.statusCode == 410 {
                    toastMessage = "Already consumed by another device"
                    queueItems.removeAll { $0.id == item.id }
                    dismissToastAfterDelay()
                } else {
                    toastMessage = "Failed to receive (status \(httpResponse.statusCode))"
                    dismissToastAfterDelay()
                }
            } else {
                // File — download to ~/Downloads/
                let delegate = DownloadProgressDelegate()
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

                let (tempURL, response) = try await session.download(for: request)
                session.invalidateAndCancel()

                guard let httpResponse = response as? HTTPURLResponse else { return }

                if httpResponse.statusCode == 200 {
                    let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Downloads")
                    let filename = item.filename ?? item.id
                    var destURL = downloadsURL.appendingPathComponent(filename)

                    // Avoid overwriting existing files
                    let fm = FileManager.default
                    if fm.fileExists(atPath: destURL.path) {
                        let base = destURL.deletingPathExtension().lastPathComponent
                        let ext = destURL.pathExtension
                        var counter = 1
                        repeat {
                            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                            destURL = downloadsURL.appendingPathComponent(newName)
                            counter += 1
                        } while fm.fileExists(atPath: destURL.path)
                    }

                    try fm.moveItem(at: tempURL, to: destURL)
                    toastMessage = "Saved \(destURL.lastPathComponent) to Downloads"
                    queueItems.removeAll { $0.id == item.id }
                    dismissToastAfterDelay()
                    NSWorkspace.shared.activateFileViewerSelecting([destURL])
                } else if httpResponse.statusCode == 410 {
                    toastMessage = "Already consumed by another device"
                    queueItems.removeAll { $0.id == item.id }
                    dismissToastAfterDelay()
                } else {
                    toastMessage = "Failed to receive (status \(httpResponse.statusCode))"
                    dismissToastAfterDelay()
                }
            }
        } catch {
            toastMessage = "Network error: \(error.localizedDescription)"
            dismissToastAfterDelay()
        }
    }

    private func dismissToastAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            toastMessage = nil
        }
    }

    private func rawClipURL(for clipID: String, baseURLString: String? = nil) -> URL? {
        let trimmedBaseURL = (baseURLString ?? hostURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard var components = URLComponents(string: "\(trimmedBaseURL)/api/v1/clips/\(clipID)/raw") else {
            return nil
        }

        if !deviceID.isEmpty {
            components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        }

        return components.url
    }

    private func showAutoReceiveWarning(_ message: String) {
        autoReceiveWarning = message
        dismissAutoReceiveWarningAfterDelay()
    }

    private func dismissAutoReceiveWarningAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            autoReceiveWarning = nil
        }
    }

    // MARK: - Device List

    func fetchDevices() async {
        guard isConfigured else { return }

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/api/v1/devices") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            var devices: [DeviceInfo] = []
            for json in jsonArray {
                guard let id = json["device_id"] as? String,
                      let name = json["name"] as? String,
                      let platform = json["platform"] as? String else { continue }
                // Exclude self
                if id == deviceID { continue }
                let lastSeenAtStr = json["last_seen_at"] as? String ?? ""
                let lastSeenAt = isoFormatter.date(from: lastSeenAtStr) ?? Date()
                let receiverStatus = DeviceInfo.ReceiverStatus(serverValue: json["receiver_status"] as? String)
                devices.append(DeviceInfo(
                    id: id,
                    name: name,
                    platform: platform,
                    lastSeenAt: lastSeenAt,
                    receiverStatus: receiverStatus
                ))
            }
            availableDevices = devices
        } catch {
            // Best-effort — don't block
        }
    }

    // MARK: - SSE Auto-Receive

    func startSSE() {
        guard isConfigured, !deviceID.isEmpty else { return }
        // Don't start a second connection
        guard sseTask == nil else { return }
        sseRetryDelay = 1.0
        sseConnectionState = .reconnecting
        sseStatusDetail = "Connecting targeted auto-delivery…"
        sseStatusDescription = "Connecting..."
        appendLocalServerLog("SSE: starting for device \(deviceID)")
        sseTask = Task { await sseLoop() }
    }

    func stopSSE() {
        sseTask?.cancel()
        sseTask = nil
        sseConnectionState = .disconnected
        if transferMode != .lanServer {
            sseStatusDetail = "LAN receiver paused while Bluetooth Direct is active."
        } else if isConfigured {
            sseStatusDetail = "Targeted auto-delivery disconnected."
        } else {
            sseStatusDetail = "Configure a LAN server to enable targeted auto-delivery."
        }
        sseStatusDescription = "Disconnected"
        appendLocalServerLog("SSE: stopped")
    }

    private func restartSSEConnection(reason: String) {
        appendLocalServerLog("SSE: restarting (\(reason))")
        stopSSE()
        startSSE()
    }

    private func sseLoop() async {
        while !Task.isCancelled {
            do {
                try await connectSSE()
                if Task.isCancelled { return }
                sseConnectionState = .reconnecting
                sseStatusDetail = "Connection lost. Reconnecting targeted auto-delivery…"
            } catch is CancellationError {
                sseStatusDescription = "Disconnected"
                return
            } catch {
                // Reconnect with exponential backoff
                if Task.isCancelled { return }
                sseConnectionState = .reconnecting
                let retrySeconds = Int(max(1, sseRetryDelay.rounded()))
                sseStatusDetail = "Reconnect in \(retrySeconds)s after \(error.localizedDescription)."
                sseStatusDescription = "Retrying in \(Int(sseRetryDelay))s"
                appendLocalServerLog("SSE: connection failed (\(error.localizedDescription)); retrying in \(Int(sseRetryDelay))s")
                try? await Task.sleep(nanoseconds: UInt64(sseRetryDelay * 1_000_000_000))
                if Task.isCancelled { return }
                sseRetryDelay = min(sseRetryDelay * 2, sseMaxRetryDelay)
            }
        }
    }

    private func connectSSE() async throws {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/api/v1/devices/\(deviceID)/stream") else { return }
        appendLocalServerLog("SSE: connecting to \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Connected successfully — reset backoff
        sseRetryDelay = 1.0
        sseConnectionState = .connected
        sseStatusDetail = "Connected for targeted auto-delivery."
        sseStatusDescription = "Connected"
        appendLocalServerLog("SSE: connected")

        var eventType = ""
        var dataBuffer = ""

        for try await line in bytes.lines {
            if Task.isCancelled { return }

            if line.isEmpty {
                // Empty line = end of event
                if eventType == "clip" && !dataBuffer.isEmpty {
                    appendLocalServerLog("SSE: received clip event")
                    await handleSSEClipEvent(dataBuffer)
                }
                eventType = ""
                dataBuffer = ""
            } else if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                dataBuffer = String(line.dropFirst(6))
            }
            // Ignore id:, comments (:), etc.
        }

        throw URLError(.networkConnectionLost)
    }

    private func handleSSEClipEvent(_ jsonString: String) async {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clipID = json["clip_id"] as? String,
              let clipType = json["type"] as? String else { return }

        let filename = json["filename"] as? String
        appendLocalServerLog("SSE: auto-receiving clip \(clipID) (\(clipType))")

        // Auto-receive the targeted clip
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let rawURL = rawClipURL(for: clipID, baseURLString: urlString) else { return }

        var request = URLRequest(url: rawURL)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 60

        do {
            if clipType == "text" {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return }
                guard httpResponse.statusCode == 200 else {
                    await handleAutoReceiveFailure(statusCode: httpResponse.statusCode, clipID: clipID)
                    return
                }
                if let text = String(data: responseData, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    autoReceiveWarning = nil
                    toastMessage = "Received text from sender"
                    dismissToastAfterDelay()
                    AppDelegate.sendNotification(body: "Received text from sender")
                }
            } else if clipType == "image" {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return }
                guard httpResponse.statusCode == 200 else {
                    await handleAutoReceiveFailure(statusCode: httpResponse.statusCode, clipID: clipID)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(responseData, forType: .png)
                autoReceiveWarning = nil
                toastMessage = "Received image from sender"
                dismissToastAfterDelay()
                AppDelegate.sendNotification(body: "Received image from sender")
            } else {
                // File — download to ~/Downloads/
                let delegate = DownloadProgressDelegate()
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

                let (tempURL, response) = try await session.download(for: request)
                session.invalidateAndCancel()

                guard let httpResponse = response as? HTTPURLResponse else { return }
                guard httpResponse.statusCode == 200 else {
                    await handleAutoReceiveFailure(statusCode: httpResponse.statusCode, clipID: clipID)
                    return
                }

                let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads")
                let destFilename = filename ?? clipID
                var destURL = downloadsURL.appendingPathComponent(destFilename)

                // Avoid overwriting existing files
                let fm = FileManager.default
                if fm.fileExists(atPath: destURL.path) {
                    let base = destURL.deletingPathExtension().lastPathComponent
                    let ext = destURL.pathExtension
                    var counter = 1
                    repeat {
                        let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                        destURL = downloadsURL.appendingPathComponent(newName)
                        counter += 1
                    } while fm.fileExists(atPath: destURL.path)
                }

                try fm.moveItem(at: tempURL, to: destURL)
                autoReceiveWarning = nil
                toastMessage = "Saved \(destURL.lastPathComponent) to Downloads"
                dismissToastAfterDelay()
                AppDelegate.sendNotification(body: "Saved \(destURL.lastPathComponent) to Downloads")
                NSWorkspace.shared.activateFileViewerSelecting([destURL])
            }

            // Remove from local queue if present
            queueItems.removeAll { $0.id == clipID }
        } catch {
            showAutoReceiveWarning("Targeted auto-delivery failed. The clip remains available in Queue for manual receive.")
            await fetchQueue()
            appendLocalServerLog("SSE: auto-receive failed for \(clipID): \(error.localizedDescription)")
        }
    }

    private func handleAutoReceiveFailure(statusCode: Int, clipID: String) async {
        if statusCode == 410 {
            queueItems.removeAll { $0.id == clipID }
            return
        }

        showAutoReceiveWarning("Targeted auto-delivery failed. The clip remains available in Queue for manual receive.")
        await fetchQueue()
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Appends sender_device_id and target_device_id multipart fields to a body.
    private func appendDeviceFields(to body: inout Data, boundary: String) {
        if !deviceID.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"sender_device_id\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(deviceID)\r\n".data(using: .utf8)!)
        }
        if let targetID = targetDeviceID {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"target_device_id\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(targetID)\r\n".data(using: .utf8)!)
        }
    }

    private func fetchAndCopyText(clipID: String) async {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let rawURL = URL(string: "\(urlString)/api/v1/clips/\(clipID)/raw") else {
            receiveStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: rawURL)
        request.httpMethod = "GET"
        setAuthHeader(&request)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                receiveStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 200:
                guard let text = String(data: data, encoding: .utf8) else {
                    receiveStatus = .error("Could not decode content as text")
                    return
                }

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)

                // Bundle.main.bundleIdentifier is nil for un-bundled SPM builds (`swift run`),
                // and UNUserNotificationCenter.current() throws NSInternalInconsistencyException in that case.
                if Bundle.main.bundleIdentifier != nil {
                    let content = UNMutableNotificationContent()
                    content.title = "CopyEverywhere"
                    content.body = "Copied to clipboard"
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                    try? await UNUserNotificationCenter.current().add(request)
                }

                receiveStatus = .success(clipID)
            case 403:
                receiveStatus = .error("Upload incomplete - download unavailable")
            case 404:
                receiveStatus = .noContent
            case 401:
                receiveStatus = .error("Authentication failed (401)")
            default:
                receiveStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                receiveStatus = .error("Connection refused - check server URL")
            case .timedOut:
                receiveStatus = .error("Request timed out")
            default:
                receiveStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            receiveStatus = .error("Error: \(error.localizedDescription)")
        }
    }
}

private struct LocalServerConfigData: Codable {
    let port: String
    let bindAddress: String
    let authEnabled: Bool
    let accessToken: String
    let storagePath: String
    let ttlHours: Int
    let maxClipSizeMB: Int

    enum CodingKeys: String, CodingKey {
        case port
        case bindAddress
        case authEnabled
        case accessToken
        case storagePath
        case ttlHours
        case maxClipSizeMB
    }

    init(
        port: String,
        bindAddress: String,
        authEnabled: Bool,
        accessToken: String,
        storagePath: String,
        ttlHours: Int,
        maxClipSizeMB: Int
    ) {
        self.port = port
        self.bindAddress = bindAddress
        self.authEnabled = authEnabled
        self.accessToken = accessToken
        self.storagePath = storagePath
        self.ttlHours = ttlHours
        self.maxClipSizeMB = maxClipSizeMB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.port = try container.decodeIfPresent(String.self, forKey: .port) ?? "8080"
        self.bindAddress = try container.decodeIfPresent(String.self, forKey: .bindAddress) ?? "0.0.0.0"
        self.authEnabled = try container.decodeIfPresent(Bool.self, forKey: .authEnabled) ?? false
        self.accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        self.storagePath = try container.decodeIfPresent(String.self, forKey: .storagePath) ?? ""
        self.ttlHours = try container.decodeIfPresent(Int.self, forKey: .ttlHours) ?? 1
        self.maxClipSizeMB = try container.decodeIfPresent(Int.self, forKey: .maxClipSizeMB) ?? 500
    }

    static func defaultConfig(baseDirectory: URL) -> LocalServerConfigData {
        let storagePath = baseDirectory.appendingPathComponent("data").path
        return LocalServerConfigData(
            port: "8080",
            bindAddress: "0.0.0.0",
            authEnabled: false,
            accessToken: "",
            storagePath: storagePath,
            ttlHours: 1,
            maxClipSizeMB: 500
        )
    }

    func merged(with fallback: LocalServerConfigData) -> LocalServerConfigData {
        LocalServerConfigData(
            port: port.isEmpty ? fallback.port : port,
            bindAddress: bindAddress.isEmpty ? fallback.bindAddress : bindAddress,
            authEnabled: authEnabled,
            accessToken: accessToken,
            storagePath: storagePath.isEmpty ? fallback.storagePath : storagePath,
            ttlHours: ttlHours <= 0 ? fallback.ttlHours : ttlHours,
            maxClipSizeMB: maxClipSizeMB <= 0 ? fallback.maxClipSizeMB : maxClipSizeMB
        )
    }
}

// MARK: - BluetoothServiceDelegate

extension ConfigStore: BluetoothServiceDelegate {

    func bluetoothService(_ service: BluetoothService, didAcceptConnection channel: IOBluetoothRFCOMMChannel, from device: IOBluetoothDevice) {
        bluetoothConnectionStatus = .connecting
        bluetoothConnectedDeviceName = device.name
    }

    func bluetoothService(_ service: BluetoothService, didConnectTo channel: IOBluetoothRFCOMMChannel, device: IOBluetoothDevice) {
        // Connection established, handshake in progress
    }

    func bluetoothService(_ service: BluetoothService, didFailWithError error: Error) {
        bluetoothConnectionStatus = .error(error.localizedDescription)
        currentPairHelper = nil
    }

    func bluetoothService(_ service: BluetoothService, sessionReady session: BluetoothSession, device: IOBluetoothDevice) {
        bluetoothConnectionStatus = .connected
        bluetoothConnectedDeviceName = device.name

        // If this was a pairing flow, complete it
        if let helper = currentPairHelper {
            let discovered = helper.discoveredDevice
            bluetoothPairingSucceeded(device: device, discovered: discovered)
            currentPairHelper = nil
        }
    }

    func bluetoothService(_ service: BluetoothService, sessionHandshakeFailed session: BluetoothSession, error: Error) {
        bluetoothConnectionStatus = .error("Handshake failed: \(error.localizedDescription)")
        currentPairHelper = nil
    }

    func bluetoothService(_ service: BluetoothService, receiveProgress progress: Double, header: BluetoothTransferHeader) {
        bluetoothReceiveProgress = progress
        bluetoothReceiveFilename = header.filename
    }

    func bluetoothService(_ service: BluetoothService, didReceive payload: BluetoothTransferPayload, from device: IOBluetoothDevice?) {
        bluetoothReceiveProgress = 0
        bluetoothReceiveFilename = nil
        handleBluetoothReceive(payload: payload)
    }

    func bluetoothService(_ service: BluetoothService, didFailReceivingWithError error: Error) {
        bluetoothReceiveProgress = 0
        bluetoothReceiveFilename = nil
        toastMessage = "Bluetooth receive failed: \(error.localizedDescription)"
        dismissToastAfterDelay()
        AppDelegate.sendNotification(body: "Bluetooth receive failed: \(error.localizedDescription)")
    }

    // MARK: - Bluetooth Receive Handling

    private func handleBluetoothReceive(payload: BluetoothTransferPayload) {
        switch payload.header.type {
        case .text:
            // Write received text to clipboard
            if let text = String(data: payload.data, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                toastMessage = "Received text (\(text.count) chars)"
                dismissToastAfterDelay()
                AppDelegate.sendNotification(body: "Received text (\(text.count) chars)")
            } else {
                toastMessage = "Received invalid text data"
                dismissToastAfterDelay()
            }

        case .file:
            // Save received file to ~/Downloads
            let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
            let filename = payload.header.filename
            var destURL = downloadsURL.appendingPathComponent(filename)

            // Avoid overwriting existing files
            let fm = FileManager.default
            if fm.fileExists(atPath: destURL.path) {
                let base = destURL.deletingPathExtension().lastPathComponent
                let ext = destURL.pathExtension
                var counter = 1
                repeat {
                    let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                    destURL = downloadsURL.appendingPathComponent(newName)
                    counter += 1
                } while fm.fileExists(atPath: destURL.path)
            }

            do {
                try payload.data.write(to: destURL)
                toastMessage = "Received \(destURL.lastPathComponent)"
                dismissToastAfterDelay()
                AppDelegate.sendNotification(body: "Received \(destURL.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([destURL])
            } catch {
                toastMessage = "Failed to save file: \(error.localizedDescription)"
                dismissToastAfterDelay()
                AppDelegate.sendNotification(body: "Failed to save received file")
            }
        }
    }
}

// MARK: - Bluetooth Pair Helper

/// Manages the system-level Bluetooth pairing flow + RFCOMM connection for a discovered device.
class BluetoothPairHelper: NSObject {
    private let configStore: ConfigStore
    private let device: IOBluetoothDevice
    let discoveredDevice: DiscoveredBluetoothDevice

    init(configStore: ConfigStore, device: IOBluetoothDevice, discoveredDevice: DiscoveredBluetoothDevice) {
        self.configStore = configStore
        self.device = device
        self.discoveredDevice = discoveredDevice
    }

    func startPairing() {
        // If the device is already paired, skip straight to RFCOMM connection
        if device.isPaired() {
            connectRFCOMM()
            return
        }

        // openConnection triggers the macOS system Bluetooth pairing dialog
        let status = device.openConnection(self)
        if status != kIOReturnSuccess {
            Task { @MainActor in
                self.configStore.bluetoothConnectionStatus = .error("Failed to initiate pairing (code: \(status))")
                self.configStore.currentPairHelper = nil
            }
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        if status == kIOReturnSuccess {
            connectRFCOMM()
        } else {
            Task { @MainActor in
                self.configStore.bluetoothConnectionStatus = .error("Pairing failed (code: \(status))")
                self.configStore.currentPairHelper = nil
            }
        }
    }

    private func connectRFCOMM() {
        Task { @MainActor in
            self.configStore.bluetoothService.connect(to: self.device)
        }
    }
}

// MARK: - Upload Progress Delegate

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let continuation: AsyncStream<Double>.Continuation
    let progressStream: AsyncStream<Double>

    override init() {
        var cont: AsyncStream<Double>.Continuation!
        progressStream = AsyncStream { cont = $0 }
        continuation = cont
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        continuation.yield(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish()
    }
}

// MARK: - Download Progress Delegate

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let continuation: AsyncStream<(Int64, Int64)>.Continuation
    let progressStream: AsyncStream<(Int64, Int64)>

    override init() {
        var cont: AsyncStream<(Int64, Int64)>.Continuation!
        progressStream = AsyncStream { cont = $0 }
        continuation = cont
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        continuation.yield((totalBytesWritten, totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        continuation.finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish()
    }
}
