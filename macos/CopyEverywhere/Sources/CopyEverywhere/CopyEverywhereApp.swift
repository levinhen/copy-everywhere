import SwiftUI
import UserNotifications

@main
struct CopyEverywhereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let configStore = ConfigStore()
    let serverConfig = ServerConfig()
    let serverProcess = ServerProcess()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var keyMonitor: Any?

    private let normalIcon = NSImage(
        systemSymbolName: "doc.on.clipboard",
        accessibilityDescription: "CopyEverywhere"
    )
    private let dropIcon = NSImage(
        systemSymbolName: "arrow.down.doc.fill",
        accessibilityDescription: "Drop to send"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Wire server config into the process manager
        serverProcess.config = serverConfig

        setupPopover()
        setupStatusItem()
        setupKeyMonitor()
        // Start SSE connection if already configured
        configStore.startSSE()

        // Auto-start embedded server if configured
        if serverConfig.serverEnabled && serverConfig.autoStartServer {
            serverProcess.start()
            autoConnectToLocalServer()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Graceful shutdown: send SIGTERM to the embedded server if running
        serverProcess.stop()
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 360, height: 500)

        let contentView = MenuBarView()
            .environmentObject(configStore)
            .environmentObject(serverConfig)
            .environmentObject(serverProcess)
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Status Item + Drag-and-Drop

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = normalIcon
        button.action = #selector(togglePopover)
        button.target = self

        let dropView = StatusItemDropView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.onFileDrop = { [weak self] urls in
            self?.handleFileDrop(urls)
        }
        dropView.onTextDrop = { [weak self] text in
            self?.handleTextDrop(text)
        }
        dropView.onDragEnter = { [weak self] in
            self?.statusItem.button?.image = self?.dropIcon
        }
        dropView.onDragExit = { [weak self] in
            self?.statusItem.button?.image = self?.normalIcon
        }
        button.addSubview(dropView)
    }

    // MARK: - Keyboard Monitor

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Intercept ⌘V while popover is shown
            if self.popover.isShown,
               event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "v" {
                self.handlePasteShortcut()
                return nil // consume the event
            }
            return event
        }
    }

    private func handlePasteShortcut() {
        let pb = NSPasteboard.general

        // Priority: text → image → file URL
        if let text = pb.string(forType: .string), !text.isEmpty {
            Task { @MainActor in
                let result = await configStore.sendText(text)
                if result.success {
                    let preview = text.count > 40 ? String(text.prefix(40)) + "..." : text
                    configStore.toastMessage = "Sent: \(preview)"
                } else {
                    configStore.toastMessage = "Failed to send: \(result.message)"
                }
                dismissToastAfterDelay()
            }
        } else if let imgData = pb.data(forType: .png) ?? pb.data(forType: .tiff), !imgData.isEmpty {
            // Save image to temp file and send as file
            let ext = pb.data(forType: .png) != nil ? "png" : "tiff"
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipboard_image.\(ext)")
            do {
                try imgData.write(to: tempURL)
                Task { @MainActor in
                    await configStore.sendFile(url: tempURL)
                    switch configStore.fileUploadStatus {
                    case .success(_, let filename, _, _):
                        configStore.toastMessage = "Sent: \(filename)"
                    case .error(let msg):
                        configStore.toastMessage = "Failed to send: \(msg)"
                    default:
                        break
                    }
                    dismissToastAfterDelay()
                    try? FileManager.default.removeItem(at: tempURL)
                }
            } catch {
                configStore.toastMessage = "Failed to send image: \(error.localizedDescription)"
                dismissToastAfterDelay()
            }
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  let fileURL = urls.first {
            Task { @MainActor in
                await configStore.sendFile(url: fileURL)
                switch configStore.fileUploadStatus {
                case .success(_, let filename, _, _):
                    configStore.toastMessage = "Sent: \(filename)"
                case .error(let msg):
                    configStore.toastMessage = "Failed to send: \(msg)"
                default:
                    break
                }
                dismissToastAfterDelay()
            }
        } else {
            configStore.toastMessage = "Clipboard is empty"
            dismissToastAfterDelay()
        }
    }

    private func dismissToastAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            configStore.toastMessage = nil
        }
    }

    // MARK: - Drop Handlers

    private func handleFileDrop(_ urls: [URL]) {
        guard configStore.isSendReady else {
            Self.sendNotification(body: configStore.transferMode == .bluetooth ? "Bluetooth not connected" : "Configure server first")
            return
        }
        Task { @MainActor in
            for url in urls {
                await configStore.sendFile(url: url)
                switch configStore.fileUploadStatus {
                case .success(_, let filename, _, _):
                    Self.sendNotification(body: "Sent \(filename)")
                case .error(let msg):
                    Self.sendNotification(body: "Failed to send: \(msg)")
                default:
                    break
                }
            }
        }
    }

    private func handleTextDrop(_ text: String) {
        guard configStore.isSendReady else {
            Self.sendNotification(body: configStore.transferMode == .bluetooth ? "Bluetooth not connected" : "Configure server first")
            return
        }
        Task { @MainActor in
            let result = await configStore.sendText(text)
            if result.success {
                Self.sendNotification(body: "Sent text (\(text.count) chars)")
            } else {
                Self.sendNotification(body: "Failed to send: \(result.message)")
            }
        }
    }

    // MARK: - Embedded Server Toggle

    /// Called when the user toggles the embedded server on/off.
    func setServerEnabled(_ enabled: Bool) {
        serverConfig.serverEnabled = enabled
        serverConfig.save()
        if enabled {
            serverProcess.start()
            autoConnectToLocalServer()
        } else {
            serverProcess.stop()
            // Keep hostURL as-is so user can still point at a remote server
        }
    }

    /// Sets the client's hostURL to the local embedded server.
    func autoConnectToLocalServer() {
        let port = serverConfig.port.isEmpty ? "8080" : serverConfig.port
        configStore.hostURL = "http://localhost:\(port)"
        if serverConfig.authEnabled && !serverConfig.accessToken.isEmpty {
            configStore.accessToken = serverConfig.accessToken
        }
        configStore.save()
    }

    // MARK: - Notifications

    static func sendNotification(body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "CopyEverywhere"
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
