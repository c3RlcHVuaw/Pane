import PaneModel
import SwiftUI

/// What the padlock in the address bar opens.
struct SiteInfoView: View {
    let host: String
    let secure: Bool
    @State var permissions: [(kind: String, allowed: Bool)]
    let onReset: (String) -> Void
    let onClearCookies: () -> Void
    let onNote: () -> Void

    private func name(_ kind: String) -> String {
        switch kind {
        case "camera": tr("Camera"); case "microphone": tr("Microphone"); case "location": tr("Location"); case "clipboard": tr("Clipboard")
        default: kind
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: secure ? "lock.fill" : "lock.open.fill").foregroundStyle(secure ? .green : .orange).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: host).font(.headline)
                    Text(secure ? "The connection is encrypted." : "The connection is not encrypted — don't type passwords here.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !permissions.isEmpty {
                Divider()
                Text("Permissions you gave this site").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                ForEach(permissions, id: \.kind) { p in
                    HStack {
                        Image(systemName: p.allowed ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(p.allowed ? .green : .secondary)
                        Text(verbatim: name(p.kind))
                        Spacer()
                        Button("Reset") { onReset(p.kind); permissions.removeAll { $0.kind == p.kind } }.buttonStyle(.link)
                    }
                }
            }
            Divider()
            Button { onNote() } label: { Label("Note for this page…", systemImage: "note.text") }.buttonStyle(.plain)
            Button(role: .destructive) { onClearCookies() } label: { Label("Delete This Site's Cookies", systemImage: "trash") }.buttonStyle(.plain)
        }
        .padding(16).frame(width: 300)
    }
}
