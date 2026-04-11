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
    let historyStore = HistoryStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

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
        setupPopover()
        setupStatusItem()
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 360, height: 500)

        let contentView = MenuBarView()
            .environmentObject(configStore)
            .environmentObject(historyStore)
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

    // MARK: - Drop Handlers

    private func handleFileDrop(_ urls: [URL]) {
        guard configStore.isConfigured else {
            Self.sendNotification(body: "Configure server first")
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
        guard configStore.isConfigured else {
            Self.sendNotification(body: "Configure server first")
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
