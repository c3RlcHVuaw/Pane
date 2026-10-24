import PaneModel
import SwiftUI

/// "What's new" card shown once after an update.
struct WhatsNewView: View {
    let title: String
    let lines: [String]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(LinearGradient(colors: [.purple, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pane updated").font(.headline)
                    Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("What's new").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(y: -2)
                        Text(verbatim: l).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack { Spacer(); Button("Got it", action: onClose).keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 340)
    }
}
