import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    /// Elements from the most recent ui_tree call, addressable by their printed id.
    private static var registry: [Int: AXUIElement] = [:]

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func requireTrusted() throws {
        if !isTrusted(prompt: false) {
            throw ToolError("Accessibility permission is missing. Run the `permissions` tool with request:true.")
        }
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 2.0)
        // Chromium/Electron apps only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return el
    }

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = copy(el, attr) else { return nil }
        if let s = v as? String { return s }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return (v as! Bool) ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        copy(el, attr) as? Bool
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (copy(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = copy(el, kAXPositionAttribute), let sv = copy(el, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func window(_ info: WindowInfo) -> AXUIElement? {
        let windows = (copy(app(info.pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(w, &id) == .success, id == info.id { return w }
        }
        return windows.first { frame($0).map { abs($0.minX - info.bounds.minX) < 2 && abs($0.minY - info.bounds.minY) < 2 } ?? false }
    }

    static func element(id: Int) throws -> AXUIElement {
        guard let el = registry[id] else {
            throw ToolError("No element [\(id)]. Element ids come from the most recent ui_tree call; run it again.")
        }
        return el
    }

    // MARK: Tree dump

    private static let containerRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXGenericElement",
    ]

    struct DumpOptions {
        var maxDepth = 30
        var maxNodes = 350
        var filter: String?
        var timeBudget: TimeInterval = 5
    }

    static func dump(roots: [AXUIElement], geometry: Geometry, options: DumpOptions) -> String {
        registry = [:]
        var lines: [String] = []
        var truncated = false
        let deadline = Date().addingTimeInterval(options.timeBudget)
        let needle = options.filter?.lowercased().nonEmpty

        func visit(_ el: AXUIElement, depth: Int, indent: Int) {
            if registry.count >= options.maxNodes || Date() > deadline {
                truncated = true
                return
            }
            let role = string(el, kAXRoleAttribute) ?? "?"
            let subrole = string(el, kAXSubroleAttribute)
            let title = string(el, kAXTitleAttribute)?.nonEmpty
            let desc = string(el, kAXDescriptionAttribute)?.nonEmpty
            let placeholder = string(el, kAXPlaceholderValueAttribute)?.nonEmpty
            let help = string(el, kAXHelpAttribute)?.nonEmpty
            var value = string(el, kAXValueAttribute)?.nonEmpty
            if role == "AXStaticText", value == title { value = nil }
            let label = title ?? desc ?? placeholder ?? (role == "AXStaticText" ? nil : help)

            let boring = containerRoles.contains(role) && label == nil && value == nil
            var printed = false
            if !boring {
                var line = String(role.dropFirst(role.hasPrefix("AX") ? 2 : 0))
                if let subrole, subrole != "AXUnknown" { line += "(\(subrole.dropFirst(subrole.hasPrefix("AX") ? 2 : 0)))" }
                if let label { line += " \"\(label.truncated(80))\"" }
                if let desc, desc != label { line += " desc=\"\(desc.truncated(60))\"" }
                if let value { line += " value=\"\(value.replacingOccurrences(of: "\n", with: "⏎").truncated(120))\"" }
                if bool(el, kAXFocusedAttribute) == true { line += " FOCUSED" }
                if bool(el, kAXEnabledAttribute) == false { line += " disabled" }
                if bool(el, kAXSelectedAttribute) == true { line += " selected" }
                if let f = frame(el), f.width > 0, f.height > 0 {
                    let r = geometry.toImage(f)
                    let c = CGPoint(x: r.midX, y: r.midY)
                    line += " @(\(fmt(c.x)),\(fmt(c.y)) \(fmt(r.width))×\(fmt(r.height)))"
                    if !geometry.contains(imagePoint: c) { line += " offscreen" }
                }
                if needle == nil || line.lowercased().contains(needle!) {
                    let id = registry.count + 1
                    registry[id] = el
                    lines.append(String(repeating: "  ", count: needle == nil ? indent : 0) + "[\(id)] " + line)
                    printed = true
                }
            }
            guard depth < options.maxDepth else { return }
            for child in children(el) {
                visit(child, depth: depth + 1, indent: indent + (printed ? 1 : 0))
            }
        }

        roots.forEach { visit($0, depth: 0, indent: 0) }
        if lines.isEmpty { lines.append(needle == nil ? "(no accessible elements)" : "(no elements match \"\(options.filter!)\")") }
        if truncated { lines.append("… truncated (raise max_nodes, use filter, or scope to a smaller window)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    static func perform(_ el: AXUIElement, action: String, value: String?) throws -> String {
        let result: AXError
        switch action.lowercased() {
        case "press":
            result = AXUIElementPerformAction(el, kAXPressAction as CFString)
        case "focus":
            result = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case "set_value":
            guard let value else { throw ToolError("set_value requires 'value'.") }
            result = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString)
        case "show_menu":
            result = AXUIElementPerformAction(el, kAXShowMenuAction as CFString)
        case "raise":
            result = AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        case "increment":
            result = AXUIElementPerformAction(el, kAXIncrementAction as CFString)
        case "decrement":
            result = AXUIElementPerformAction(el, kAXDecrementAction as CFString)
        case "confirm":
            result = AXUIElementPerformAction(el, kAXConfirmAction as CFString)
        case "cancel":
            result = AXUIElementPerformAction(el, kAXCancelAction as CFString)
        case "select":
            result = AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        default:
            result = AXUIElementPerformAction(el, action as CFString)
        }
        guard result == .success else {
            let available = actions(el)
            throw ToolError("AX action '\(action)' failed (\(result.rawValue)). Element supports: \(available.isEmpty ? "none" : available.joined(separator: ", ")). Try action:\"click\" instead.")
        }
        return "Performed \(action)"
    }

    /// Finds the app's menu item for a keyboard shortcut and presses it. Menu shortcuts posted to a
    /// background app are ignored, but pressing the menu item works whether or not it is active.
    static func pressMenuShortcut(pid: pid_t, key: String, keyCode: CGKeyCode?, modifiers: [String]) -> String? {
        let mods = Set(modifiers.compactMap { Keyboard.modifierKeys[$0.lowercased()]?.flag.rawValue })
        // AXMenuItemCmdModifiers: 1 shift, 2 option, 4 control, 8 "no command key".
        var wanted = 0
        if mods.contains(CGEventFlags.maskShift.rawValue) { wanted |= 1 }
        if mods.contains(CGEventFlags.maskAlternate.rawValue) { wanted |= 2 }
        if mods.contains(CGEventFlags.maskControl.rawValue) { wanted |= 4 }
        if !mods.contains(CGEventFlags.maskCommand.rawValue) { wanted |= 8 }

        guard let bar = element(app(pid), kAXMenuBarAttribute) else { return nil }
        let deadline = Date().addingTimeInterval(2)

        func search(_ el: AXUIElement, path: [String]) -> String? {
            for child in children(el) where Date() < deadline {
                let title = string(child, kAXTitleAttribute) ?? ""
                if string(child, kAXRoleAttribute) == kAXMenuItemRole {
                    let char = string(child, kAXMenuItemCmdCharAttribute)
                    let virtualKey = (copy(child, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue
                    let charMatches = char.map { $0.lowercased() == key.lowercased() } ?? false
                    let keyMatches = keyCode != nil && virtualKey == Int(keyCode!) && (char ?? "").isEmpty
                    let itemMods = (copy(child, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
                    if (charMatches || keyMatches), itemMods == wanted, bool(child, kAXEnabledAttribute) != false {
                        if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                            return (path + [title]).joined(separator: " › ")
                        }
                    }
                }
                if let found = search(child, path: title.isEmpty ? path : path + [title]) { return found }
            }
            return nil
        }
        return search(bar, path: [])
    }

    static func describeFocused() -> String? {
        let system = AXUIElementCreateSystemWide()
        guard let el = element(system, kAXFocusedUIElementAttribute) else { return nil }
        let role = string(el, kAXRoleAttribute) ?? "?"
        let label = string(el, kAXTitleAttribute)?.nonEmpty ?? string(el, kAXDescriptionAttribute)?.nonEmpty ?? ""
        return "\(role) \(label.isEmpty ? "" : "\"\(label.truncated(60))\"")"
    }
}
