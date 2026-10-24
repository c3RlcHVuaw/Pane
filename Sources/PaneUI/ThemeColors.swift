import AppKit
import PaneModel
import SwiftUI

extension ThemeChoice {
    var nsColor: NSColor? { rgb.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } }
    var color: Color { rgb.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .accentColor }
}
