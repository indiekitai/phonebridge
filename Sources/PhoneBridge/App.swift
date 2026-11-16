import AppKit
import SwiftUI

@main
struct PhoneBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DeviceStore()

    var body: some Scene {
        WindowGroup("PhoneBridge") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    store.start()
                    if let out = SelfTest.outputDirectory {
                        Task { await SelfTest.run(store: store, out: out) }
                    }
                    if DemoMode.isOn {
                        Task { await DemoMode.run(store: store) }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
