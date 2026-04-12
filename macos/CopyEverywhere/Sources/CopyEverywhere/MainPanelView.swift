import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainPanelView: View {
    @EnvironmentObject var configStore: ConfigStore
    @State private var showingConfig = false
    @State private var clipboardText: String? = nil
    @State private var isDragTargeted = false
    @State private var isFullPanelDragTargeted = false
    @State private var queueRefreshTimer: Timer?

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

                // Server queue section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Queue")
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
            Task { await configStore.fetchQueue() }
            startQueueRefresh()
        }
        .onDisappear {
            stopQueueRefresh()
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

                HStack(spacing: 4) {
                    Text(configStore.formatBytes(item.sizeBytes))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(item.age)
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
