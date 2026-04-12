import SwiftUI

@main
struct CopyEverywhereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var configStore = ConfigStore()
    @StateObject private var historyStore = HistoryStore()

    var body: some Scene {
        MenuBarExtra("CopyEverywhere", systemImage: "doc.on.clipboard") {
            MenuBarView()
                .environmentObject(configStore)
                .environmentObject(historyStore)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
