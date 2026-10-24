import PaneModel
import SwiftUI

struct DownloadsPopoverView: View {
    @ObservedObject var store: DownloadsStore
    let onShow: (DownloadItem) -> Void
    let onOpen: (DownloadItem) -> Void
    let onCancel: (DownloadItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { withAnimation(.snappy) { store.clearFinished() } }
                    .buttonStyle(.link)
                    .disabled(store.items.allSatisfy { $0.state == .inProgress })
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("No downloads yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            DownloadRow(item: item, onShow: onShow, onOpen: onOpen, onCancel: onCancel, onRemove: { store.remove(item.id) })
                            if item.id != store.items.last?.id { Divider().padding(.leading, 60) }
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 360)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let onShow: (DownloadItem) -> Void
    let onOpen: (DownloadItem) -> Void
    let onCancel: (DownloadItem) -> Void
    let onRemove: () -> Void
    @State private var hover = false

    private var exists: Bool { FileManager.default.fileExists(atPath: item.path) }
    private var sizeText: String { item.total > 0 ? ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file) : "" }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: exists && item.state == .complete ? NSWorkspace.shared.icon(forFile: item.path)
                  : (NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()))
                .resizable().frame(width: 32, height: 32)
                .opacity(item.state == .canceled ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .inProgress:
                    if let f = item.fraction { ProgressView(value: f).progressViewStyle(.linear) } else { ProgressView().controlSize(.small) }
                    Text(progressText).font(.caption).foregroundStyle(.secondary)
                case .complete:
                    Text(exists ? sizeText : tr("File was moved or deleted")).font(.caption).foregroundStyle(.secondary)
                case .canceled:
                    Text("Canceled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            switch item.state {
            case .inProgress:
                Button { onCancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel download")
            case .complete where exists:
                Button { onShow(item) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
            default: EmptyView()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(hover ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if item.state == .complete && exists { onOpen(item) } }
        .contextMenu {
            if item.state == .complete && exists { Button("Open") { onOpen(item) }; Button("Show in Finder") { onShow(item) } }
            Button("Remove from List") { onRemove() }
        }
    }

    private var progressText: String {
        let got = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        return item.total > 0 ? "\(got) of \(sizeText)" : got
    }
}
