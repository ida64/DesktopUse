import AppKit
import QuartzCore

let claudeOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

/// Thread-safe facade over the on-screen overlay; callable from the server thread.
enum Overlay {
    static let enabled = ProcessInfo.processInfo.environment["DESKTOPUSE_OVERLAY"] != "0"
    /// Where the orange cursor currently is (global points), or nil before the first action.
    static var position: CGPoint?

    static func show(at p: CGPoint) {
        position = p
        guard enabled else { return }
        onMain { CursorOverlay.shared.place(at: p) }
    }

    static func ripple() {
        guard enabled else { return }
        onMain { CursorOverlay.shared.ripple() }
    }

    static func flash(_ rect: CGRect, label: String) {
        guard enabled else { return }
        // Synchronous, so the border exists (and is excluded) before the screenshot that follows.
        onMainSync { CursorOverlay.shared.flashScope(rect, label: label) }
    }

    private static func onMain(_ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
    }
}

@MainActor
final class CursorOverlay {
    static let shared = CursorOverlay()

    /// Location of the arrow tip inside the cursor panel (top-left origin).
    static let tip = CGPoint(x: 30, y: 30)
    static let size = CGSize(width: 150, height: 90)

    private var panel: NSPanel?
    private let view = CursorView(frame: NSRect(origin: .zero, size: CursorOverlay.size))
    private var scopePanel: NSPanel?
    private var scopeView: ScopeBorderView?
    private var scopeGeneration = 0

    func setup() {
        let p = Self.makePanel(NSRect(origin: .zero, size: Self.size))
        p.contentView = view
        panel = p
    }

    static func makePanel(_ frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        return p
    }

    /// Converts a global top-left-origin rect to Cocoa's bottom-left-origin screen space.
    static func cocoaRect(_ r: CGRect) -> NSRect {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    func place(at p: CGPoint) {
        guard let panel else { return }
        let r = CGRect(x: p.x - Self.tip.x, y: p.y - Self.tip.y, width: Self.size.width, height: Self.size.height)
        panel.setFrame(Self.cocoaRect(r), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func ripple() {
        view.startRipple()
    }

    func flashScope(_ rect: CGRect, label: String) {
        let frame = Self.cocoaRect(rect.insetBy(dx: -4, dy: -4))
        if scopePanel == nil {
            let p = Self.makePanel(frame)
            let v = ScopeBorderView(frame: NSRect(origin: .zero, size: frame.size))
            v.autoresizingMask = [.width, .height]
            p.contentView = v
            scopePanel = p
            scopeView = v
        }
        guard let scopePanel, let scopeView else { return }
        scopeView.label = label
        scopePanel.setFrame(frame, display: true)
        scopePanel.alphaValue = 1
        scopePanel.orderFrontRegardless()
        scopeView.needsDisplay = true

        scopeGeneration += 1
        let generation = scopeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            MainActor.assumeIsolated {
                guard generation == self.scopeGeneration else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.5
                    scopePanel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        if generation == self.scopeGeneration { scopePanel.orderOut(nil) }
                    }
                })
            }
        }
    }
}

final class CursorView: NSView {
    override var isFlipped: Bool { true }
    private var rippleStart: CFTimeInterval?
    private var timer: Timer?
    private static let rippleDuration: CFTimeInterval = 0.45

    func startRipple() {
        rippleStart = CACurrentMediaTime()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                self.needsDisplay = true
                if CACurrentMediaTime() - (self.rippleStart ?? 0) > Self.rippleDuration {
                    self.rippleStart = nil
                    t.invalidate()
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let tip = CursorOverlay.tip

        if let start = rippleStart {
            let p = min(1, (CACurrentMediaTime() - start) / Self.rippleDuration)
            let r = 5 + 21 * p
            let ring = NSBezierPath(ovalIn: NSRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2))
            claudeOrange.withAlphaComponent(0.22 * (1 - p)).setFill()
            ring.fill()
            claudeOrange.withAlphaComponent(0.9 * (1 - p)).setStroke()
            ring.lineWidth = 2.5
            ring.stroke()
        }

        // Classic pointer arrow, tip at `tip`.
        let shape: [CGPoint] = [(0, 0), (0, 23), (5.5, 17.5), (9.5, 26.5), (13, 25), (9, 16.5), (16.5, 16.5)]
            .map { CGPoint(x: tip.x + $0.0, y: tip.y + $0.1) }
        let arrow = NSBezierPath()
        arrow.move(to: shape[0])
        shape.dropFirst().forEach { arrow.line(to: $0) }
        arrow.close()
        arrow.lineJoinStyle = .round

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()
        claudeOrange.setFill()
        arrow.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.5
        arrow.stroke()

        // Name tag.
        let text = NSAttributedString(string: "Claude", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let pill = NSRect(x: tip.x + 15, y: tip.y + 24, width: size.width + 14, height: size.height + 5)
        let pillPath = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        claudeOrange.setFill()
        pillPath.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()
        text.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 2.5))
    }
}

final class ScopeBorderView: NSView {
    override var isFlipped: Bool { true }
    var label = ""

    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        border.lineWidth = 4
        claudeOrange.setStroke()
        border.stroke()

        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let tag = NSRect(x: 14, y: 0, width: min(size.width + 16, bounds.width - 28), height: size.height + 6)
        claudeOrange.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 5, yRadius: 5).fill()
        text.draw(in: tag.insetBy(dx: 8, dy: 3))
    }
}
