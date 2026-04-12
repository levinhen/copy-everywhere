import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var serverProcess: ServerProcess
    @EnvironmentObject var serverConfig: ServerConfig

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                Divider()
                statusSection
                Divider()
                configSection
                Divider()
                logSection
                Divider()
                footerSection
            }
            .padding()
        }
        .frame(width: 400, height: 520)
        .onAppear { serverConfig.refreshUsedSpace() }
    }

    // MARK: - Header + controls

    private var headerSection: some View {
        HStack {
            Text("CopyEverywhere Server")
                .font(.headline)
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(serverProcess.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(serverProcess.isRunning ? "Running" : "Stopped")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Status display

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status")
                .font(.subheadline)
                .foregroundColor(.secondary)

            LabeledRow(label: "Listen address", value: "0.0.0.0:\(serverConfig.port)")
            LabeledRow(label: "Storage path", value: serverConfig.storagePath)
            LabeledRow(label: "Used space", value: formattedSize(serverConfig.usedSpaceBytes))
        }
    }

    // MARK: - Config fields

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configuration")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                Text("Port")
                    .frame(width: 90, alignment: .leading)
                TextField("8080", text: $serverConfig.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            HStack {
                Text("Storage path")
                    .frame(width: 90, alignment: .leading)
                TextField("~/…/data", text: $serverConfig.storagePath)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                Button("Browse…") { browseStoragePath() }
                    .controlSize(.small)
            }

            HStack {
                Text("TTL (hours)")
                    .frame(width: 90, alignment: .leading)
                TextField("1", value: $serverConfig.ttlHours, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
            }

            HStack {
                Toggle("Require auth", isOn: $serverConfig.authEnabled)
            }

            if serverConfig.authEnabled {
                HStack {
                    Text("Access token")
                        .frame(width: 90, alignment: .leading)
                    SecureField("token", text: $serverConfig.accessToken)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Save & Restart") {
                    serverConfig.save()
                    serverProcess.restart()
                    // Refresh used space after restart
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        serverConfig.refreshUsedSpace()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Save") {
                    serverConfig.save()
                }
                .controlSize(.small)

                Text("Changes apply on next restart")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Log output

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Logs")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") { serverProcess.logLines.removeAll() }
                    .controlSize(.mini)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(serverProcess.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .onChange(of: serverProcess.logLines.count) { _ in
                    if let last = serverProcess.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 8) {
            if serverProcess.isRunning {
                Button("Stop Server") { serverProcess.stop() }
                Button("Restart") { serverProcess.restart() }
            } else {
                Button("Start Server") { serverProcess.start() }
            }
            Spacer()
            Button("Quit") {
                serverProcess.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .foregroundColor(.red)
        }
    }

    // MARK: - Helpers

    private func browseStoragePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            serverConfig.storagePath = url.path
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Reusable labeled row

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
