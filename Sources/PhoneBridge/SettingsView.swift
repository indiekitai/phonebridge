import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: DeviceStore
    @AppStorage(SettingsKey.saveDirectory) private var saveDirectory = Defaults.saveDirectory
    @AppStorage(SettingsKey.copyToClipboard) private var copyToClipboard = true
    @AppStorage(SettingsKey.adbPath) private var adbPath = ""

    var body: some View {
        Form {
            Section("保存") {
                LabeledContent("保存到") {
                    HStack {
                        Text(saveDirectory).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 280, alignment: .leading)
                        Button("选择…") { chooseFolder() }
                        Button("打开") {
                            let url = URL(fileURLWithPath: saveDirectory)
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Toggle("截图后复制到剪贴板", isOn: $copyToClipboard)
                Text("截图、从 Android 下载的文件、从 iPhone 导入的照片都放在这里。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("adb") {
                TextField("adb 路径", text: $adbPath, prompt: Text("留空自动查找"))
                    .onSubmit { store.relocateADB() }
                LabeledContent("正在使用") {
                    Text(store.adbPath ?? "没找到").foregroundStyle(store.adbPath == nil ? .red : .secondary)
                        .textSelection(.enabled)
                }
                Button("重新查找") { store.relocateADB() }
                Text("留空时按终端的 PATH 查找 adb，和终端用同一个，避免版本不同把正在运行的 adb 服务重启。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url.path }
    }
}
