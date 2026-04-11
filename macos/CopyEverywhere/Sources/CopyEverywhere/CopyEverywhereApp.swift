import SwiftUI

@main
struct CopyEverywhereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var configStore = ConfigStore()

    var body: some Scene {
        MenuBarExtra("CopyEverywhere", systemImage: "doc.on.clipboard") {
            MenuBarView()
                .environmentObject(configStore)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
