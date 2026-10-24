import AppKit
import PaneModel
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    enum Section: Hashable { case history, downloads }
    @Published var section: Section = .history
    @Published var entries: [HistoryEntry] = []
    @Published var query = ""
    let downloads: DownloadsStore
    var onOpen: (String) -> Void = { _ in }
    var onDelete: (String) -> Void = { _ in }
    var onClearHistory: () -> Void = {}
    init(downloads: DownloadsStore) { self.downloads = downloads }
}

/// History and downloads in one searchable window (⌘Y).
struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var downloads: DownloadsStore
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.entries.sorted { $0.lastVisit > $1.lastVisit }
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
    }

    private var groups: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        var out: [(String, [HistoryEntry])] = []
        for e in filtered.prefix(600) {
            let title: String = cal.isDateInToday(e.lastVisit) ? tr("Today") : cal.isDateInYesterday(e.lastVisit) ? tr("Yesterday")
                : e.lastVisit.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.currentLocale))
            if out.last?.0 == title { out[out.count - 1].1.append(e) } else { out.append((title, [e])) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $model.section) {
                    Text("History").tag(LibraryModel.Section.history)
                    Text("Downloads").tag(LibraryModel.Section.downloads)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if model.section == .history {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search history", text: $model.query).textFieldStyle(.plain)
                        if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)) }
                    Button("Clear…", role: .destructive) { confirmClear = true }.disabled(model.entries.isEmpty)
                } else {
                    Spacer()
                    Button("Clear Finished") { downloads.clearFinished() }.disabled(downloads.items.allSatisfy { $0.state == .inProgress })
                }
            }
            .padding(14)
            Divider().opacity(0.5)
            if model.section == .history { historyList } else { downloadsList }
        }
        .frame(minWidth: 520, minHeight: 420)
        .confirmationDialog("Clear all browsing history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.onClearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
    }

    private var historyList: some View {
        Group {
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "No history yet" : "Nothing found").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.0) { day, entries in
                        Section(day) {
                            ForEach(entries, id: \.url) { e in
                                HStack(spacing: 10) {
                                    Text(e.lastVisit.formatted(date: .omitted, time: .shortened).description).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 52, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: e.title.isEmpty ? (URL(string: e.url)?.host ?? e.url) : e.title).lineLimit(1)
                                        Text(verbatim: URL(string: e.url)?.host ?? e.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { model.onOpen(e.url) }
                                .contextMenu {
                                    Button("Open in New Tab") { model.onOpen(e.url) }
                                    Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.url, forType: .string) }
                                    Divider()
                                    Button("Delete", role: .destructive) { model.onDelete(e.url) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var downloadsList: some View {
        Group {
            if downloads.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("No downloads yet").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(downloads.items.sorted { $0.date > $1.date }) { d in
                    let exists = FileManager.default.fileExists(atPath: d.path)
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: d.path)).resizable().frame(width: 28, height: 28).opacity(exists || d.state == .inProgress ? 1 : 0.4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: d.name).lineLimit(1)
                            Text(d.state == .inProgress ? (d.fraction.map { "\(Int($0 * 100))%" } ?? tr("Downloading…")) : (d.state == .canceled ? tr("Canceled") : (exists ? d.date.formatted(date: .abbreviated, time: .shortened) : tr("File was moved or deleted"))))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if d.state == .complete && exists {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.path)]) } label: { Image(systemName: "magnifyingglass.circle") }
                                .buttonStyle(.borderless).help("Show in Finder")
                        }
                        Button { downloads.remove(d.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Remove from List")
                    }
                    .onTapGesture(count: 2) { if exists { NSWorkspace.shared.open(URL(fileURLWithPath: d.path)) } }
                }
                .listStyle(.inset)
            }
        }
    }
}

@MainActor
final class LibraryWindowController: NSWindowController {
    let model: LibraryModel
    init(model: LibraryModel) {
        self.model = model
        let host = NSHostingController(rootView: LibraryView(model: model, downloads: model.downloads))
        let window = NSWindow(contentViewController: host)
        window.title = tr("History")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 600))
        window.setFrameAutosaveName("PaneLibraryWindow")
        super.init(window: window)
        window.center()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func show() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate() }
}
