import Foundation

/// `--demo`: for README screenshots. Shows iPhones as plain "iPhone" (the real name is usually
/// "<owner>'s iPhone") and Android devices without serial or IP, selects the first iPhone and takes one screenshot of it.
enum DemoMode {
    static let isOn = CommandLine.arguments.contains("--demo")

    @MainActor
    static func run(store: DeviceStore) async {
        for _ in 0..<20 {
            if let phone = store.ios.first {
                store.selection = .ios(phone.id)
                _ = try? await store.screenshot(.ios(phone.id), display: nil)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
