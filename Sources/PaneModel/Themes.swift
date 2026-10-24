import Foundation

/// A colour mood for Pane's chrome: the sidebar and window glass, the start page and the accent colour.
public enum ThemeChoice: String, CaseIterable, Identifiable, Sendable {
    case system, ocean, sunset, forest, rose, violet, graphite
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: tr("Default look"); case .ocean: tr("Ocean"); case .sunset: tr("Sunset"); case .forest: tr("Forest")
        case .rose: tr("Rose"); case .violet: tr("Violet"); case .graphite: tr("Graphite")
        }
    }

    /// The theme's colour as red, green, blue (0...1); nil for the system look.
    public var rgb: (r: Double, g: Double, b: Double)? {
        switch self {
        case .system: nil
        case .ocean: (0.12, 0.55, 0.95)
        case .sunset: (0.98, 0.45, 0.25)
        case .forest: (0.18, 0.66, 0.40)
        case .rose: (0.95, 0.35, 0.58)
        case .violet: (0.58, 0.40, 0.95)
        case .graphite: (0.50, 0.53, 0.58)
        }
    }
}
