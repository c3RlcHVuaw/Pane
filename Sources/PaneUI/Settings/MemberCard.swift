import PaneModel
import SwiftUI

/// A collectible "member card": which Pane user you are. Tilts toward the pointer and shimmers like a hologram on hover.
struct MemberCard: View {
    let name: String
    let number: Int?
    let since: Date?

    @State private var pointer: CGPoint? = {
        // Debug aid: PANE_DEBUG_CARD="0.8,0.25" renders the card as if the pointer were there.
        guard let v = ProcessInfo.processInfo.environment["PANE_DEBUG_CARD"] else { return nil }
        let p = v.split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? CGPoint(x: p[0], y: p[1]) : nil
    }()
    private let size = CGSize(width: 250, height: 330)

    private static let adjectives = ["Vibrant", "Quiet", "Swift", "Lucid", "Bold", "Gentle", "Bright", "Curious"]
    private static let nouns = ["Pilot", "Voyager", "Wanderer", "Pioneer", "Navigator", "Explorer", "Drifter", "Seeker"]

    private var title: String {
        let n = max(number ?? 0, 0)
        return (tr(Self.adjectives[n % Self.adjectives.count]) + " " + tr(Self.nouns[(n / 3) % Self.nouns.count])).uppercased()
    }
    private var hue: Double { Double(((number ?? 7) * 47) % 360) / 360 }
    private let ink = Color(red: 0.36, green: 0.36, blue: 0.55)

    var body: some View {
        let hovering = pointer != nil
        let px = pointer?.x ?? 0.5, py = pointer?.y ?? 0.5
        card(px: px, py: py, hovering: hovering)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .rotation3DEffect(.degrees((py - 0.5) * -16), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees((px - 0.5) * 18), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .scaleEffect(hovering ? 1.04 : 1)
            .shadow(color: .black.opacity(hovering ? 0.35 : 0.2), radius: hovering ? 22 : 10, x: (0.5 - px) * 14, y: hovering ? 14 : 5)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.8)) {
                        pointer = CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
                    }
                case .ended:
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { pointer = nil }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(number.map { String(localized: "Pane member number \($0)") } ?? tr("Pane member card"))
    }

    private func card(px: Double, py: Double, hovering: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Color(red: 1.0, green: 0.995, blue: 0.9)
            VStack(alignment: .leading, spacing: 0) {
                art(px: px, py: py)
                    .frame(height: 188)
                    .padding(.horizontal, 16).padding(.top, 16)
                Text(verbatim: name)
                    .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 16).padding(.top, 12)
                Text(verbatim: title)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(ink.opacity(0.85))
                    .padding(.horizontal, 16).padding(.top, 1)
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    seal
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "PANE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(ink)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(ink, lineWidth: 1))
                        if let since {
                            Text(since.formatted(.dateTime.day().month(.abbreviated).year().locale(AppLanguage.currentLocale)))
                                .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(ink.opacity(0.8))
                        }
                    }
                    Spacer()
                    Text("BROWSER\nFOR YOU").multilineTextAlignment(.trailing)
                        .font(.system(size: 8.5, design: .serif)).foregroundStyle(ink.opacity(0.75))
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
            hologram(px: px, py: py, hovering: hovering)
        }
    }

    private func art(px: Double, py: Double) -> some View {
        let h = hue
        let a = Color(hue: h, saturation: 0.55, brightness: 0.55), b = Color(hue: (h + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.85)
        let c = Color(hue: (h + 0.55).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.75), d = Color(hue: (h + 0.9).truncatingRemainder(dividingBy: 1), saturation: 0.3, brightness: 0.95)
        return UnevenRoundedRectangle(topLeadingRadius: 100, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 100, style: .continuous)
            .fill(LinearGradient(colors: [a, b, c, d], startPoint: UnitPoint(x: 0.1 + px * 0.3, y: 0), endPoint: UnitPoint(x: 0.9 - px * 0.3, y: 1)))
            .overlay(
                RadialGradient(colors: [.white.opacity(0.55), .clear], center: UnitPoint(x: 0.3 + px * 0.4, y: 0.35 + py * 0.3), startRadius: 0, endRadius: 120)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 100, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 100, style: .continuous))
            )
    }

    private var seal: some View {
        ZStack {
            Circle().strokeBorder(Color.blue.opacity(0.8), lineWidth: 1.6)
            Circle().strokeBorder(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2.5])).padding(4)
            VStack(spacing: -2) {
                Text(verbatim: "№").font(.system(size: 8, weight: .semibold, design: .serif))
                Text(verbatim: number.map(String.init) ?? "·")
                    .font(.system(size: (number ?? 0) >= 100 ? 15 : 19, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
            }
            .foregroundStyle(Color.blue.opacity(0.85))
        }
        .frame(width: 50, height: 50)
        .background(Circle().fill(Color.blue.opacity(0.06)))
    }

    /// The moving rainbow sheen and the soft glare under the pointer.
    private func hologram(px: Double, py: Double, hovering: Bool) -> some View {
        ZStack {
            LinearGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red],
                           startPoint: UnitPoint(x: px - 0.7, y: py - 0.7), endPoint: UnitPoint(x: px + 0.7, y: py + 0.7))
                .blendMode(.colorBurn).opacity(hovering ? 0.16 : 0)
            LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: UnitPoint(x: px - 0.35, y: py - 0.35), endPoint: UnitPoint(x: px + 0.35, y: py + 0.35))
                .blendMode(.softLight).opacity(hovering ? 0.6 : 0)
            RadialGradient(colors: [.white.opacity(0.55), .clear], center: UnitPoint(x: px, y: py), startRadius: 0, endRadius: 140)
                .blendMode(.overlay).opacity(hovering ? 1 : 0)
        }
        .allowsHitTesting(false)
    }
}
