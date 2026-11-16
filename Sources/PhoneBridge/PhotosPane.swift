import AppKit
import SwiftUI

struct PhotosPane: View {
    @EnvironmentObject var store: DeviceStore
    let deviceName: String
    @State private var selection = Set<IOSPhotoLibrary.Item.ID>()
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        PhotosContent(library: store.photos, deviceName: deviceName, selection: $selection,
                      message: $message, isError: $isError, saveDirectory: store.saveDirectory)
    }
}

private struct PhotosContent: View {
    @ObservedObject var library: IOSPhotoLibrary
    let deviceName: String
    @Binding var selection: Set<IOSPhotoLibrary.Item.ID>
    @Binding var message: String?
    @Binding var isError: Bool
    let saveDirectory: URL

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(statusText).foregroundStyle(isError ? .red : .secondary).lineLimit(2)
                Spacer()
                if !selection.isEmpty { Button("取消选择") { selection = [] } }
                Button(library.importing ? "导入中…" : "导入到 Mac（\(selection.count)）") { importSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || library.importing)
            }
            .padding(12)
            Divider()
            content
        }
        .onAppear { library.open(name: deviceName) }
        .onChange(of: library.cameraNames) { _, names in
            if names.contains(deviceName), library.status == .idle || isFailed { library.open(name: deviceName) }
        }
        .onDisappear { library.close() }
    }

    private var isFailed: Bool { if case .failed = library.status { return true } else { return false } }

    private var statusText: String {
        if let message { return message }
        switch library.status {
        case .idle, .opening: return "正在读取照片…"
        case .locked: return "请解锁 iPhone，解锁后自动读取"
        case .ready: return "共 \(library.items.count) 项，按时间从新到旧。点选（⌘ 多选）后导入，保存到 \(saveDirectory.path)"
        case .failed(let m): return m
        }
    }

    @ViewBuilder private var content: some View {
        switch library.status {
        case .ready:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(library.items) { item in
                        cell(item)
                    }
                }
                .padding(12)
            }
        case .locked:
            placeholder("lock.iphone", "请解锁 iPhone")
        case .failed(let m):
            placeholder("exclamationmark.triangle", m)
        default:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func cell(_ item: IOSPhotoLibrary.Item) -> some View {
        let selected = selection.contains(item.id)
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let img = library.thumbnails[item.id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 120, height: 120)
            .clipped()
            if item.isVideo {
                Image(systemName: "video.fill").foregroundStyle(.white).shadow(radius: 2).padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(4)
            }
        }
        .help(item.name)
        .onAppear { library.requestThumbnail(item) }
        .onTapGesture {
            let multi = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            if multi {
                if selected { selection.remove(item.id) } else { selection.insert(item.id) }
            } else {
                selection = selected && selection.count == 1 ? [] : [item.id]
            }
        }
    }

    private func importSelected() {
        let items = library.items.filter { selection.contains($0.id) }
        message = nil
        library.download(items, to: saveDirectory) { result in
            switch result {
            case .success(let n):
                message = "已导入 \(n) 项到 \(saveDirectory.path)"
                isError = false
                selection = []
                NSWorkspace.shared.activateFileViewerSelecting(
                    items.map { saveDirectory.appendingPathComponent($0.name) })
            case .failure(let e):
                message = e.localizedDescription
                isError = true
            }
        }
    }
}
