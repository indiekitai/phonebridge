import AppKit
import SwiftUI

struct ScreenshotPane: View {
    @EnvironmentObject var store: DeviceStore
    let ref: DeviceRef
    @State private var display: String = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var image: NSImage?

    private var displays: [String] {
        if case .android(let s) = ref { return store.displays[s] ?? [] }
        return []
    }

    private var fileURL: URL? { store.lastShot[ref] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    Task { await take() }
                } label: {
                    Label(busy ? "截图中…" : "截图", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(busy)

                if displays.count > 1 {
                    Picker("屏幕", selection: $display) {
                        ForEach(Array(displays.enumerated()), id: \.element) { i, id in
                            Text(i == 0 ? "主屏" : "屏 \(i + 1)").tag(id)
                        }
                    }
                    .frame(width: 140)
                }

                Text(message ?? "⌘S 截图，截完自动保存\(copyEnabled ? "并复制" : "")")
                    .font(.callout)
                    .foregroundStyle(isError ? .red : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let url = fileURL {
                    Button("复制") { copy(url) }
                    Button("在 Finder 显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            .padding(12)
            Divider()

            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(radius: 6)
                        .padding(20)
                        .onDrag {
                            fileURL.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
                        }
                        .help("可以直接拖到别的 App 里")
                } else {
                    Text("还没有截图").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if display.isEmpty { display = displays.first ?? "" }
            if let url = fileURL { image = NSImage(contentsOf: url) }
        }
        .onChange(of: fileURL) { _, url in
            image = url.flatMap { NSImage(contentsOf: $0) }
        }
        .onChange(of: displays) { _, new in
            if !new.contains(display) { display = new.first ?? "" }
        }
    }

    private var copyEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.copyToClipboard) as? Bool ?? true
    }

    private func take() async {
        busy = true
        defer { busy = false }
        let start = Date()
        do {
            let url = try await store.screenshot(ref, display: displays.count > 1 ? display : nil)
            let secs = String(format: "%.1f", Date().timeIntervalSince(start))
            message = "\(secs) 秒 · \(copyEnabled ? "已复制 · " : "")\(url.lastPathComponent)"
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func copy(_ url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        message = "已复制 \(url.lastPathComponent)"
        isError = false
    }
}
