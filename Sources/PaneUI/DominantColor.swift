import AppKit

enum DominantColor {
    /// The most colourful hue in a small image (a favicon), or nil for black/white/grey icons.
    static func of(_ image: NSImage) -> NSColor? {
        let n = 12
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for y in 0..<n { for x in 0..<n {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
            let w = Double(c.saturationComponent) * Double(c.saturationComponent) * (c.brightnessComponent > 0.2 ? 1 : 0.1)
            r += Double(c.redComponent) * w; g += Double(c.greenComponent) * w; b += Double(c.blueComponent) * w; total += w
        } }
        guard total > 0.25 else { return nil }
        let color = NSColor(deviceRed: r / total, green: g / total, blue: b / total, alpha: 1)
        return color.saturationComponent > 0.25 ? color : nil
    }
}
