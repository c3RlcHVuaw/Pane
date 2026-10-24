import AppKit
import PaneModel
import QuartzCore

/// Drawn over the page while the agent works: a travelling glow around the page, a cursor that glides to what
/// it is about to touch, a highlight on that element, and a ripple on every click. It never takes mouse input.
@MainActor
final class AgentOverlayView: NSView {
    private let ring = CALayer()            // masked to a thin rounded border; the gradient inside rotates
    private let ringGlow = CALayer()        // the same, wider and fainter, for a soft halo
    private let highlight = CAShapeLayer()
    private let cursor = CALayer()
    private let cursorSize: CGFloat = 24
    private var active = false
    private var cursorShown = false
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static let colors: [CGColor] = [NSColor.systemPurple, .systemBlue, .systemTeal, .systemPink, .systemPurple].map { $0.cgColor }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [ringGlow, ring] { l.opacity = 0; layer?.addSublayer(l) }
        highlight.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        highlight.strokeColor = NSColor.controlAccentColor.cgColor
        highlight.lineWidth = 2
        highlight.opacity = 0
        layer?.addSublayer(highlight)
        cursor.bounds = CGRect(x: 0, y: 0, width: cursorSize, height: cursorSize)
        cursor.anchorPoint = CGPoint(x: 0.15, y: 0.1)  // the arrow's tip
        cursor.opacity = 0
        cursor.contents = Self.cursorImage(size: cursorSize)
        cursor.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        cursor.shadowColor = NSColor.controlAccentColor.cgColor
        cursor.shadowOpacity = 0.9
        cursor.shadowRadius = 7
        cursor.shadowOffset = .zero
        layer?.addSublayer(cursor)
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        buildRing(ring, width: 3, blur: false)
        buildRing(ringGlow, width: 12, blur: true)
    }

    private func buildRing(_ host: CALayer, width: CGFloat, blur: Bool) {
        host.frame = bounds
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard bounds.width > 20, bounds.height > 20 else { return }
        let side = max(bounds.width, bounds.height) * 1.6
        let g = CAGradientLayer()
        g.type = .conic
        g.colors = Self.colors
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 0.5, y: 0)
        g.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        g.position = CGPoint(x: bounds.midX, y: bounds.midY)
        host.addSublayer(g)
        let mask = CAShapeLayer()
        let path = CGPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), cornerWidth: 12, cornerHeight: 12, transform: nil)
        mask.path = path
        mask.fillColor = nil
        mask.strokeColor = NSColor.white.cgColor
        mask.lineWidth = width
        mask.frame = bounds
        host.mask = mask
        if blur { host.compositingFilter = nil }
        if active { spin(g) }
    }

    private func spin(_ g: CALayer) {
        g.removeAnimation(forKey: "spin")
        guard !reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0; a.toValue = Double.pi * 2
        a.duration = 3.2; a.repeatCount = .infinity
        g.add(a, forKey: "spin")
    }

    // MARK: Agent on / off

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        for l in [ring, ringGlow] {
            if on { l.sublayers?.forEach { spin($0) } }
            let target: Float = on ? (l === ring ? 1 : 0.28) : 0
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = l.presentation()?.opacity ?? l.opacity
            a.toValue = target; a.duration = on ? 0.5 : 0.7
            l.opacity = target
            l.add(a, forKey: "fade")
        }
        if !on {
            hideCursor()
            setHighlight(nil)
        }
    }

    // MARK: Cursor, highlight, ripple

    /// Glides the cursor to `point` (in this view's top-left coordinates) and outlines `rect`, then returns.
    func move(to point: CGPoint, target rect: CGRect?) async {
        let p = CGPoint(x: min(max(point.x, 4), bounds.width - 4), y: min(max(point.y, 4), bounds.height - 4))
        let from = cursorShown ? (cursor.presentation()?.position ?? cursor.position) : CGPoint(x: bounds.midX, y: bounds.maxY - 8)
        cursorShown = true
        setHighlight(rect)
        let distance = hypot(p.x - from.x, p.y - from.y)
        let duration = reduceMotion ? 0.01 : min(0.7, 0.22 + distance / 1600)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            CATransaction.begin()
            CATransaction.setCompletionBlock { c.resume() }
            cursor.position = from
            cursor.opacity = 1
            let a = CASpringAnimation(keyPath: "position")
            a.fromValue = NSValue(point: from); a.toValue = NSValue(point: p)
            a.mass = 0.9; a.stiffness = 140; a.damping = 17; a.initialVelocity = 0
            a.duration = min(a.settlingDuration, duration + 0.25)
            cursor.position = p
            cursor.add(a, forKey: "glide")
            CATransaction.commit()
        }
    }

    func ripple() {
        guard cursorShown, !reduceMotion else { return }
        let at = cursor.presentation()?.position ?? cursor.position
        let r = CAShapeLayer()
        r.path = CGPath(ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8), transform: nil)
        r.position = at
        r.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        r.strokeColor = NSColor.controlAccentColor.cgColor
        r.lineWidth = 2
        layer?.addSublayer(r)
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 1; scale.toValue = 6
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [scale, fade]; group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { r.removeFromSuperlayer() }
        r.add(group, forKey: "ripple")
        r.opacity = 0
        CATransaction.commit()
        // A little press: the cursor dips and returns.
        let press = CAKeyframeAnimation(keyPath: "transform.scale")
        press.values = [1, 0.82, 1]; press.keyTimes = [0, 0.4, 1]; press.duration = 0.25
        cursor.add(press, forKey: "press")
    }

    func setHighlight(_ rect: CGRect?) {
        guard let rect, rect.width > 1, rect.height > 1 else {
            let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = highlight.presentation()?.opacity ?? highlight.opacity; a.toValue = 0; a.duration = 0.25
            highlight.opacity = 0; highlight.add(a, forKey: "fade")
            return
        }
        let r = rect.insetBy(dx: -4, dy: -4)
        let path = CGPath(roundedRect: r, cornerWidth: min(10, r.height / 2), cornerHeight: min(10, r.height / 2), transform: nil)
        let old = highlight.path
        highlight.path = path
        if let old, highlight.opacity > 0, !reduceMotion {
            let a = CABasicAnimation(keyPath: "path"); a.fromValue = old; a.toValue = path; a.duration = 0.3
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            highlight.add(a, forKey: "morph")
        }
        highlight.opacity = 1
        let fadeIn = CABasicAnimation(keyPath: "opacity"); fadeIn.fromValue = 0; fadeIn.toValue = 1; fadeIn.duration = 0.2
        highlight.add(fadeIn, forKey: "fadeIn")
    }

    func hideCursor() {
        cursorShown = false
        let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = cursor.presentation()?.opacity ?? 1; a.toValue = 0; a.duration = 0.35
        cursor.opacity = 0; cursor.add(a, forKey: "fade")
    }

    /// A white pointer with a thin dark edge so it reads on any page.
    private static func cursorImage(size: CGFloat) -> CGImage? {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 3, y: 2)); p.line(to: NSPoint(x: 3, y: 18)); p.line(to: NSPoint(x: 7.5, y: 14))
            p.line(to: NSPoint(x: 10.5, y: 21)); p.line(to: NSPoint(x: 13.5, y: 19.7)); p.line(to: NSPoint(x: 10.6, y: 13))
            p.line(to: NSPoint(x: 16.5, y: 13)); p.close()
            NSColor.white.setFill(); p.fill()
            NSColor.black.withAlphaComponent(0.75).setStroke(); p.lineWidth = 1.2; p.lineJoinStyle = .round; p.stroke()
            return true
        }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// "Agent is working" with a Stop button, centred at the bottom of the page.
@MainActor
final class AgentStatusPill: NSView {
    var onStop: (() -> Void)?
    private let label = NSTextField(labelWithString: tr("Agent is working"))
    private let spark = NSImageView()
    private let card: NSView
    private var bottom: NSLayoutConstraint!

    init() {
        let content = NSView()
        card = Glass.surface(content: content, cornerRadius: 19)
        super.init(frame: .zero)
        spark.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        spark.contentTintColor = .systemPurple
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let stop = PillButton(title: tr("Stop"), symbol: "stop.fill", target: self, action: #selector(stopClicked))
        stop.toolTip = tr("Stop the agent  ⌘.")
        stop.setAccessibilityLabel(tr("Stop the agent"))
        let row = NSStackView(views: [spark, label, stop])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stop.heightAnchor.constraint(equalToConstant: 26), stop.widthAnchor.constraint(equalToConstant: 76),
            spark.widthAnchor.constraint(equalToConstant: 16),
        ])
        addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.heightAnchor.constraint(equalToConstant: 38),
        ])
        bottom = card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        bottom.isActive = true
        alphaValue = 0
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("The agent is working"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func attach(to parent: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor), trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -14), heightAnchor.constraint(equalToConstant: 46),
        ])
    }
    func bringToFront() { superview?.addSubview(self, positioned: .above, relativeTo: nil) }

    func setStatus(_ text: String) { label.stringValue = text }

    func show(_ on: Bool) {
        if on { isHidden = false; bottom.constant = 8; layoutSubtreeIfNeeded(); bottom.constant = -4 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = on ? 1 : 0
            bottom.animator().constant = on ? -4 : 8
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { if !on { self?.isHidden = true } } })
        if on {
            let pulse = CABasicAnimation(keyPath: "opacity"); pulse.fromValue = 1; pulse.toValue = 0.4
            pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
            spark.wantsLayer = true
            spark.layer?.add(pulse, forKey: "pulse")
        } else {
            spark.layer?.removeAnimation(forKey: "pulse")
        }
    }

    @objc private func stopClicked() { onStop?() }
}
