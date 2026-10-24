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

/// A small card at the foot of the sidebar after an update: what happened, and two things to do next.
struct UpdateCompleteView: View {
    let title: String
    let onSeeWhatsNew: () -> Void
    let onShare: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text("Update Complete!").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            row("heart.fill", "See What's New", tint: .pink, action: onSeeWhatsNew)
            row("gift", "Share Pane with a Friend", tint: .accentColor, action: onShare)
            Text(verbatim: title).font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 4)
        }
        .padding(12)
        .frame(width: 230)
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
