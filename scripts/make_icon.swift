// Renders the Pane app icon (1024 px PNG). Usage: swift scripts/make_icon.swift out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}

// macOS icon grid: 824 pt squircle centred in 1024 with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: c(0x000000, 0.38))
ctx.setFillColor(c(0x3B2FD6)); ctx.addPath(shape); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [c(0x6C5CFF), c(0x8F46F2), c(0x16B8E8)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 140, y: 920), end: CGPoint(x: 900, y: 120), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, 0.38), c(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 800), startRadius: 0, endCenter: CGPoint(x: 330, y: 800), endRadius: 520, options: [])

// Four glass "panes" in a 2 x 2 grid.
let pane: CGFloat = 196, gap: CGFloat = 36, r: CGFloat = 52
let origin = CGPoint(x: 512 - pane - gap / 2, y: 512 - pane - gap / 2)
for row in 0..<2 {
    for col in 0..<2 {
        let rect = CGRect(x: origin.x + CGFloat(col) * (pane + gap), y: origin.y + CGFloat(row) * (pane + gap), width: pane, height: pane)
        let p = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        let lead = (row == 1 && col == 0)  // top-left pane is the brightest
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: c(0x1A0F6B, 0.35))
        ctx.setFillColor(c(0xFFFFFF, lead ? 0.5 : 0.26)); ctx.addPath(p); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, lead ? 0.85 : 0.5), c(0xFFFFFF, lead ? 0.22 : 0.08)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        ctx.restoreGState()
        ctx.setStrokeColor(c(0xFFFFFF, 0.6)); ctx.setLineWidth(3); ctx.addPath(p); ctx.strokePath()
    }
}
ctx.restoreGState()
ctx.setStrokeColor(c(0xFFFFFF, 0.2)); ctx.setLineWidth(3); ctx.addPath(shape); ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
