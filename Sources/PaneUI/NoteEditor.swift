import PaneModel
import SwiftUI

/// The little card for a page's note: type, and it saves itself.
struct NoteEditorView: View {
    let host: String
    @State var text: String
    let onChange: (String) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "note.text").foregroundStyle(.yellow)
                Text("Note for this page").font(.headline)
                Spacer()
                Text(verbatim: host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            TextEditor(text: $text)
                .font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(8).frame(width: 300, height: 130)
                .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.yellow.opacity(0.14)) }
                .focused($focused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty { Text("Write anything — you'll see it next time you open this page, and ⌘K finds it.").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.top, 16).padding(.leading, 13).allowsHitTesting(false) }
                }
                .onChange(of: text) { _, new in onChange(new) }
            HStack {
                Button("Delete Note", role: .destructive) { text = ""; onChange(""); onClose() }.disabled(text.isEmpty)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }
}
