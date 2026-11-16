import PhoneBridgeCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let ref = store.selection {
                DeviceDetail(ref: ref).id(ref)
            } else {
                EmptyState()
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        List(selection: $store.selection) {
            Section("Android") {
                if store.android.isEmpty {
                    Text(store.adbError ?? "没有设备").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.android) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(d.displayName, systemImage: "candybarphone")
                        Text(d.isReady ? d.serial : "\(d.serial) · \(stateText(d.state))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(DeviceRef.android(d.serial))
                    .disabled(!d.isReady)
                }
            }
            Section("iPhone") {
                if store.ios.isEmpty {
                    Text("用 USB 连接并在手机上点「信任」").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.ios) { d in
                    Label(d.name, systemImage: "iphone").tag(DeviceRef.ios(d.id))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func stateText(_ s: String) -> String {
        switch s {
        case "unauthorized": return "请在设备上允许 USB 调试"
        case "offline": return "离线"
        default: return s
        }
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cable.connector").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("连接一台 Android（开 USB 调试）或 iPhone").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeviceDetail: View {
    enum Tab: Hashable { case screenshot, files, photos }

    @EnvironmentObject var store: DeviceStore
    let ref: DeviceRef
    @State private var tab: Tab = .screenshot

    var body: some View {
        VStack(spacing: 0) {
            switch tab {
            case .screenshot: ScreenshotPane(ref: ref)
            case .files:
                if case .android(let serial) = ref { FilesPane(serial: serial) }
            case .photos:
                if case .ios = ref { PhotosPane(deviceName: store.name(of: ref)) }
            }
        }
        .navigationTitle(store.name(of: ref))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) {
                    Text("截图").tag(Tab.screenshot)
                    if case .android = ref { Text("文件").tag(Tab.files) }
                    if case .ios = ref { Text("照片").tag(Tab.photos) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
        }
    }
}
