import AppKit
import SwiftUI

struct MainPanelView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var showingConfig = false
    @State private var clipboardText: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("CopyEverywhere")
                    .font(.headline)
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
                                Text("Sent successfully!")
                                    .foregroundColor(.green)
                            }
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
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
        .onAppear {
            refreshClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClipboard()
        }
    }

    private func refreshClipboard() {
        clipboardText = NSPasteboard.general.string(forType: .string)
    }
}
