import SwiftUI

struct ConfigView: View {
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Configuration")
                .font(.headline)

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
        .padding()
    }

    // MARK: - Discovered Servers

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
                                // Show checkmark if this server is currently selected
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
