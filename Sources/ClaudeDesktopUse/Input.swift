import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum MouseButton: String {
    case left, right, middle

    var cg: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    var draggedType: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    static func parse(_ s: String?) throws -> MouseButton {
        guard let s else { return .left }
        guard let b = MouseButton(rawValue: s.lowercased()) else {
            throw ToolError("Unknown mouse button '\(s)'. Use left, right or middle.")
        }
        return b
    }
}

enum Input {
    private static let hidSource = CGEventSource(stateID: .hidSystemState)
    // Private state so routed events don't pick up modifiers the user is physically holding.
    private static let privateSource = CGEventSource(stateID: .privateState)
    private static var source: CGEventSource? { route == nil ? hidSource : privateSource }
    private static var held: MouseButton?
    private static var heldFlags: CGEventFlags = []

    /// When set, events go straight to this app/window instead of through the HID system:
    /// the app stays in the background and the user's pointer doesn't move.
    struct Route {
        let pid: pid_t
        let windowID: CGWindowID
    }

    static var route: Route?

    static func mouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Where Claude's cursor is. It is independent of the user's pointer.
    static func pointerLocation() -> CGPoint {
        Overlay.position ?? mouseLocation()
    }

    private static let windowUnderPointer = CGEventField(rawValue: 91)!
    private static let windowThatCanHandle = CGEventField(rawValue: 92)!

    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        guard let route else { return event.post(tap: .cghidEventTap) }
        if event.type != .keyDown, event.type != .keyUp, event.type != .flagsChanged {
            event.setIntegerValueField(windowUnderPointer, value: Int64(route.windowID))
            event.setIntegerValueField(windowThatCanHandle, value: Int64(route.windowID))
        }
        event.postToPid(route.pid)
    }

    private static func mouseEvent(_ type: CGEventType, _ p: CGPoint, _ button: MouseButton, flags: CGEventFlags = []) -> CGEvent? {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button.cg)
        e?.flags = flags
        return e
    }

    /// Moves the orange cursor smoothly to `target`. The real pointer jumps there at the end,
    /// unless a button is held, in which case it follows the path so drags register.
    static func glide(to target: CGPoint, minSteps: Int = 1) {
        let start = Overlay.position ?? pointerLocation()
        let distance = hypot(target.x - start.x, target.y - start.y)
        let dragging = held != nil
        let duration = Overlay.enabled ? min(0.4, max(0.12, Double(distance) / 2200)) : (dragging ? 0.15 : 0)
        let steps = max(minSteps, Int(duration * 60), 1)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let p = CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e)
            Overlay.show(at: p)
            if let held {
                post(mouseEvent(held.draggedType, p, held, flags: heldFlags))
            } else if i == steps, route != nil {
                post(mouseEvent(.mouseMoved, p, .left))
            }
            if i < steps { sleepMs(duration * 1000 / Double(steps)) }
        }
    }

    // MARK: Borrowing the user's pointer
    // Foreground clicks, drags and scrolls are delivered where the hardware pointer is, so the pointer
    // is moved to the target only for the action and then given straight back to the user.

    private static var borrowedFrom: CGPoint?

    private static func warp(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        // Warping briefly freezes the physical mouse; re-associating ends that immediately.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private static func borrowPointer(at p: CGPoint) {
        guard route == nil else { return }
        if borrowedFrom == nil { borrowedFrom = mouseLocation() }
        warp(p)
        post(mouseEvent(.mouseMoved, p, .left))
    }

    /// Puts the pointer back where the user left it, plus any movement they made meanwhile.
    private static func returnPointer(from last: CGPoint) {
        guard route == nil, held == nil, let home = borrowedFrom else { return }
        sleepMs(40) // let the window server deliver the action's events first
        let now = mouseLocation()
        warp(CGPoint(x: home.x + now.x - last.x, y: home.y + now.y - last.y))
        borrowedFrom = nil
    }

    /// Moves Claude's cursor and sends a hover event to the app under it, without moving the user's pointer.
    static func hover(at p: CGPoint) {
        glide(to: p)
        guard route == nil, held == nil,
              let window = WindowList.all().first(where: { $0.pid != getpid() && $0.bounds.contains(p) }),
              let e = mouseEvent(.mouseMoved, p, .left)
        else { return }
        e.setIntegerValueField(windowUnderPointer, value: Int64(window.id))
        e.setIntegerValueField(windowThatCanHandle, value: Int64(window.id))
        e.postToPid(window.pid)
    }

    /// Moves the user's real pointer to `p` and leaves it there (for hover UI that tracks the real pointer).
    static func movePointer(to p: CGPoint) {
        glide(to: p)
        guard route == nil else { return }
        warp(p)
        post(mouseEvent(.mouseMoved, p, .left))
    }

    /// Clicks at `target`, or, when it is nil, right where the pointer already is without moving it
    /// (needed for games that lock the pointer, like Minecraft).
    static func click(at target: CGPoint?, button: MouseButton = .left, count: Int = 1, modifiers: [String] = []) throws {
        let flags = try Keyboard.flags(for: modifiers)
        let p = target ?? mouseLocation()
        if let target {
            glide(to: target)
            borrowPointer(at: target)
        }
        defer { returnPointer(from: p) }
        try Keyboard.withModifiers(modifiers) {
            for i in 1...max(1, count) {
                let down = mouseEvent(button.downType, p, button, flags: flags)
                down?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                post(down)
                sleepMs(25)
                let up = mouseEvent(button.upType, p, button, flags: flags)
                up?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                post(up)
                if i < count { sleepMs(50) }
            }
        }
        Overlay.ripple()
    }

    /// Presses a button at `target`, or in place when it is nil (see `click`).
    static func buttonDown(_ button: MouseButton, at target: CGPoint?, modifiers: [String] = []) throws {
        if held != nil { buttonUp(at: target) }
        heldFlags = try Keyboard.flags(for: modifiers)
        let p = target ?? mouseLocation()
        if let target {
            glide(to: target)
            borrowPointer(at: target)
        }
        post(mouseEvent(button.downType, p, button, flags: heldFlags))
        held = button
        Overlay.ripple()
    }

    /// Releases the held button at `target`, or in place when it is nil.
    static func buttonUp(at target: CGPoint? = nil) {
        guard let button = held else { return }
        let p = target ?? mouseLocation()
        if let target, target != (Overlay.position ?? target) { glide(to: target, minSteps: 8) }
        post(mouseEvent(button.upType, p, button, flags: heldFlags))
        held = nil
        heldFlags = []
        returnPointer(from: p)
    }

    static func drag(_ points: [CGPoint], button: MouseButton = .left, modifiers: [String] = []) throws {
        guard let first = points.first, points.count >= 2 else { throw ToolError("A drag needs at least two points.") }
        try Keyboard.withModifiers(modifiers) {
            try buttonDown(button, at: first, modifiers: modifiers)
            sleepMs(90)
            for p in points.dropFirst() { glide(to: p, minSteps: 12) }
            sleepMs(90)
            buttonUp(at: points.last)
        }
    }

    /// Relative mouse movement the way games read it: only the event deltas change and the pointer
    /// is never warped, so a game that has locked the pointer (Minecraft) turns its camera.
    static func look(dx: Int, dy: Int, durationMs: Double) {
        let at = mouseLocation()
        let steps = max(1, Int(durationMs / 8))
        var sentX = 0, sentY = 0
        for i in 1...steps {
            let x = dx * i / steps, y = dy * i / steps
            let e = mouseEvent(held?.draggedType ?? .mouseMoved, at, held ?? .left, flags: heldFlags)
            e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(x - sentX))
            e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(y - sentY))
            post(e)
            sentX = x
            sentY = y
            if i < steps { sleepMs(durationMs / Double(steps)) }
        }
    }

    /// `dy` > 0 scrolls content up (towards the top), matching a mouse wheel rolled forward.
    static func scroll(at p: CGPoint, dx: Int, dy: Int, modifiers: [String] = []) throws {
        let flags = try Keyboard.flags(for: modifiers)
        glide(to: p)
        borrowPointer(at: p)
        defer { returnPointer(from: p) }
        let notches = max(abs(dx), abs(dy))
        for i in 0..<notches {
            let wy = i < abs(dy) ? Int32(dy.signum() * 3) : 0
            let wx = i < abs(dx) ? Int32(dx.signum() * 3) : 0
            let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: wy, wheel2: wx, wheel3: 0)
            e?.location = p
            e?.flags = flags
            post(e)
            sleepMs(20)
        }
    }

    // MARK: Keyboard

    static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        post(e)
    }

    static func typeCharacter(_ ch: Character) {
        if ch == "\n" || ch == "\r" { return tap(CGKeyCode(kVK_Return)) }
        if ch == "\t" { return tap(CGKeyCode(kVK_Tab)) }
        let utf16 = Array(String(ch).utf16)
        let mapped = Keyboard.layoutMap()[ch]
        let code = mapped?.code ?? 0
        let flags: CGEventFlags = mapped?.shift == true ? .maskShift : []
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            utf16.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: $0.baseAddress) }
            post(e)
        }
    }

    static func tap(_ code: CGKeyCode, flags: CGEventFlags = []) {
        key(code, down: true, flags: flags)
        sleepMs(8)
        key(code, down: false, flags: flags)
    }
}

enum Keyboard {
    struct Mapping {
        let code: CGKeyCode
        let shift: Bool
    }

    static let modifierKeys: [String: (code: Int, flag: CGEventFlags)] = [
        "cmd": (kVK_Command, .maskCommand), "command": (kVK_Command, .maskCommand), "⌘": (kVK_Command, .maskCommand),
        "super": (kVK_Command, .maskCommand), "meta": (kVK_Command, .maskCommand), "win": (kVK_Command, .maskCommand),
        "shift": (kVK_Shift, .maskShift), "⇧": (kVK_Shift, .maskShift),
        "option": (kVK_Option, .maskAlternate), "opt": (kVK_Option, .maskAlternate), "alt": (kVK_Option, .maskAlternate),
        "⌥": (kVK_Option, .maskAlternate),
        "ctrl": (kVK_Control, .maskControl), "control": (kVK_Control, .maskControl), "⌃": (kVK_Control, .maskControl),
        "fn": (kVK_Function, .maskSecondaryFn),
    ]

    static let namedKeys: [String: Int] = [
        "return": kVK_Return, "enter": kVK_Return, "kp_enter": kVK_ANSI_KeypadEnter, "tab": kVK_Tab, "space": kVK_Space,
        "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete, "del": kVK_ForwardDelete,
        "escape": kVK_Escape, "esc": kVK_Escape,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "help": kVK_Help,
        "capslock": kVK_CapsLock,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7,
        "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13,
        "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        "volumeup": kVK_VolumeUp, "volumedown": kVK_VolumeDown, "mute": kVK_Mute,
        "plus": kVK_ANSI_Equal, "minus": kVK_ANSI_Minus,
    ]

    private static let usFallback: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave, " ": kVK_Space,
    ]

    private static var cachedLayoutID: String?
    private static var cachedMap: [Character: Mapping] = [:]

    /// Character → key code for the user's current keyboard layout (so cmd+z works on AZERTY too).
    /// TIS APIs must run on the main thread.
    static func layoutMap() -> [Character: Mapping] {
        onMainSync { () -> [Character: Mapping] in
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            var layoutSource = source
            if let s = source, TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) == nil {
                layoutSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
            }
            guard let layoutSource,
                  let idPtr = TISGetInputSourceProperty(layoutSource, kTISPropertyInputSourceID),
                  let dataPtr = TISGetInputSourceProperty(layoutSource, kTISPropertyUnicodeKeyLayoutData)
            else { return usMap() }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            if id == cachedLayoutID { return cachedMap }

            let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
            var map: [Character: Mapping] = [:]
            data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
                for shift in [false, true] {
                    for code in 0..<128 {
                        var dead: UInt32 = 0
                        var length = 0
                        var chars = [UniChar](repeating: 0, count: 4)
                        let status = UCKeyTranslate(
                            base, UInt16(code), UInt16(kUCKeyActionDisplay),
                            shift ? UInt32((shiftKey >> 8) & 0xFF) : 0,
                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                            &dead, chars.count, &length, &chars
                        )
                        guard status == noErr, length > 0,
                              let ch = String(utf16CodeUnits: chars, count: length).first,
                              map[ch] == nil
                        else { continue }
                        map[ch] = Mapping(code: CGKeyCode(code), shift: shift)
                    }
                }
            }
            if map.isEmpty { return usMap() }
            cachedLayoutID = id
            cachedMap = map
            return map
        }
    }

    private static func usMap() -> [Character: Mapping] {
        usFallback.reduce(into: [:]) { $0[$1.key] = Mapping(code: CGKeyCode($1.value), shift: false) }
    }

    static func flags(for modifiers: [String]) throws -> CGEventFlags {
        try modifiers.reduce(into: CGEventFlags()) { acc, m in
            guard let entry = modifierKeys[m.lowercased()] else {
                throw ToolError("Unknown modifier '\(m)'. Use cmd, shift, option, ctrl or fn.")
            }
            acc.insert(entry.flag)
        }
    }

    /// Presses modifier keys for the duration of `body` so apps that track key state see them.
    static func withModifiers<T>(_ modifiers: [String], _ body: () throws -> T) throws -> T {
        let entries = try modifiers.map { m -> (code: Int, flag: CGEventFlags) in
            guard let e = modifierKeys[m.lowercased()] else { throw ToolError("Unknown modifier '\(m)'.") }
            return e
        }
        var flags: CGEventFlags = []
        for e in entries {
            flags.insert(e.flag)
            Input.key(CGKeyCode(e.code), down: true, flags: flags)
        }
        defer {
            for e in entries.reversed() {
                flags.remove(e.flag)
                Input.key(CGKeyCode(e.code), down: false, flags: flags)
            }
        }
        return try body()
    }

    /// Resolves a single key (named, or a literal character) to a key code plus any implied shift.
    static func resolve(_ name: String) throws -> Mapping {
        let lower = name.lowercased()
        if let code = namedKeys[lower] { return Mapping(code: CGKeyCode(code), shift: false) }
        if name.count == 1, let ch = name.first {
            let map = layoutMap()
            if let m = map[ch] { return m }
            if let m = map[Character(lower)] { return Mapping(code: m.code, shift: m.shift || ch.isUppercase) }
        }
        throw ToolError("Unknown key '\(name)'. Use a character or one of: \(namedKeys.keys.sorted().joined(separator: ", ")).")
    }

    enum Action: String { case press, down, up }

    /// Performs a combo like "cmd+shift+t", "return" or "shift" (modifiers alone).
    /// In background mode, returns a note when the shortcut was carried out through accessibility.
    @discardableResult
    static func perform(_ combo: String, action: Action = .press) throws -> String? {
        var parts = combo.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        if combo.hasSuffix("++") || combo == "+" { parts.append("+") }
        var modifiers: [String] = []
        var main: String?
        for part in parts {
            if modifierKeys[part.lowercased()] != nil {
                modifiers.append(part)
            } else {
                guard main == nil else { throw ToolError("'\(combo)' has more than one non-modifier key; send them separately.") }
                main = part
            }
        }

        let mapping = try main.map(resolve)
        // Characters like "?" need shift on most layouts.
        if mapping?.shift == true, !modifiers.contains(where: { $0.lowercased() == "shift" }) {
            modifiers.append("shift")
        }
        let flags = try flags(for: modifiers)

        switch action {
        case .press:
            // A background app ignores menu shortcuts: press the menu item, or do common edits directly.
            if let route = Input.route, let main, !modifiers.isEmpty {
                if let item = AX.pressMenuShortcut(pid: route.pid, key: main, keyCode: mapping?.code, modifiers: modifiers) {
                    return "\(combo) → menu \(item)"
                }
                if let note = Background.editShortcut(pid: route.pid, key: main, modifiers: modifiers) {
                    return "\(combo) → \(note)"
                }
            }
            try withModifiers(modifiers) {
                if let mapping { Input.tap(mapping.code, flags: flags) }
            }
        case .down:
            for m in modifiers { Input.key(CGKeyCode(modifierKeys[m.lowercased()]!.code), down: true, flags: flags) }
            if let mapping { Input.key(mapping.code, down: true, flags: flags) }
        case .up:
            if let mapping { Input.key(mapping.code, down: false, flags: flags) }
            for m in modifiers.reversed() { Input.key(CGKeyCode(modifierKeys[m.lowercased()]!.code), down: false, flags: []) }
        }
        return nil
    }
}

enum Clipboard {
    static var pasteboard: NSPasteboard { .general }

    static func text() -> String? {
        pasteboard.string(forType: .string)
    }

    static func setText(_ s: String) {
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
    }

    static func imagePNG() -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    static func fileURLs() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func snapshot() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    static func restore(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
