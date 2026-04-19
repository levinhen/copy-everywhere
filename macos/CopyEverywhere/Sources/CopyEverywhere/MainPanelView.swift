import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConnectedDevice: Identifiable, Decodable {
    let id: String
    let name: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case id = "device_id"
        case name
        case platform
    }
}

struct MainPanelView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var serverConfig: ServerConfig
    @EnvironmentObject var serverProcess: ServerProcess
    @State private var showingConfig = false
    @State private var clipboardText: String? = nil
    @State private var isDragTargeted = false
    @State private var isFullPanelDragTargeted = false
    @State private var queueRefreshTimer: Timer?
    @State private var showServerLogs = false
    @State private var connectedDevices: [ConnectedDevice] = []
    @State private var devicesError: String? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
        VStack(spacing: 12) {
            // Toast banner for ⌘V send feedback
            if let toast = configStore.toastMessage {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.white)
                    Text(toast)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color.accentColor)
                .cornerRadius(6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: configStore.toastMessage)
            }

            HStack {
                Text("CopyEverywhere")
                    .font(.headline)
                if serverConfig.serverEnabled {
                    Circle()
                        .fill(serverStatusColor)
                        .frame(width: 8, height: 8)
                }
                Spacer()
                Button(action: { showingConfig.toggle() }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
            }

            if showingConfig {
                ConfigView()
                    .padding(.top, 4)

                HStack {
                    Button("Clear Config") {
                        configStore.clearConfig()
                    }
                    .foregroundColor(.red)

                    Spacer()

                    Button("Done") {
                        showingConfig = false
                    }
                }
            } else {
                if let warning = configStore.selectedTargetFallbackWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                if let warning = configStore.autoReceiveWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                if configStore.transferMode == .lanServer {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(configStore.lanDeliveryModeTitle)
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(configStore.lanDeliveryModeDetail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(8)
                }

                // Clipboard preview section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clipboard")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if let text = clipboardText, !text.isEmpty {
                        Text(text.count > 500 ? String(text.prefix(500)) + "..." : text)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                    } else {
                        Text("Clipboard is empty")
                            .foregroundColor(.secondary)
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                    }

                    Button(action: {
                        Task {
                            await configStore.sendClipboardText()
                        }
                    }) {
                        HStack {
                            if configStore.sendStatus == .sending {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                                Text("Sending...")
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("Send Clipboard")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(clipboardText == nil || clipboardText?.isEmpty == true || configStore.sendStatus == .sending)

                    // Send status display
                    switch configStore.sendStatus {
                    case .idle:
                        EmptyView()
                    case .sending:
                        EmptyView()
                    case .success(let clipID, let expiresAt):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text(configStore.transferMode == .lanServer ? "Delivery request sent" : "Bluetooth transfer sent")
                                    .foregroundColor(.green)
                            }
                            Text(configStore.sendSuccessDetail)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text("Clip ID:")
                                    .foregroundColor(.secondary)
                                Text(clipID)
                                    .fontWeight(.semibold)
                                    .textSelection(.enabled)
                            }
                            HStack {
                                Text("Expires:")
                                    .foregroundColor(.secondary)
                                Text(expiresAt)
                            }
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                    case .error(let message):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text(message)
                                    .foregroundColor(.red)
                            }
                            Button("Retry") {
                                Task {
                                    await configStore.sendClipboardText()
                                }
                            }
                            .font(.caption)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }
                }

                Divider()

                // File upload section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Send File")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    // Drop zone
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isDragTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
                            )

                        VStack(spacing: 4) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Drop file here")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 60)
                    .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                        handleFileDrop(providers)
                    }

                    Button(action: chooseFile) {
                        HStack {
                            Image(systemName: "folder.fill")
                            Text("Choose File")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isFileUploading)

                    // Upload progress (small file)
                    if case .uploading(let filename) = configStore.fileUploadStatus {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(filename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ProgressView(value: configStore.fileUploadProgress)
                            HStack {
                                Text("\(Int(configStore.fileUploadProgress * 100))%")
                                if !configStore.fileUploadSpeed.isEmpty {
                                    Text("- \(configStore.fileUploadSpeed)")
                                }
                                Spacer()
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    }

                    // Chunked upload progress
                    if case .chunkedUploading(let filename, let chunk, let total) = configStore.fileUploadStatus {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(filename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ProgressView(value: configStore.fileUploadProgress)
                            HStack {
                                Text("Chunk \(chunk)/\(total) — \(Int(configStore.fileUploadProgress * 100))%")
                                if !configStore.fileUploadSpeed.isEmpty {
                                    Text("- \(configStore.fileUploadSpeed)")
                                }
                                Spacer()
                                Button("Pause") {
                                    configStore.pauseChunkedUpload()
                                }
                                .font(.caption2)
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    }

                    // Chunked upload paused
                    if case .chunkedPaused(let filename, let chunk, let total) = configStore.fileUploadStatus {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(filename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ProgressView(value: configStore.fileUploadProgress)
                            HStack {
                                Text("Paused at chunk \(chunk)/\(total)")
                                Spacer()
                                Button("Resume") {
                                    Task {
                                        await configStore.resumeChunkedUpload()
                                    }
                                }
                                .font(.caption2)
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }

                    // File upload result
                    switch configStore.fileUploadStatus {
                    case .idle, .uploading, .chunkedUploading, .chunkedPaused:
                        EmptyView()
                    case .success(let clipID, let filename, let fileSize, let expiresAt):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text(configStore.transferMode == .lanServer ? "File delivery request sent" : "Bluetooth file sent")
                                    .foregroundColor(.green)
                            }
                            Text(configStore.sendSuccessDetail)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Group {
                                HStack {
                                    Text("Clip ID:")
                                        .foregroundColor(.secondary)
                                    Text(clipID)
                                        .fontWeight(.semibold)
                                        .textSelection(.enabled)
                                }
                                HStack {
                                    Text("File:")
                                        .foregroundColor(.secondary)
                                    Text(filename)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                HStack {
                                    Text("Size:")
                                        .foregroundColor(.secondary)
                                    Text(fileSize)
                                }
                                HStack {
                                    Text("Expires:")
                                        .foregroundColor(.secondary)
                                    Text(expiresAt)
                                }
                            }
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                    case .error(let message):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text(message)
                                    .foregroundColor(.red)
                            }
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }
                }

                // Bluetooth receive progress
                if configStore.bluetoothReceiveProgress > 0, let filename = configStore.bluetoothReceiveFilename {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                            Text("Receiving via Bluetooth")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        Text(filename)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProgressView(value: configStore.bluetoothReceiveProgress)
                        Text("\(Int(configStore.bluetoothReceiveProgress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }

                Divider()

                if configStore.transferMode == .bluetooth {
                    // Bluetooth status section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Bluetooth")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                        }

                        HStack(spacing: 6) {
                            Circle()
                                .fill(bluetoothStatusColor(configStore.bluetoothConnectionStatus))
                                .frame(width: 8, height: 8)
                            Text(bluetoothStatusText(configStore.bluetoothConnectionStatus))
                                .font(.caption)
                            Spacer()
                        }
                        .padding(8)
                        .background(bluetoothStatusColor(configStore.bluetoothConnectionStatus).opacity(0.1))
                        .cornerRadius(6)

                        if let name = configStore.bluetoothConnectedDeviceName {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .foregroundColor(.blue)
                                Text("Connected to \(name)")
                                    .font(.caption)
                            }
                        }

                        if !configStore.isSendReady {
                            Text("Pair a device in Settings to send and receive.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(8)
                        }
                    }
                } else {
                    // Server queue section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Queue Mode & Recovery")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                Task { await configStore.fetchQueue() }
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }

                        if let error = configStore.queueError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(error)
                                    .foregroundColor(.orange)
                            }
                            .font(.caption)
                            .padding(8)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                        }

                        if configStore.queueItems.isEmpty && configStore.queueError == nil {
                            Text("Queue is empty \u{2014} copy something and click the icon.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(8)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(configStore.queueItems) { item in
                                        queueRow(item)
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                }
            }

            // Embedded server management panel
            if serverConfig.serverEnabled {
                Divider()
                serverManagementSection
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
        }
        .overlay(
            Group {
                if isFullPanelDragTargeted {
                    ZStack {
                        Color.accentColor.opacity(0.08)
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                Color.accentColor,
                                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                            )
                            .padding(4)
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title)
                                .foregroundColor(.accentColor)
                            Text("Drop to send")
                                .font(.headline)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        )
        .onDrop(of: [.fileURL, .plainText], isTargeted: $isFullPanelDragTargeted) { providers in
            handlePanelDrop(providers)
        }
        .onAppear {
            refreshClipboard()
            if configStore.transferMode == .lanServer {
                Task { await configStore.fetchQueue() }
                startQueueRefresh()
            }
        }
        .onDisappear {
            stopQueueRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClipboard()
        }
    }

    // MARK: - Server Status

    private var serverStatusColor: Color {
        if !serverConfig.serverEnabled { return .gray }
        return serverProcess.isRunning ? .green : .red
    }

    // MARK: - Server Management Section

    @ViewBuilder
    private var serverManagementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Server")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Circle()
                    .fill(serverStatusColor)
                    .frame(width: 8, height: 8)
                Text(serverProcess.isRunning ? "Running" : "Stopped")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Start / Stop / Restart buttons
            HStack(spacing: 8) {
                if serverProcess.isRunning {
                    Button("Stop") {
                        serverProcess.stop()
                    }
                    Button("Restart") {
                        serverProcess.restart()
                    }
                } else {
                    Button("Start") {
                        serverProcess.start()
                    }
                }
            }
            .font(.caption)

            // Storage stats
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .foregroundColor(.secondary)
                Text(configStore.formatBytes(serverConfig.usedSpaceBytes))
                    .font(.caption)
                Text("used")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .onAppear {
                serverConfig.refreshUsedSpace()
            }

            Text(serverConfig.storagePath)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Connected devices
            if serverProcess.isRunning {
                Divider()
                HStack {
                    Text("Connected Devices")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { fetchConnectedDevices() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }

                if let error = devicesError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if connectedDevices.isEmpty {
                    Text("No devices connected")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(connectedDevices) { device in
                        HStack(spacing: 6) {
                            Image(systemName: devicePlatformIcon(device.platform))
                                .foregroundColor(.accentColor)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text(device.platform)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Log viewer
            DisclosureGroup(isExpanded: $showServerLogs) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(serverProcess.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 150)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                    .onChange(of: serverProcess.logLines.count) { _ in
                        if let lastIndex = serverProcess.logLines.indices.last {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            } label: {
                Text("Logs (\(serverProcess.logLines.count))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if serverProcess.isRunning {
                fetchConnectedDevices()
            }
        }
    }

    private func devicePlatformIcon(_ platform: String) -> String {
        switch platform {
        case "macos": return "laptopcomputer"
        case "windows": return "pc"
        case "android": return "apps.iphone"
        case "linux": return "server.rack"
        default: return "desktopcomputer"
        }
    }

    private func fetchConnectedDevices() {
        guard serverProcess.isRunning else { return }
        let port = serverConfig.port.isEmpty ? "8080" : serverConfig.port
        let urlString = "http://localhost:\(port)/api/v1/devices"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        if serverConfig.authEnabled && !serverConfig.accessToken.isEmpty {
            request.setValue("Bearer \(serverConfig.accessToken)", forHTTPHeaderField: "Authorization")
        }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    devicesError = "Failed to fetch devices"
                    return
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let devices = try decoder.decode([ConnectedDevice].self, from: data)
                connectedDevices = devices
                devicesError = nil
            } catch {
                devicesError = "Could not reach server"
            }
        }
    }

    private var isFileUploading: Bool {
        switch configStore.fileUploadStatus {
        case .uploading, .chunkedUploading:
            return true
        default:
            return false
        }
    }

    private func refreshClipboard() {
        clipboardText = NSPasteboard.general.string(forType: .string)
    }

    private func startQueueRefresh() {
        queueRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                await configStore.fetchQueue()
            }
        }
    }

    private func stopQueueRefresh() {
        queueRefreshTimer?.invalidate()
        queueRefreshTimer = nil
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await configStore.sendFile(url: url)
            }
        }
    }

    private func bluetoothStatusColor(_ status: ConfigStore.BluetoothConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private func bluetoothStatusText(_ status: ConfigStore.BluetoothConnectionStatus) -> String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    @ViewBuilder
    private func queueRow(_ item: QueueItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.typeIcon)
                .foregroundColor(.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let badgeLabel = item.deliveryState.badgeLabel {
                    Text(badgeLabel)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.14))
                        .cornerRadius(999)
                }

                HStack(spacing: 4) {
                    Text(
                        item.deliveryState == .targetedFallback
                            ? "Automatic delivery missed; click Receive to recover"
                            : "\(configStore.formatBytes(item.sizeBytes)) • \(item.age)"
                    )
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: {
                Task { await configStore.receiveQueueItem(item) }
            }) {
                Text("Receive")
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func handlePanelDrop(_ providers: [NSItemProvider]) -> Bool {
        // Try file URLs first
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        await configStore.sendFile(url: url)
                    }
                }
                return true
            }
        }
        // Fall back to text
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.plain-text") {
                provider.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { item, _ in
                    guard let text = item as? String else { return }
                    Task { @MainActor in
                        let _ = await configStore.sendText(text)
                    }
                }
                return true
            }
        }
        return false
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                await configStore.sendFile(url: url)
            }
        }
        return true
    }
}
