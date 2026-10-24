// Renders the installer window background (1320x800 px = 660x400 pt @2x). Usage: swift dmg_background.swift out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bg.png"
let W = 1320, H = 800
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}

// Deep violet-to-navy base with two soft glows.
let base = CGGradient(colorsSpace: cs, colors: [c(0x1B1740), c(0x0E1230)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: CGFloat(W), y: 0), options: [])
func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ col: UInt32, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: [c(col, a), c(col, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
}
glow(260, 640, 640, 0x7A5CFF, 0.38)
glow(1080, 180, 620, 0x14B8E6, 0.30)

// A glass strip behind the two icons.
let strip = CGPath(roundedRect: CGRect(x: 150, y: 215, width: 1020, height: 330), cornerWidth: 64, cornerHeight: 64, transform: nil)
ctx.setFillColor(c(0xFFFFFF, 0.06)); ctx.addPath(strip); ctx.fillPath()
ctx.setStrokeColor(c(0xFFFFFF, 0.14)); ctx.setLineWidth(2); ctx.addPath(strip); ctx.strokePath()

// Arrow between the app icon (x=360) and the Applications folder (x=960); icon centres sit at y=380 from the top.
let cy = CGFloat(H) - 380
ctx.setStrokeColor(c(0xFFFFFF, 0.55)); ctx.setLineWidth(8); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.setLineDash(phase: 0, lengths: [2, 22])
ctx.move(to: CGPoint(x: 500, y: cy)); ctx.addLine(to: CGPoint(x: 740, y: cy)); ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])
ctx.setLineWidth(10)
ctx.move(to: CGPoint(x: 740, y: cy + 38)); ctx.addLine(to: CGPoint(x: 800, y: cy)); ctx.addLine(to: CGPoint(x: 740, y: cy - 38)); ctx.strokePath()

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                            .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: para]
    NSAttributedString(string: s, attributes: a).draw(in: CGRect(x: 0, y: y, width: CGFloat(W), height: size * 1.5))
}
text("Welcome to Pane", size: 52, weight: .semibold, alpha: 0.96, y: CGFloat(H) - 150)
text("Drag Pane into Applications to install", size: 30, weight: .regular, alpha: 0.62, y: CGFloat(H) - 205)

NSGraphicsContext.restoreGraphicsState()
// 1320x800 pixels shown as 660x400 points (144 dpi); otherwise Finder displays it at pixel size, cropped.
rep.size = NSSize(width: W / 2, height: H / 2)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
