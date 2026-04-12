import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var serverProcess: ServerProcess

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("CopyEverywhere Server")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            Divider()

            // Start / Stop controls
            HStack(spacing: 8) {
                if serverProcess.isRunning {
                    Button("Stop Server") {
                        serverProcess.stop()
                    }
                    Button("Restart") {
                        serverProcess.restart()
                    }
                } else {
                    Button("Start Server") {
                        serverProcess.start()
                    }
                }
            }

            Divider()

            // Log output
            Text("Logs")
                .font(.subheadline)
                .foregroundColor(.secondary)

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
                .frame(maxHeight: 200)
                .onChange(of: serverProcess.logLines.count) { _ in
                    if let last = serverProcess.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Quit
            HStack {
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
        .padding()
        .frame(width: 400)
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
}
