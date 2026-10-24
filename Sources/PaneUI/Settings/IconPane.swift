import AppKit
import CoreImage
import SwiftUI
import PaneModel

/// Alternative Dock icons, derived from the original artwork with colour filters.
@MainActor
public enum AppIconStyle {
    public struct Variant: Identifiable, Sendable {
        public let id: String, title: String
        let hue: Double, saturation: Double, brightness: Double, contrast: Double
    }

    public static let variants: [Variant] = [
        .init(id: "original", title: "The Original", hue: 0, saturation: 1, brightness: 0, contrast: 1),
        .init(id: "sunset", title: "Sunset", hue: -2.4, saturation: 1.1, brightness: 0.02, contrast: 1),
        .init(id: "ocean", title: "Ocean", hue: 1.6, saturation: 1.05, brightness: 0, contrast: 1),
        .init(id: "mint", title: "Mint", hue: 3.4, saturation: 1.0, brightness: 0.03, contrast: 1),
        .init(id: "candy", title: "Candy", hue: -0.9, saturation: 0.7, brightness: 0.12, contrast: 0.9),
        .init(id: "graphite", title: "Graphite", hue: 0, saturation: 0, brightness: 0, contrast: 1.1),
        .init(id: "neon", title: "Neon", hue: 0.9, saturation: 1.6, brightness: -0.08, contrast: 1.35),
    ]

    private static let base: NSImage = NSApp.applicationIconImage.copy() as? NSImage ?? NSImage()
    private static var cache: [String: NSImage] = [:]
    private static let ctx = CIContext()

    public static func image(for v: Variant) -> NSImage {
        if v.id == "original" { return base }
        if let c = cache[v.id] { return c }
        guard let tiff = base.tiffRepresentation, let ci = CIImage(data: tiff) else { return base }
        var img = ci
        if let f = CIFilter(name: "CIHueAdjust") { f.setValue(img, forKey: kCIInputImageKey); f.setValue(v.hue, forKey: kCIInputAngleKey); img = f.outputImage ?? img }
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(v.saturation, forKey: kCIInputSaturationKey); f.setValue(v.brightness, forKey: kCIInputBrightnessKey); f.setValue(v.contrast, forKey: kCIInputContrastKey)
            img = f.outputImage ?? img
        }
        guard let cg = ctx.createCGImage(img, from: ci.extent) else { return base }
        let out = NSImage(cgImage: cg, size: base.size)
        cache[v.id] = out
        return out
    }

    public static func apply(_ id: String) {
        guard let v = variants.first(where: { $0.id == id }) else { return }
        NSApp.applicationIconImage = image(for: v)
    }
}

struct IconPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(AppIconStyle.variants) { v in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { settings.appIcon = v.id }
                        AppIconStyle.apply(v.id)
                    } label: {
                        HStack(spacing: 14) {
                            Image(nsImage: AppIconStyle.image(for: v)).resizable().frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: tr(v.title)).fontWeight(.semibold)
                                if settings.appIcon == v.id { Text("CURRENT ICON").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor) }
                            }
                            Spacer()
                            Image(systemName: settings.appIcon == v.id ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 18)).foregroundStyle(settings.appIcon == v.id ? Color.accentColor : Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.appIcon == v.id ? .isSelected : [])
                }
            } footer: {
                Text("The icon changes in the Dock while Pane is running.")
            }
        }
        .formStyle(.grouped)
    }
}
