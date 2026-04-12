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
                Text("Access Token")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                SecureField("Enter access token", text: $configStore.accessToken)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Test Connection") {
                    Task {
                        await configStore.testConnection()
                    }
                }
                .disabled(configStore.hostURL.isEmpty || configStore.accessToken.isEmpty)

                Spacer()

                Button("Save") {
                    configStore.save()
                }
                .disabled(configStore.hostURL.isEmpty || configStore.accessToken.isEmpty)
                .buttonStyle(.borderedProminent)
            }

            connectionStatusView
        }
        .padding()
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
