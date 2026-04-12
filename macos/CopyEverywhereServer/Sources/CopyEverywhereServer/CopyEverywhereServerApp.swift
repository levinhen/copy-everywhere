import SwiftUI
import AppKit

@main
struct CopyEverywhereServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty scene — all UI is driven by the NSStatusItem popover
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private let serverProcess = ServerProcess()

    // SF Symbols for menu bar icon
    private let runningIcon = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Server Running")
    private let stoppedIcon = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Server Stopped")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupPopover()
        setupStatusItem()
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        serverProcess.stop()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = stoppedIcon
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 400, height: 420)

        let contentView = MenuBarView()
            .environmentObject(serverProcess)
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    // MARK: - Icon updates

    private func updateIcon() {
        // Observe isRunning changes to tint the icon
        Task { @MainActor in
            for await _ in serverProcess.$isRunning.values {
                self.applyIconTint()
            }
        }
    }

    private func applyIconTint() {
        guard let button = statusItem.button else { return }
        if serverProcess.isRunning {
            let img = runningIcon?.copy() as? NSImage ?? NSImage()
            img.isTemplate = false
            // Tint green by drawing into a new image
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect)
                NSColor.systemGreen.withAlphaComponent(0.8).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            button.image = tinted
        } else {
            stoppedIcon?.isTemplate = true
            button.image = stoppedIcon
        }
    }

    // MARK: - Popover toggle

    @objc private func togglePopover() {
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
}
