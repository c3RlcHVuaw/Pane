import PaneModel
import SwiftUI

/// What the app can do with profile windows; supplied by the app, which owns the windows.
public struct AppActions {
    public var openProfile: (ProfileInfo) -> Void
    public var deleteProfile: (ProfileInfo) -> Void
    public var openPrivateWindow: () -> Void
    public var isOpen: (ProfileInfo) -> Bool
    public init(openProfile: @escaping (ProfileInfo) -> Void, deleteProfile: @escaping (ProfileInfo) -> Void,
                openPrivateWindow: @escaping () -> Void, isOpen: @escaping (ProfileInfo) -> Bool) {
        self.openProfile = openProfile; self.deleteProfile = deleteProfile; self.openPrivateWindow = openPrivateWindow; self.isOpen = isOpen
    }
}

struct ProfilesPane: View {
    @ObservedObject var profiles: ProfilesStore
    let app: AppActions
    @State private var newName = ""
    @State private var newColor = 1
    @State private var renaming: ProfileInfo?
    @State private var renameText = ""
    @State private var deleting: ProfileInfo?
    @State private var error: String?

    private func color(_ i: Int) -> Color { Color(nsColor: GroupPalette.color(i)) }

    var body: some View {
        Form {
            Section {
                row(name: "Default", detail: "Your main profile", color: .gray, initial: "D", profile: nil)
                ForEach(profiles.profiles) { p in
                    row(name: p.name, detail: app.isOpen(p) ? "Open in a window" : "Own tabs, bookmarks, history and logins",
                        color: color(p.colorIndex), initial: String(p.name.prefix(1)).uppercased(), profile: p)
                }
            } header: { Text("Profiles") } footer: {
                Text("Each profile is fully separate: you can be signed in to two accounts on the same site at once. Open one from File → New Window in Profile.")
            }

            Section("Add a profile") {
                TextField("Name", text: $newName, prompt: Text("Work, School, …")).accessibilityLabel("New profile name")
                HStack(spacing: 8) {
                    ForEach(0..<GroupPalette.colors.count, id: \.self) { i in
                        Button { newColor = i } label: {
                            Circle().fill(color(i)).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white, lineWidth: newColor == i ? 2.5 : 0))
                                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain).accessibilityLabel(GroupPalette.colors[i].name)
                    }
                    Spacer()
                    Button("Add") { add() }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.callout) }
            }

            Section {
                Button { app.openPrivateWindow() } label: { Label("New Private Window", systemImage: "lock.shield.fill") }
            } header: { Text("Private browsing") } footer: {
                Text("A private window keeps no history, cookies or open tabs once you close it.")
            }
        }
        .formStyle(.grouped)
        .alert("Rename profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let r = renaming, !profiles.rename(r.id, to: renameText) { error = "That name is empty, too long or already used." }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete this profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Profile", role: .destructive) { if let d = deleting { app.deleteProfile(d) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Its tabs, bookmarks, history and logins are removed from this Mac. This can't be undone.") }
    }

    private func add() {
        error = nil
        if profiles.add(name: newName, colorIndex: newColor) != nil { newName = "" }
        else { error = "That name is empty, too long or already used." }
    }

    @ViewBuilder private func row(name: String, detail: String, color: Color, initial: String, profile: ProfileInfo?) -> some View {
        HStack(spacing: 12) {
            Text(initial).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(color.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) { Text(tr(name)); Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let p = profile {
                Button("Open") { app.openProfile(p) }
                Menu {
                    Button("Rename…") { renameText = p.name; renaming = p }
                    Menu("Color") {
                        ForEach(0..<GroupPalette.colors.count, id: \.self) { i in
                            Button(GroupPalette.colors[i].name) { profiles.setColor(p.id, colorIndex: i) }
                        }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = p }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More for \(p.name)")
            } else {
                Button("Open") { NSApp.activate() }.disabled(true).opacity(0)
            }
        }
    }
}
