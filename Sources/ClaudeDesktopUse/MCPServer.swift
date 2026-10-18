import Foundation

/// Minimal MCP server speaking newline-delimited JSON-RPC 2.0 over stdio.
/// stdout is reserved for protocol messages; diagnostics go to stderr via `log`.
final class MCPServer {
    private let tools: ToolRegistry
    private let outLock = NSLock()
    private static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    init(tools: ToolRegistry) {
        self.tools = tools
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
            else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = obj as? [[String: Any]] {
                batch.forEach(handle)
            } else if let msg = obj as? [String: Any] {
                handle(msg)
            }
        }
        log("stdin closed, exiting")
        exit(0)
    }

    private func handle(_ msg: [String: Any]) {
        // Responses from the client and notifications need no reply.
        guard let method = msg["method"] as? String, let id = msg["id"], !(id is NSNull) else { return }
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions.last!
            reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "claude-desktop-use", "version": "1.0.0"],
                "instructions": Instructions.text,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            reply(id, tools.call(name, args))
        case "resources/list":
            reply(id, ["resources": []])
        case "prompts/list":
            reply(id, ["prompts": []])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else {
            log("failed to serialize response")
            return
        }
        data.append(0x0A)
        outLock.lock()
        FileHandle.standardOutput.write(data)
        outLock.unlock()
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[claude-desktop-use] \(message)\n".utf8))
}

enum Instructions {
    static let text = """
    You are controlling the user's Mac. A small orange "Claude" cursor shows the user where you are acting.

    Work in a loop: screenshot → think → act → verify. Action tools (click, type_text, key, scroll, drag, …) \
    return a fresh screenshot by default; pass screenshot:false when chaining several quick actions.

    Coordinates: every x/y is in pixels of the most recent screenshot of the current scope, origin at its top-left. \
    Use set_scope to switch between the whole display and a single window (window scope gives sharper, smaller \
    screenshots and coordinates relative to that window, and follows the window if it moves). \
    To work without disturbing the user, use set_scope with background:true (and open with background:true): \
    the app stays behind other windows, input goes straight to it, and the user's own pointer and keyboard \
    are untouched. If something doesn't respond to background clicks, use ui_action, which also works in the background. \
    Games that lock the pointer (Minecraft and most 3D games) need the window in front (not background mode): \
    turn the camera with mouse_look, attack/use with click or mouse_button without x/y (in place), and move \
    with key + hold_ms (e.g. "w" for 1500). To aim precisely in Minecraft (placing or breaking specific blocks), \
    use look_at instead of working out mouse movements yourself: read position and facing once from F3, then \
    give block coordinates; it can click after each aim. Opening chat or a menu frees the pointer; press escape to return. \
    Use zoom to read small text; zoom images are for reading only, keep using screenshot coordinates.

    Prefer the most reliable channel: keyboard shortcuts (key), the accessibility tree (ui_tree + ui_action) for \
    exact buttons and fields, open for apps/files/URLs, run_applescript to script apps, and run_shell for anything \
    that doesn't need the GUI. Fall back to pixel clicking when nothing else fits.
    """
}
