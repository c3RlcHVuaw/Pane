import AppKit
import SwiftUI
import PaneModel

struct ExtensionsPane: View {
    @ObservedObject var store: ExtensionStore = .shared
    @State private var link = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Form {
            if store.needsRestart {
                Section {
                    HStack {
                        Label("Restart Pane to apply the changes.", systemImage: "arrow.clockwise.circle.fill").foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("Restart Now") { Relauncher.relaunch() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            Section {
                if store.items.isEmpty {
                    Text("No extensions yet.").foregroundStyle(.secondary)
                }
                ForEach(store.items) { e in
                    HStack(spacing: 12) {
                        ExtensionIcon(path: e.iconPath)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: e.name).fontWeight(.medium)
                            Text(verbatim: e.detail.isEmpty ? "v\(e.version)" : "v\(e.version) · \(e.detail)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { e.enabled }, set: { store.setEnabled(e.id, $0) })).labelsHidden().toggleStyle(.switch)
                        Button { store.remove(e.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help(tr("Remove"))
                    }
                }
            } header: { Text("Installed") }
            Section {
                HStack {
                    TextField("Chrome Web Store link or extension ID", text: $link).textFieldStyle(.roundedBorder).onSubmit(install)
                    Button("Install") { install() }.disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                    if busy { ProgressView().controlSize(.small) }
                }
                Button("Add Unpacked Folder…") { pickFolder() }
                if let message { Text(message).font(.callout).foregroundStyle(failed ? Color.orange : Color.green) }
            } header: { Text("Add") } footer: {
                Text("Extensions that work on web pages (content blockers, dark mode, page tweaks) run. Toolbar buttons and pop-ups are not supported yet.")
            }
        }
        .formStyle(.grouped)
    }

    private func install() {
        let text = link
        guard !busy else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await store.installFromWebStore(text); link = ""; failed = false; message = tr("Installed. Restart Pane to use it.") }
            catch { failed = true; message = error.localizedDescription }
        }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = tr("Add")
        p.message = tr("Choose the folder that contains manifest.json")
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try store.add(folder: url); failed = false; message = tr("Added. Restart Pane to use it.") }
        catch { failed = true; message = error.localizedDescription }
    }
}

private struct ExtensionIcon: View {
    let path: String?
    var body: some View {
        Group {
            if let path, let img = NSImage(contentsOfFile: path) { Image(nsImage: img).resizable() }
            else { Image(systemName: "puzzlepiece.extension.fill").resizable().scaledToFit().padding(6).foregroundStyle(.white).background(Color.mint.gradient) }
        }
        .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
