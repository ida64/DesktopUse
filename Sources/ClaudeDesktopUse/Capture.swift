import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Capture {
    static func content() throws -> SCShareableContent {
        try blocking { (box: Box<SCShareableContent>, done) in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                box.value = content
                box.error = error
                done()
            }
        }
    }

    private static func capture(_ filter: SCContentFilter, _ config: SCStreamConfiguration) throws -> CGImage {
        do {
            return try blocking { (box: Box<CGImage>, done) in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                    box.value = image
                    box.error = error
                    done()
                }
            }
        } catch {
            if (error as? ToolError)?.message.hasPrefix("Timed out") == true {
                // macOS stops answering a rebuilt binary while an older copy from the same path is still running.
                throw ToolError("Screen capture didn't respond. This happens when the server was rebuilt while another copy of it (e.g. another Claude session's) is still running: restart every Claude session that uses desktop-use.")
            }
            if !CGPreflightScreenCaptureAccess() {
                throw ToolError("Screen Recording permission is missing. Run the `permissions` tool with request:true. (\(error.localizedDescription))")
            }
            throw error
        }
    }

    /// Captures a global rect of one display, excluding Claude's own overlay windows.
    static func region(_ rect: CGRect, display: CGDirectDisplayID, size: CGSize, showsCursor: Bool = false) throws -> CGImage {
        let content = try content()
        guard let scDisplay = content.displays.first(where: { $0.displayID == display }) else {
            throw ToolError("Display \(display) is not available for capture.")
        }
        let own = content.windows.filter { $0.owningApplication.map { isOverlayProcess($0.processID) } ?? false }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: own)
        let db = CGDisplayBounds(display)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX - db.minX, y: rect.minY - db.minY, width: rect.width, height: rect.height)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = showsCursor
        config.captureResolution = .best
        return try capture(filter, config)
    }

    private static var overlayPIDs: [pid_t: Bool] = [:]

    /// True for this server and any other running copy of it (e.g. another Claude session's),
    /// so no Claude cursor ever shows up in a screenshot.
    private static func isOverlayProcess(_ pid: pid_t) -> Bool {
        if pid == getpid() { return true }
        if let known = overlayPIDs[pid] { return known }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let isOverlay = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
            && URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == ProcessInfo.processInfo.processName
        overlayPIDs[pid] = isOverlay
        return isOverlay
    }

    /// Captures a single window by itself, even when other windows cover it.
    static func window(_ id: CGWindowID, size: CGSize) throws -> CGImage {
        let content = try content()
        guard let w = content.windows.first(where: { $0.windowID == id }) else {
            throw ToolError("Window \(id) cannot be captured (closed, minimized or on another Space).")
        }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        return try capture(filter, config)
    }

    static func encode(_ image: CGImage, png: Bool = false, quality: Double = 0.82) -> Data {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
