import SwiftUI

struct ConfigView: View {
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configuration")
                .font(.headline)

            // Mode toggle
            Picker("Transfer Mode", selection: Binding(
                get: { configStore.transferMode },
                set: { configStore.setTransferMode($0) }
            )) {
                ForEach(TransferMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if configStore.transferMode == .lanServer {
                lanServerSection
            } else {
                bluetoothSection
            }
        }
        .padding()
    }

    // MARK: - LAN Server Section

    @ViewBuilder
    private var lanServerSection: some View {
        // Discovered Servers section
        discoveredServersSection

        VStack(alignment: .leading, spacing: 8) {
            Text("Host URL")
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextField("https://your-server.com:8080", text: $configStore.hostURL)
                .textFieldStyle(.roundedBorder)
        }

        // Only show token field when auth is required or unknown
        if configStore.serverAuthRequired != false {
            VStack(alignment: .leading, spacing: 8) {
                Text("Access Token\(configStore.serverAuthRequired == true ? "" : " (optional)")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                SecureField(
                    configStore.serverAuthRequired == true
                        ? "Required by this server"
                        : "Leave empty if server auth is disabled",
                    text: $configStore.accessToken
                )
                .textFieldStyle(.roundedBorder)
            }
        }

        if !configStore.deviceID.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Registered Device")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .foregroundColor(.accentColor)
                    Text(configStore.deviceName)
                    Text("(\(configStore.deviceID))")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Target Device")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { configStore.targetDeviceID ?? "" },
                    set: { configStore.targetDeviceID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("(Queue \u{2014} any device)")
                        .tag("")
                    ForEach(configStore.availableDevices) { device in
                        HStack {
                            Text(platformIcon(device.platform))
                            Text("\(device.name)")
                        }
                        .tag(device.id)
                    }
                }
                .labelsHidden()
            }
            .onAppear {
                Task { await configStore.fetchDevices() }
            }
        }

        HStack {
            Button("Test Connection") {
                Task {
                    await configStore.testConnection()
                }
            }
            .disabled(configStore.hostURL.isEmpty)

            Spacer()

            Button("Save") {
                configStore.save()
            }
            .disabled(configStore.hostURL.isEmpty)
            .buttonStyle(.borderedProminent)
        }

        connectionStatusView
    }

    // MARK: - Bluetooth Section

    @ViewBuilder
    private var bluetoothSection: some View {
        // Connection status
        bluetoothStatusBadge

        // Paired devices
        pairedDevicesSection

        // Scan section
        scanSection
    }

    @ViewBuilder
    private var bluetoothStatusBadge: some View {
        HStack(spacing: 8) {
            switch configStore.bluetoothConnectionStatus {
            case .disconnected:
                Image(systemName: "circle.fill")
                    .foregroundColor(.gray)
                    .font(.caption2)
                Text("Disconnected")
                    .foregroundColor(.secondary)
            case .connecting:
                ProgressView()
                    .controlSize(.mini)
                Text("Connecting...")
                    .foregroundColor(.secondary)
            case .connected:
                Image(systemName: "circle.fill")
                    .foregroundColor(.green)
                    .font(.caption2)
                Text("Connected to \(configStore.bluetoothConnectedDeviceName ?? "device")")
                    .foregroundColor(.green)
            case .error(let message):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption2)
                Text(message)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var pairedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired Devices")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if configStore.pairedDevices.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "wave.3.right")
                        .foregroundColor(.secondary)
                    Text("No paired devices. Scan to find nearby devices.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(configStore.pairedDevices) { device in
                        HStack(spacing: 8) {
                            Image(systemName: "laptopcomputer")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text(device.address)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()

                            // Connected indicator
                            if configStore.bluetoothConnectedDeviceName == device.name,
                               configStore.bluetoothConnectionStatus == .connected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }

                            // Connect/Disconnect button
                            if configStore.bluetoothConnectedDeviceName == device.name,
                               configStore.bluetoothConnectionStatus == .connected {
                                Button("Disconnect") {
                                    configStore.disconnectBluetooth()
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            } else {
                                Button("Connect") {
                                    configStore.reconnectBluetoothDevice(device)
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .disabled(configStore.bluetoothConnectionStatus == .connecting)
                            }

                            // Forget button
                            Button {
                                configStore.forgetBluetoothDevice(device)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Forget Device")
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(configStore.bluetoothConnectedDeviceName == device.name
                                      ? Color.accentColor.opacity(0.1)
                                      : Color.clear)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        let discovery = configStore.bluetoothDiscovery

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scan Nearby Devices")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if discovery.isScanning {
                    Button("Stop") {
                        discovery.stopScan()
                    }
                    .font(.caption)
                } else {
                    Button("Scan") {
                        discovery.startScan()
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                }
            }

            if discovery.isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Scanning for CopyEverywhere devices...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = discovery.scanError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if !discovery.discoveredDevices.isEmpty {
                VStack(spacing: 4) {
                    ForEach(discovery.discoveredDevices) { device in
                        let isPaired = configStore.pairedDevices.contains { $0.id == device.id }
                        Button {
                            if !isPaired {
                                configStore.pairBluetoothDevice(device)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "wave.3.right")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(device.address)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if isPaired {
                                    Text("Paired")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                } else {
                                    Text("Tap to Pair")
                                        .font(.caption2)
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPaired)
                    }
                }
            } else if !discovery.isScanning && discovery.scanError == nil {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.secondary)
                    Text("No CopyEverywhere devices found nearby")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Discovered Servers (LAN)

    @ViewBuilder
    private var discoveredServersSection: some View {
        let servers = configStore.bonjourBrowser.discoveredServers
        let isSearching = configStore.bonjourBrowser.isSearching

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Discovered Servers")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if isSearching {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if servers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.secondary)
                    Text(isSearching ? "Scanning LAN..." : "No servers found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(servers) { server in
                        Button {
                            configStore.selectDiscoveredServer(server)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "server.rack")
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text("\(server.host):\(server.port)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if !server.version.isEmpty {
                                    Text("v\(server.version)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if server.authRequired {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                                if configStore.hostURL == "http://\(server.host):\(server.port)" {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(configStore.hostURL == "http://\(server.host):\(server.port)"
                                          ? Color.accentColor.opacity(0.1)
                                          : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform {
        case "macos": return "\u{1F4BB}" // laptop
        case "windows": return "\u{1F5A5}" // desktop
        case "linux": return "\u{1F427}" // penguin
        default: return "\u{1F4F1}" // phone
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch configStore.connectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Testing connection...")
                    .foregroundColor(.secondary)
            }
        case .success(let latencyMs):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connected (\(latencyMs)ms)")
                    .foregroundColor(.green)
            }
        case .error(let message):
            HStack(alignment: .top) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
