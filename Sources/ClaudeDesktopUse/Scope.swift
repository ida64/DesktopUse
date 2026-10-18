import AppKit
import CoreGraphics

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let bounds: CGRect
    let layer: Int
    let onScreen: Bool

    var label: String {
        title.isEmpty ? app : "\(app) — \(title.truncated(80))"
    }
}

enum WindowList {
    static func all(onScreenOnly: Bool = true) -> [WindowInfo] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap(parse)
    }

    static func find(_ id: CGWindowID) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return nil }
        return list.compactMap(parse).first { $0.id == id }
    }

    /// Normal, user-facing windows in front-to-back order, excluding our own overlay.
    static func appWindows() -> [WindowInfo] {
        all().filter { $0.layer == 0 && $0.pid != getpid() && $0.bounds.width >= 40 && $0.bounds.height >= 40 }
    }

    private static func parse(_ d: [String: Any]) -> WindowInfo? {
        guard let num = d[kCGWindowNumber as String] as? Int,
              let pid = d[kCGWindowOwnerPID as String] as? Int,
              let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        return WindowInfo(
            id: CGWindowID(num),
            pid: pid_t(pid),
            app: d[kCGWindowOwnerName as String] as? String ?? "?",
            title: d[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            layer: d[kCGWindowLayer as String] as? Int ?? 0,
            onScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false
        )
    }
}

enum Displays {
    static func all() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        // Main display first so index 0 is always the menu-bar display.
        return ids.sorted { a, _ in CGDisplayIsMain(a) != 0 }
    }

    static func backingScale(_ id: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    static func containing(_ p: CGPoint) -> CGDirectDisplayID {
        var id = CGDirectDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(p, 1, &id, &count)
        return count > 0 ? id : CGMainDisplayID()
    }

    static func best(for rect: CGRect) -> CGDirectDisplayID {
        all().max { CGDisplayBounds($0).intersection(rect).area < CGDisplayBounds($1).intersection(rect).area }
            ?? containing(CGPoint(x: rect.midX, y: rect.midY))
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Maps between screenshot pixel space and global screen points (top-left origin).
struct Geometry {
    var frame: CGRect
    var imageSize: CGSize

    var sx: CGFloat { frame.width / imageSize.width }
    var sy: CGFloat { frame.height / imageSize.height }

    func toGlobal(_ p: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + p.x * sx, y: frame.minY + p.y * sy)
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - frame.minX) / sx, y: (p.y - frame.minY) / sy)
    }

    func toImage(_ r: CGRect) -> CGRect {
        let o = toImage(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width / sx, height: r.height / sy)
    }

    func contains(imagePoint p: CGPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x < imageSize.width && p.y < imageSize.height
    }
}

enum ScopeTarget: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID, isolated: Bool)
}

final class Scope {
    static let shared = Scope()

    private(set) var target: ScopeTarget = .display(CGMainDisplayID())
    /// In window scope, bring the window's app to the front before keyboard input.
    var keepFocused = true
    /// Window scope only: operate the window without activating it or moving the user's pointer.
    private(set) var background = false
    private var last: (target: ScopeTarget, geometry: Geometry)?
    /// Owner of the scoped window, so the scope can follow the app if that window is replaced.
    private var scopedPID: pid_t?
    /// One-shot message for Claude about an automatic scope change.
    private var notice: String?

    static let maxEdge: CGFloat = {
        if let s = ProcessInfo.processInfo.environment["DESKTOPUSE_MAX_EDGE"], let v = Double(s), v >= 256 { return CGFloat(v) }
        return 1568
    }()
    static let maxPixels: CGFloat = 1_150_000

    func set(_ t: ScopeTarget, background: Bool? = nil) {
        if let background { self.background = background }
        if case .display = t { self.background = false }
        target = t
        last = nil
        notice = nil
        if case .window(let id, _) = t { scopedPID = WindowList.find(id)?.pid } else { scopedPID = nil }
    }

    var scopedWindowID: CGWindowID? {
        if case .window(let id, _) = target { return id }
        return nil
    }

    func scopedWindow() throws -> WindowInfo? {
        guard case .window(let id, let isolated) = target else { return nil }
        if let w = WindowList.find(id) { return w }
        // Windows are often replaced (a launch panel closes, a dialog finishes): follow the app.
        if let pid = scopedPID, let next = WindowList.appWindows().first(where: { $0.pid == pid }) {
            set(.window(next.id, isolated: isolated))
            notice = "The previously scoped window \(id) closed; scope moved to window \(next.id) of the same app."
            return next
        }
        throw ToolError("The scoped window (\(id)) no longer exists. Call set_scope or list_windows.")
    }

    /// The global rect a screenshot of the current scope covers, and the display it is on.
    func captureFrame() throws -> (frame: CGRect, display: CGDirectDisplayID) {
        switch target {
        case .display(let d):
            return (CGDisplayBounds(d), d)
        case .window(_, let isolated):
            let w = try scopedWindow()!
            let d = Displays.best(for: w.bounds)
            if isolated { return (w.bounds, d) }
            let clipped = w.bounds.intersection(CGDisplayBounds(d))
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
                throw ToolError("The scoped window is off-screen (minimized or on another Space).")
            }
            return (clipped, d)
        }
    }

    static func scaledSize(_ points: CGSize, backing: CGFloat) -> CGSize {
        let pw = points.width * backing, ph = points.height * backing
        let s = min(1, maxEdge / max(pw, ph), sqrt(maxPixels / max(1, pw * ph)))
        return CGSize(width: max(1, (pw * s).rounded()), height: max(1, (ph * s).rounded()))
    }

    /// Geometry used to interpret action coordinates. Reuses the last screenshot's scale so
    /// coordinates match what Claude saw, but follows the window if it has moved since.
    func geometry() throws -> Geometry {
        let (frame, display) = try captureFrame()
        if let last, last.target == target {
            return Geometry(frame: CGRect(origin: frame.origin, size: last.geometry.frame.size), imageSize: last.geometry.imageSize)
        }
        return Geometry(frame: frame, imageSize: Self.scaledSize(frame.size, backing: Displays.backingScale(display)))
    }

    func toGlobal(x: Double, y: Double) throws -> CGPoint {
        try geometry().toGlobal(CGPoint(x: x, y: y))
    }

    func screenshot() throws -> (CGImage, Geometry) {
        let (frame, display) = try captureFrame()
        let size = Self.scaledSize(frame.size, backing: Displays.backingScale(display))
        let image: CGImage
        if case .window(let id, true) = target {
            image = try Capture.window(id, size: size)
        } else {
            image = try Capture.region(frame, display: display, size: size)
        }
        let g = Geometry(frame: frame, imageSize: CGSize(width: image.width, height: image.height))
        last = (target, g)
        return (image, g)
    }

    func describe(_ g: Geometry) -> String {
        var s: String
        switch target {
        case .display(let d):
            let idx = Displays.all().firstIndex(of: d) ?? 0
            s = "Scope: display \(idx)\(CGDisplayIsMain(d) != 0 ? " (main)" : "")"
        case .window(let id, let isolated):
            let label = WindowList.find(id)?.label ?? "?"
            s = "Scope: window \(id) [\(label)]\(background ? " (background)" : isolated ? " (isolated capture)" : "")"
        }
        if let notice {
            s = "⚠️ \(notice)\n" + s
            self.notice = nil
        }
        s += " | screenshot \(fmt(g.imageSize.width))×\(fmt(g.imageSize.height)) px"
        if let position = Overlay.position, g.contains(imagePoint: g.toImage(position)) {
            let p = g.toImage(position)
            s += " | Claude's cursor at (\(fmt(p.x)), \(fmt(p.y)))"
        }
        if let front = NSWorkspace.shared.frontmostApplication?.localizedName {
            s += " | frontmost app: \(front)"
        }
        return s
    }
}
