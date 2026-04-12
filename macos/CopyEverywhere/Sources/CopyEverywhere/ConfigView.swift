import SwiftUI

struct ConfigView: View {
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Configuration")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Host URL")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("https://your-server.com:8080", text: $configStore.hostURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Access Token (optional)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                SecureField("Leave empty if server auth is disabled", text: $configStore.accessToken)
                    .textFieldStyle(.roundedBorder)
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
