import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainPanelView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var showingConfig = false
    @State private var clipboardText: String? = nil
    @State private var manualClipID: String = ""
    @State private var isDragTargeted = false
    @State private var downloadClipID: String = ""

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
                                Text("File sent!")
                                    .foregroundColor(.green)
                            }
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

                Divider()

                // Receive section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Receive")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button(action: {
                        Task {
                            await configStore.receiveLatest()
                        }
                    }) {
                        HStack {
                            if configStore.receiveStatus == .receiving {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                                Text("Receiving...")
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Receive Latest")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(configStore.receiveStatus == .receiving)

                    HStack(spacing: 8) {
                        TextField("Clip ID", text: $manualClipID)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)

                        Button("Fetch") {
                            Task {
                                await configStore.receiveByID(manualClipID)
                            }
                        }
                        .disabled(manualClipID.trimmingCharacters(in: .whitespaces).isEmpty || configStore.receiveStatus == .receiving)
                    }

                    // Receive status display
                    switch configStore.receiveStatus {
                    case .idle:
                        EmptyView()
                    case .receiving:
                        EmptyView()
                    case .success(let clipID):
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Clip \(clipID) copied to clipboard")
                                .foregroundColor(.green)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                    case .noContent:
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.orange)
                            Text("No content available or expired")
                                .foregroundColor(.orange)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    case .error(let message):
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text(message)
                                .foregroundColor(.red)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }
                }

                Divider()

                // Download file section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Download File")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        TextField("Clip ID", text: $downloadClipID)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)

                        Button("Lookup") {
                            Task {
                                await configStore.fetchClipMetadata(downloadClipID)
                            }
                        }
                        .disabled(downloadClipID.trimmingCharacters(in: .whitespaces).isEmpty || configStore.fileDownloadStatus == .fetchingMetadata)
                    }

                    switch configStore.fileDownloadStatus {
                    case .idle:
                        EmptyView()
                    case .fetchingMetadata:
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                            Text("Fetching metadata...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .metadataLoaded(let meta):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(.accentColor)
                                Text(meta.filename ?? "Untitled")
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Group {
                                HStack {
                                    Text("Type:")
                                        .foregroundColor(.secondary)
                                    Text(meta.type)
                                }
                                HStack {
                                    Text("Size:")
                                        .foregroundColor(.secondary)
                                    Text(configStore.formatBytes(meta.sizeBytes))
                                }
                                HStack {
                                    Text("Uploaded:")
                                        .foregroundColor(.secondary)
                                    Text(meta.createdAt)
                                }
                                HStack {
                                    Text("Expires:")
                                        .foregroundColor(.secondary)
                                    Text(meta.expiresAt)
                                }
                            }

                            Button(action: { chooseDownloadLocation(clipID: meta.id, suggestedName: meta.filename) }) {
                                HStack {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("Download")
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    case .downloading(let filename):
                        VStack(alignment: .leading, spacing: 4) {
                            Text(filename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ProgressView(value: configStore.fileDownloadProgress)
                            HStack {
                                Text("\(Int(configStore.fileDownloadProgress * 100))%")
                                if !configStore.fileDownloadSpeed.isEmpty {
                                    Text("- \(configStore.fileDownloadSpeed)")
                                }
                                Spacer()
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    case .success(let savedPath):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Downloaded successfully!")
                                    .foregroundColor(.green)
                            }
                            Text(savedPath)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                    case .uploadIncomplete:
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Upload incomplete - download unavailable")
                                .foregroundColor(.orange)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    case .error(let message):
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text(message)
                                .foregroundColor(.red)
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

    private func chooseDownloadLocation(clipID: String, suggestedName: String?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? clipID
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await configStore.downloadFile(clipID: clipID, saveURL: url)
            }
        }
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
