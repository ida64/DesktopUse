import AppKit

/// Lets Claude work in a window without activating its app or touching the user's pointer.
/// Events are posted straight to the target process, and the window is made key inside its own
/// app (without the app becoming frontmost) so AppKit treats clicks and keystrokes as normal input.
enum Background {
    private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    // Private SkyLight call, as used by window managers to focus a window without raising it.
    private static let postEventRecordTo: PostEventRecordTo? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "SLPSPostEventRecordTo")
        else {
            log("SLPSPostEventRecordTo unavailable; background clicks may need a first click to focus")
            return nil
        }
        return unsafeBitCast(symbol, to: PostEventRecordTo.self)
    }()

    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    // Deprecated (so hidden from Swift) but still exported, and SkyLight needs a PSN.
    private static let getProcessForPID: GetProcessForPID? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map { unsafeBitCast($0, to: GetProcessForPID.self) }
    }()

    static func makeKey(windowID: CGWindowID, pid: pid_t) {
        guard let post = postEventRecordTo, let getPSN = getProcessForPID else { return }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return }
        // Two records: "window became key" and "window ordered in", targeted at windowID.
        for kind: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xF8)
            bytes[0x04] = 0xF8
            bytes[0x08] = kind
            bytes[0x3A] = 0x10
            for i in 0x20..<0x30 { bytes[i] = 0xFF }
            withUnsafeBytes(of: windowID.littleEndian) { bytes.replaceSubrange(0x3C..<0x40, with: $0) }
            bytes.withUnsafeMutableBufferPointer { _ = post(&psn, $0.baseAddress!) }
        }
    }
}

// MARK: - Accessibility-driven actions
// Background apps receive keystrokes, but AppKit drops synthetic mouse and scroll events
// aimed at windows that aren't active, so pointer actions are carried out through accessibility.

extension Background {
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    private static let selectableRoles: Set<String> = ["AXRow", "AXOutlineRow", "AXCell", "AXTab", "AXRadioButton"]

    static func hitTest(pid: pid_t, at p: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AX.app(pid), Float(p.x), Float(p.y), &hit) == .success else { return nil }
        return hit
    }

    /// The element and its ancestors, nearest first.
    private static func chain(_ el: AXUIElement, limit: Int) -> [AXUIElement] {
        var out = [el]
        while out.count < limit, let parent = AX.element(out.last!, kAXParentAttribute) {
            out.append(parent)
        }
        return out
    }

    static func label(_ el: AXUIElement) -> String {
        let role = AX.string(el, kAXRoleAttribute) ?? "element"
        let name = AX.string(el, kAXTitleAttribute)?.nonEmpty ?? AX.string(el, kAXDescriptionAttribute)?.nonEmpty
        return name.map { "\(role) \"\($0.truncated(50))\"" } ?? role
    }

    private static func isTextInput(_ el: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXSelectedTextRangeAttribute as CFString, &settable)
        return settable.boolValue || textRoles.contains(AX.string(el, kAXRoleAttribute) ?? "")
    }

    private static func setSelection(_ el: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func characterIndex(in el: AXUIElement, at p: CGPoint, textLength: Int) -> Int {
        var point = p
        guard let position = AXValueCreate(.cgPoint, &point) else { return textLength }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForPositionParameterizedAttribute as CFString, position, &result) == .success,
              let value = result, CFGetTypeID(value) == AXValueGetTypeID()
        else { return textLength }
        var range = CFRange()
        AXValueGetValue(value as! AXValue, .cfRange, &range)
        return min(max(range.location, 0), textLength)
    }

    static func click(pid: pid_t, at p: CGPoint, button: MouseButton, count: Int) throws -> String {
        guard let hit = hitTest(pid: pid, at: p) else {
            throw ToolError("Nothing accessible at that point. In background mode clicks go through accessibility; try ui_tree + ui_action, or set_scope with background:false.")
        }
        let ancestors = chain(hit, limit: 6)

        if button == .right {
            guard let el = ancestors.first(where: { AX.actions($0).contains(kAXShowMenuAction) }) else {
                throw ToolError("\(label(hit)) has no context menu reachable in background mode.")
            }
            AXUIElementPerformAction(el, kAXShowMenuAction as CFString)
            return "Opened the context menu of \(label(el))"
        }

        if let text = ancestors.prefix(3).first(where: isTextInput) {
            AXUIElementSetAttributeValue(text, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let value = (AX.string(text, kAXValueAttribute) ?? "") as NSString
            let index = characterIndex(in: text, at: p, textLength: value.length)
            var range = NSRange(location: index, length: 0)
            var what = "Placed the caret in \(label(text)) at character \(index)"
            if count == 2, value.length > 0 {
                range = wordRange(in: value, at: index)
                what = "Selected \"\(value.substring(with: range).truncated(60))\" in \(label(text))"
            } else if count >= 3, value.length > 0 {
                range = value.paragraphRange(for: NSRange(location: min(index, value.length - 1), length: 0))
                what = "Selected the paragraph in \(label(text))"
            }
            _ = setSelection(text, range)
            return what
        }

        for el in ancestors {
            let actions = AX.actions(el)
            if count >= 2, actions.contains("AXOpen") {
                AXUIElementPerformAction(el, "AXOpen" as CFString)
                return "Opened \(label(el))"
            }
            if actions.contains(kAXPressAction) {
                let result = AXUIElementPerformAction(el, kAXPressAction as CFString)
                if result == .success { return "Pressed \(label(el))" }
            }
            if actions.contains(kAXPickAction), AXUIElementPerformAction(el, kAXPickAction as CFString) == .success {
                return "Picked \(label(el))"
            }
            if selectableRoles.contains(AX.string(el, kAXRoleAttribute) ?? ""),
               AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
                return "Selected \(label(el))"
            }
        }
        if AXUIElementSetAttributeValue(hit, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return "Focused \(label(hit)) (it has no press action)"
        }
        throw ToolError("\(label(hit)) can't be clicked in background mode. Try ui_tree + ui_action, or set_scope with background:false.")
    }

    private static func wordRange(in text: NSString, at index: Int) -> NSRange {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_'"))
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
            return word.contains(scalar)
        }
        var start = min(index, text.length - 1), end = start
        if !isWord(start), isWord(start - 1) { start -= 1; end = start }
        guard isWord(start) else { return NSRange(location: start, length: 1) }
        while isWord(start - 1) { start -= 1 }
        while isWord(end + 1) { end += 1 }
        return NSRange(location: start, length: end - start + 1)
    }

    /// Scrolls the scroll area under `p` by moving its scroll bars. `dy` > 0 scrolls towards the top.
    static func scroll(pid: pid_t, at p: CGPoint, dx: Int, dy: Int) throws -> String {
        guard let hit = hitTest(pid: pid, at: p),
              let area = chain(hit, limit: 15).first(where: { AX.string($0, kAXRoleAttribute) == kAXScrollAreaRole })
        else {
            throw ToolError("No scrollable area at that point. In background mode try key \"pagedown\"/\"pageup\", or set_scope with background:false.")
        }
        let content = AX.children(area).first { AX.string($0, kAXRoleAttribute) != kAXScrollBarRole }.flatMap(AX.frame)
        let visible = AX.frame(area) ?? .zero
        var moved = false
        for (bar, notches, contentLength, visibleLength) in [
            (AX.element(area, kAXVerticalScrollBarAttribute), -dy, content?.height, visible.height),
            (AX.element(area, kAXHorizontalScrollBarAttribute), -dx, content?.width, visible.width),
        ] where notches != 0 {
            guard let bar, let current = (AX.copy(bar, kAXValueAttribute) as? NSNumber)?.doubleValue else { continue }
            let travel = max(1, Double((contentLength ?? visibleLength * 4) - visibleLength))
            let next = min(1, max(0, current + Double(notches) * 48 / travel))
            moved = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next)) == .success || moved
        }
        guard moved else {
            throw ToolError("\(label(area)) can't be scrolled through accessibility. Try key \"pagedown\"/\"pageup\", or set_scope with background:false.")
        }
        return "Scrolled \(label(area))"
    }

    /// Select all / copy / cut / paste on the focused text field, since a background app's edit menu is disabled.
    static func editShortcut(pid: pid_t, key: String, modifiers: [String]) -> String? {
        guard modifiers.map({ $0.lowercased() }).allSatisfy({ ["cmd", "command", "⌘", "super", "meta", "win"].contains($0) }),
              let el = AX.element(AX.app(pid), kAXFocusedUIElementAttribute), isTextInput(el)
        else { return nil }
        let value = (AX.string(el, kAXValueAttribute) ?? "") as NSString
        switch key.lowercased() {
        case "a":
            return setSelection(el, NSRange(location: 0, length: value.length)) ? "Selected all text in \(label(el))" : nil
        case "c", "x":
            guard let selected = AX.string(el, kAXSelectedTextAttribute), !selected.isEmpty else { return nil }
            Clipboard.setText(selected)
            if key.lowercased() == "x" { AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, "" as CFString) }
            return "\(key.lowercased() == "x" ? "Cut" : "Copied") \(selected.count) characters from \(label(el))"
        case "v":
            guard let text = Clipboard.text(), insertText(pid: pid, text) else { return nil }
            return "Pasted \(text.count) characters into \(label(el))"
        default:
            return nil
        }
    }

    /// Inserts text at the caret of the app's focused text field, replacing any selection.
    static func insertText(pid: pid_t, _ text: String) -> Bool {
        guard let el = AX.element(AX.app(pid), kAXFocusedUIElementAttribute) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}
