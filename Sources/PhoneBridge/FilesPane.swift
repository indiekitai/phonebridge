import AppKit
import PhoneBridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Android file browser: browse, upload (drag in or pick), download to the save folder.
/// No delete / rename / install on purpose: these are often shared work devices.
struct FilesPane: View {
    @EnvironmentObject var store: DeviceStore
    let serial: String

    @State private var path = "/sdcard"
    @State private var entries: [RemoteEntry] = []
    @State private var selection = Set<RemoteEntry.ID>()
    @State private var loading = false
    @State private var working: String?
    @State private var message: String?
    @State private var isError = false
    @State private var dropTargeted = false

    private let places: [(String, String)] = [
        ("内部存储", "/sdcard"),
        ("Download", "/sdcard/Download"),
        ("DCIM", "/sdcard/DCIM"),
        ("Pictures", "/sdcard/Pictures"),
        ("Documents", "/sdcard/Documents"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            table
            Divider()
            statusBar
        }
        .task(id: path) { await load() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { path = RemotePath.parent(path) } label: { Image(systemName: "chevron.up") }
                .help("上一级").disabled(path == "/")
            Menu {
                ForEach(places, id: \.1) { p in Button(p.0) { path = p.1 } }
            } label: { Image(systemName: "folder") }
                .menuStyle(.borderlessButton).frame(width: 40)
            Text(path).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
            Button("上传…") { pickAndUpload() }
            Button("下载到 Mac") { Task { await download() } }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || working != nil)
        }
        .padding(10)
    }

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("名称") { e in
                Label(e.name, systemImage: e.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(e.isDirectory ? Color.accentColor : .primary)
            }
            TableColumn("大小") { e in
                Text(e.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("修改时间") { e in
                Text(e.modified.formatted(date: .numeric, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150, max: 200)
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            if !ids.isEmpty {
                Button("下载到 Mac") { selection = ids; Task { await download() } }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first, let e = entries.first(where: { $0.id == id }) else { return }
            if e.isDirectory { path = e.path } else { selection = ids; Task { await download() } }
        }
        .overlay {
            if loading && entries.isEmpty { ProgressView() }
            else if !loading && entries.isEmpty { Text("空文件夹（或没有权限读取）").foregroundStyle(.secondary) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4)
                    .overlay(Text("松手上传到 \(path)").padding(8).background(.regularMaterial, in: Capsule()))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { await upload(providers) }
            return true
        }
    }

    private var statusBar: some View {
        HStack {
            if let working { ProgressView().controlSize(.small); Text(working) }
            else if let message { Text(message).foregroundStyle(isError ? .red : .secondary) }
            else { Text("把 Mac 上的文件拖进来就上传到当前文件夹；双击文件夹进入，双击文件下载").foregroundStyle(.secondary) }
            Spacer()
            Text("\(entries.count) 项").foregroundStyle(.secondary)
        }
        .font(.callout)
        .lineLimit(2)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: Actions

    private func load() async {
        guard let adb = store.adb else { return }
        loading = true
        let dir = path
        do {
            let list = try await Task.detached { try adb.list(serial: serial, directory: dir) }.value
            guard dir == path else { return }
            entries = list
            selection = selection.filter { id in list.contains { $0.id == id } }
        } catch {
            entries = []
            show(error.localizedDescription, error: true)
        }
        loading = false
    }

    private func download() async {
        guard let adb = store.adb else { return }
        let picked = entries.filter { selection.contains($0.id) }
        guard !picked.isEmpty else { return }
        let dest = store.saveDirectory
        working = "正在下载 \(picked.count) 项…"
        defer { working = nil }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for e in picked {
                try await Task.detached { try adb.pull(serial: serial, remotePath: e.path, localDirectory: dest.path) }.value
            }
            show("已下载 \(picked.count) 项到 \(dest.path)", error: false)
            let urls = picked.map { dest.appendingPathComponent($0.name) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        guard panel.runModal() == .OK else { return }
        Task { await upload(urls: panel.urls) }
    }

    private func upload(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for p in providers {
            if let url = await loadURL(p) { urls.append(url) }
        }
        await upload(urls: urls)
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    private func upload(urls: [URL]) async {
        guard let adb = store.adb, !urls.isEmpty else { return }
        let dir = path
        working = "正在上传 \(urls.count) 项到 \(dir)…"
        defer { working = nil }
        do {
            try await Task.detached { try adb.push(serial: serial, localPaths: urls.map(\.path), remoteDirectory: dir) }.value
            show("已上传 \(urls.count) 项", error: false)
            await load()
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}
