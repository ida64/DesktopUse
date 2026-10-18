import AppKit

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let run: (Args) throws -> [[String: Any]]
}

final class ToolRegistry {
    private let tools: [Tool]

    init() {
        tools = Self.build()
    }

    var definitions: [[String: Any]] {
        tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }
    }

    func call(_ name: String, _ args: Args) -> [String: Any] {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return ["content": [Content.text("Unknown tool: \(name)")], "isError": true]
        }
        do {
            return ["content": try tool.run(args), "isError": false]
        } catch {
            log("\(name) failed: \(error.localizedDescription)")
            return ["content": [Content.text("Error: \(error.localizedDescription)")], "isError": true]
        }
    }
}

// MARK: - Schema helpers

private func object(_ props: [String: Any], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": props, "required": required]
}

private func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
private func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
private func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
private func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
private func oneOf(_ values: [String], _ d: String) -> [String: Any] { ["type": "string", "enum": values, "description": d] }

private let xProp = num("X in screenshot pixels (from the left edge of the current scope).")
private let yProp = num("Y in screenshot pixels (from the top edge of the current scope).")
private let screenshotProp = bool("Return a screenshot after the action (default true). Use false when chaining quick actions.")
private let modifiersProp: [String: Any] = [
    "type": "array", "items": ["type": "string"],
    "description": "Modifier keys held during the action, e.g. [\"cmd\"] or [\"shift\",\"option\"].",
]
private let buttonProp = oneOf(["left", "right", "middle"], "Mouse button (default left).")

// MARK: - Shared behaviour

private func screenshotContent() throws -> [[String: Any]] {
    let (image, geometry) = try Scope.shared.screenshot()
    return [
        Content.image(Capture.encode(image), mimeType: "image/jpeg"),
        Content.text(Scope.shared.describe(geometry)),
    ]
}

/// Summary text plus, unless disabled, a screenshot taken after the UI settles.
private func respond(_ summary: String, _ args: Args, settleMs: Double = 350) throws -> [[String: Any]] {
    var out = [Content.text(summary)]
    if args.bool("screenshot") ?? true {
        sleepMs(args.double("settle_ms") ?? settleMs)
        out += try screenshotContent()
    }
    return out
}

private func point(_ args: Args, x: String = "x", y: String = "y") throws -> CGPoint? {
    guard let px = args.double(x), let py = args.double(y) else {
        if args[x] != nil || args[y] != nil { throw ToolError("Provide both '\(x)' and '\(y)'.") }
        return nil
    }
    return try Scope.shared.toGlobal(x: px, y: py)
}

private func requirePoint(_ args: Args) throws -> CGPoint {
    guard let p = try point(args) else { throw ToolError("Missing 'x' and 'y'.") }
    return p
}

private func describe(_ global: CGPoint) -> String {
    guard let g = try? Scope.shared.geometry() else { return "(\(fmt(global.x)), \(fmt(global.y)))" }
    let p = g.toImage(global)
    return "(\(fmt(p.x)), \(fmt(p.y)))"
}

/// Decides where the next input goes. In background scope, events are routed to the scoped window
/// and it is made key inside its app without activating it. Otherwise, before keyboard input,
/// the scoped window is brought forward if another app took focus.
private func prepareInput(keyboard: Bool) throws {
    Input.route = nil
    guard let w = try Scope.shared.scopedWindow() else { return }
    if Scope.shared.background {
        Background.makeKey(windowID: w.id, pid: w.pid)
        Input.route = Input.Route(pid: w.pid, windowID: w.id)
    } else if keyboard, Scope.shared.keepFocused, Apps.frontmostPID() != w.pid {
        Apps.raise(w)
        sleepMs(200)
    }
}

private func axRoots(_ args: Args) throws -> (roots: [AXUIElement], label: String) {
    try AX.requireTrusted()
    let includeMenuBar = args.bool("include_menu_bar") ?? false
    let pid: pid_t
    var roots: [AXUIElement] = []
    var label: String

    if let name = args.string("app") {
        guard let app = Apps.find(name) else { throw ToolError("No running app matches '\(name)'.") }
        pid = app.processIdentifier
        roots = [AX.app(pid)]
        label = app.localizedName ?? name
    } else if let w = try Scope.shared.scopedWindow() {
        pid = w.pid
        roots = [AX.window(w) ?? AX.app(pid)]
        label = "window \(w.id) [\(w.label)]"
        // Context menus and popovers live outside the window in the AX hierarchy.
        let appEl = AX.app(pid)
        roots += AX.children(appEl).filter { AX.string($0, kAXRoleAttribute) == kAXMenuRole }
        if includeMenuBar, let bar = AX.element(appEl, kAXMenuBarAttribute) { roots.append(bar) }
    } else {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ToolError("No frontmost application.") }
        pid = app.processIdentifier
        roots = [AX.app(pid)]
        label = "frontmost app \(app.localizedName ?? "?")"
    }
    return (roots, label)
}

private extension ToolRegistry {
    static func build() -> [Tool] {
        [
            // MARK: Seeing

            Tool(
                name: "screenshot",
                description: "Capture the current scope (whole display or a single window). All coordinates for other tools refer to this image's pixels.",
                schema: object([:])
            ) { _ in try screenshotContent() },

            Tool(
                name: "zoom",
                description: "Capture a region of the current scope at full native resolution to read small text or inspect details. The returned image is for viewing only; keep using the main screenshot's coordinates for actions.",
                schema: object([
                    "x": xProp, "y": yProp,
                    "width": num("Region width in screenshot pixels."),
                    "height": num("Region height in screenshot pixels."),
                ], required: ["x", "y", "width", "height"])
            ) { args in
                let g = try Scope.shared.geometry()
                let origin = g.toGlobal(CGPoint(x: try args.requireDouble("x"), y: try args.requireDouble("y")))
                var rect = CGRect(origin: origin, size: CGSize(width: try args.requireDouble("width") * g.sx, height: try args.requireDouble("height") * g.sy))
                let image: CGImage
                if case .window(let id, true) = Scope.shared.target, let w = try Scope.shared.scopedWindow() {
                    // Isolated scope: crop from the window's own pixels, which may be covered on screen.
                    let scale = Displays.backingScale(Displays.best(for: w.bounds))
                    let full = try Capture.window(id, size: CGSize(width: w.bounds.width * scale, height: w.bounds.height * scale))
                    let crop = CGRect(x: (rect.minX - w.bounds.minX) * scale, y: (rect.minY - w.bounds.minY) * scale,
                                      width: rect.width * scale, height: rect.height * scale)
                        .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
                    guard crop.area > 1, let cropped = full.cropping(to: crop.integral) else { throw ToolError("Region is outside the window.") }
                    image = cropped
                } else {
                    let display = Displays.best(for: rect)
                    rect = rect.intersection(CGDisplayBounds(display))
                    guard rect.area > 1 else { throw ToolError("Region is outside the screen.") }
                    let size = Scope.scaledSize(rect.size, backing: Displays.backingScale(display))
                    image = try Capture.region(rect, display: display, size: size)
                }
                return [
                    Content.image(Capture.encode(image, png: true), mimeType: "image/png"),
                    Content.text("Zoomed \(image.width)×\(image.height) view. Not a coordinate space for actions."),
                ]
            },

            Tool(
                name: "set_scope",
                description: "Choose what screenshots show and what x/y coordinates are relative to: a single window (by window_id or app) or a whole display. With no arguments, scopes to the main display. Returns a screenshot of the new scope.",
                schema: object([
                    "window_id": int("Window id from list_windows."),
                    "app": str("App name or bundle id; scopes to its frontmost window."),
                    "display": int("Display index from list_displays (0 = main). Used when no window/app is given."),
                    "isolated": bool("Window scope only: capture just the window's pixels even if covered by others (menus/popups from other windows won't appear). Default false."),
                    "focus": bool("Bring the window to the front (default true)."),
                    "keep_focused": bool("Before keyboard input, re-focus the scoped window if another app took focus (default true)."),
                    "background": bool("Window scope only: work in the window without bringing it to the front or moving the user's pointer. Input is sent straight to the app and screenshots show the window even when it's covered, so the user can keep working. Default false."),
                    "screenshot": screenshotProp,
                ])
            ) { args in
                let background = args.bool("background") ?? false
                let focus = args.bool("focus") ?? !background
                var window: WindowInfo?
                if let id = args.int("window_id") {
                    guard let w = WindowList.find(CGWindowID(id)) else { throw ToolError("No window with id \(id). Use list_windows.") }
                    window = w
                } else if let name = args.string("app") {
                    guard let app = Apps.find(name) else { throw ToolError("'\(name)' is not running. Use open to launch it first.") }
                    var windows = WindowList.appWindows().filter { $0.pid == app.processIdentifier }
                    if windows.isEmpty, focus || app.isHidden {
                        // Unhiding shows the windows without activating the app.
                        if focus { Apps.activate(app.processIdentifier) } else { app.unhide() }
                        sleepMs(600)
                        windows = WindowList.appWindows().filter { $0.pid == app.processIdentifier }
                    }
                    guard let w = windows.first else {
                        throw ToolError("\(app.localizedName ?? name) has no visible windows (it may be minimized or on another Space).")
                    }
                    window = w
                }

                if let keep = args.bool("keep_focused") { Scope.shared.keepFocused = keep }
                let summary: String
                if let w = window {
                    if focus {
                        Apps.raise(w)
                        sleepMs(250)
                    }
                    Scope.shared.set(.window(w.id, isolated: args.bool("isolated") ?? background), background: background)
                    Overlay.flash(w.bounds, label: "Claude · \(w.app)\(background ? " (background)" : "")")
                    summary = "Scope set to window \(w.id) [\(w.label)]\(background ? " in background mode: the app stays behind and the user's pointer is untouched" : "")."
                } else {
                    if background { throw ToolError("Background mode needs a window: pass window_id or app.") }
                    let displays = Displays.all()
                    let index = args.int("display") ?? 0
                    guard displays.indices.contains(index) else { throw ToolError("No display \(index). There are \(displays.count).") }
                    Scope.shared.set(.display(displays[index]))
                    Overlay.flash(CGDisplayBounds(displays[index]).insetBy(dx: 6, dy: 6), label: "Claude · Display \(index)")
                    summary = "Scope set to display \(index)."
                }
                return try respond(summary, args, settleMs: 0)
            },

            Tool(
                name: "list_windows",
                description: "List visible windows (front to back) with their ids, apps, titles and frames. ★ marks the current scope.",
                schema: object([
                    "app": str("Only windows whose app name contains this text."),
                    "all": bool("Include non-standard windows (menus, panels, status items). Default false."),
                ])
            ) { args in
                let filter = args.string("app")?.lowercased()
                let windows = (args.bool("all") == true ? WindowList.all() : WindowList.appWindows())
                    .filter { filter == nil || $0.app.lowercased().contains(filter!) }
                let scoped = Scope.shared.scopedWindowID
                let frontPID = Apps.frontmostPID()
                var lines = windows.map { w -> String in
                    let b = w.bounds
                    var line = "\(w.id == scoped ? "★" : " ") id \(w.id) | \(w.label) | (\(fmt(b.minX)),\(fmt(b.minY)) \(fmt(b.width))×\(fmt(b.height)))"
                    if w.layer != 0 { line += " layer \(w.layer)" }
                    if w.pid == frontPID { line += " | frontmost app" }
                    return line
                }
                if lines.isEmpty { lines = ["No matching windows."] }
                return [Content.text(lines.joined(separator: "\n"))]
            },

            Tool(
                name: "list_displays",
                description: "List connected displays with index, frame (global points) and scale.",
                schema: object([:])
            ) { _ in
                let lines = Displays.all().enumerated().map { i, d -> String in
                    let b = CGDisplayBounds(d)
                    return "display \(i)\(CGDisplayIsMain(d) != 0 ? " (main)" : "") | id \(d) | (\(fmt(b.minX)),\(fmt(b.minY)) \(fmt(b.width))×\(fmt(b.height))) pt | @\(Displays.backingScale(d))x"
                }
                return [Content.text(lines.joined(separator: "\n"))]
            },

            // MARK: Mouse

            Tool(
                name: "click",
                description: "Click at a point in the current screenshot (omit x/y to click in place without moving the pointer, e.g. to attack or use an item in a game). Use clicks:2 to double-click, button:\"right\" for a context menu, modifiers for cmd-click/shift-click. In background scope the click is carried out through accessibility (press buttons/links, place the caret in text, select rows) and the result says what happened.",
                schema: object([
                    "x": xProp, "y": yProp,
                    "button": buttonProp,
                    "clicks": int("Number of clicks: 1, 2 (double) or 3 (triple). Default 1."),
                    "modifiers": modifiersProp,
                    "screenshot": screenshotProp,
                ])
            ) { args in
                guard let p = try point(args) else {
                    // No point: click where the pointer is, without moving it (games that lock the pointer).
                    let button = try MouseButton.parse(args.string("button"))
                    let count = min(max(args.int("clicks") ?? 1, 1), 3)
                    try prepareInput(keyboard: true)
                    if Input.route != nil { throw ToolError("Background mode needs x and y for clicks.") }
                    try Input.click(at: nil, button: button, count: count, modifiers: args.strings("modifiers"))
                    return try respond("\(button.rawValue)-click in place\(count > 1 ? " ×\(count)" : "")", args)
                }
                let button = try MouseButton.parse(args.string("button"))
                let count = min(max(args.int("clicks") ?? 1, 1), 3)
                let mods = args.strings("modifiers")
                try prepareInput(keyboard: false)
                if let route = Input.route {
                    Input.glide(to: p)
                    let note = try Background.click(pid: route.pid, at: p, button: button, count: count)
                    Overlay.ripple()
                    return try respond("\(note) at \(describe(p)) (background)", args)
                }
                try Input.click(at: p, button: button, count: count, modifiers: mods)
                let what = (count > 1 ? "\(count)× " : "") + "\(button.rawValue)-click" + (mods.isEmpty ? "" : " with \(mods.joined(separator: "+"))")
                return try respond("\(what) at \(describe(p))", args)
            },

            Tool(
                name: "move_mouse",
                description: "Move Claude's cursor to a point and send a hover event to the app there (e.g. to reveal hover menus or tooltips). The user's own pointer is not moved unless move_user_pointer is true.",
                schema: object([
                    "x": xProp, "y": yProp,
                    "move_user_pointer": bool("Also move the user's real pointer there and leave it (only for hover UI that ignores hover events, e.g. Dock magnification). Default false."),
                    "screenshot": screenshotProp,
                ], required: ["x", "y"])
            ) { args in
                let p = try requirePoint(args)
                try prepareInput(keyboard: false)
                if Input.route != nil {
                    Input.glide(to: p)
                    return try respond("Moved Claude's cursor to \(describe(p)) (hover effects don't happen in background mode)", args)
                }
                if args.bool("move_user_pointer") == true {
                    Input.movePointer(to: p)
                    return try respond("Moved Claude's cursor and the user's pointer to \(describe(p))", args)
                }
                Input.hover(at: p)
                return try respond("Moved Claude's cursor to \(describe(p))", args)
            },

            Tool(
                name: "drag",
                description: "Press, drag and release. Give from/to points, or a path of [x,y] points for complex gestures (drawing, sliders, selecting text, moving files or windows).",
                schema: object([
                    "from_x": num("Start X (screenshot pixels)."), "from_y": num("Start Y."),
                    "to_x": num("End X."), "to_y": num("End Y."),
                    "path": ["type": "array", "items": ["type": "array", "items": ["type": "number"]], "description": "Optional list of [x,y] points; overrides from/to."],
                    "button": buttonProp,
                    "modifiers": modifiersProp,
                    "screenshot": screenshotProp,
                ])
            ) { args in
                var points: [CGPoint] = []
                if let path = args["path"] as? [[Any]] {
                    let g = try Scope.shared.geometry()
                    points = try path.map { pair in
                        guard pair.count >= 2, let x = (pair[0] as? NSNumber)?.doubleValue, let y = (pair[1] as? NSNumber)?.doubleValue else {
                            throw ToolError("Each path entry must be [x, y].")
                        }
                        return g.toGlobal(CGPoint(x: x, y: y))
                    }
                } else {
                    guard let a = try point(args, x: "from_x", y: "from_y"), let b = try point(args, x: "to_x", y: "to_y") else {
                        throw ToolError("Provide from_x/from_y/to_x/to_y or path.")
                    }
                    points = [a, b]
                }
                try prepareInput(keyboard: false)
                if Input.route != nil { throw ToolError("Dragging and holding buttons aren't possible in background mode: apps ignore synthetic mouse input while inactive. Use ui_action (e.g. set_value for sliders), or set_scope with background:false.") }
                try Input.drag(points, button: try MouseButton.parse(args.string("button")), modifiers: args.strings("modifiers"))
                return try respond("Dragged \(describe(points.first!)) → \(describe(points.last!)) via \(points.count) points", args)
            },

            Tool(
                name: "mouse_button",
                description: "Low-level: press or release a mouse button, at x/y or (without them) in place without moving the pointer. Use for press-and-hold, e.g. holding attack to mine in a game; combine with mouse_look to turn while holding.",
                schema: object([
                    "action": oneOf(["down", "up"], "Press or release."),
                    "x": xProp, "y": yProp,
                    "button": buttonProp,
                    "modifiers": modifiersProp,
                    "screenshot": screenshotProp,
                ], required: ["action"])
            ) { args in
                try prepareInput(keyboard: false)
                if Input.route != nil { throw ToolError("Dragging and holding buttons aren't possible in background mode: apps ignore synthetic mouse input while inactive. Use ui_action (e.g. set_value for sliders), or set_scope with background:false.") }
                let p = try point(args)
                if p == nil { try prepareInput(keyboard: true) }
                let place = p.map { "at \(describe($0))" } ?? "in place"
                if try args.requireString("action") == "down" {
                    try Input.buttonDown(try MouseButton.parse(args.string("button")), at: p, modifiers: args.strings("modifiers"))
                    return try respond("Button down \(place)", args)
                }
                Input.buttonUp(at: p)
                return try respond("Button up \(place)", args)
            },

            Tool(
                name: "scroll",
                description: "Scroll at a point (defaults to the centre of the current scope).",
                schema: object([
                    "x": xProp, "y": yProp,
                    "direction": oneOf(["up", "down", "left", "right"], "Scroll direction."),
                    "amount": int("Number of wheel notches (default 5; ~3 lines each)."),
                    "modifiers": modifiersProp,
                    "screenshot": screenshotProp,
                ], required: ["direction"])
            ) { args in
                let g = try Scope.shared.geometry()
                let p = try point(args) ?? CGPoint(x: g.frame.midX, y: g.frame.midY)
                let n = max(1, args.int("amount") ?? 5)
                let direction = try args.requireString("direction").lowercased()
                let (dx, dy): (Int, Int)
                switch direction {
                case "up": (dx, dy) = (0, n)
                case "down": (dx, dy) = (0, -n)
                case "left": (dx, dy) = (n, 0)
                case "right": (dx, dy) = (-n, 0)
                default: throw ToolError("direction must be up, down, left or right.")
                }
                try prepareInput(keyboard: false)
                if let route = Input.route {
                    Input.glide(to: p)
                    let note = try Background.scroll(pid: route.pid, at: p, dx: dx, dy: dy)
                    return try respond("\(note) \(direction) \(n) at \(describe(p)) (background)", args, settleMs: 300)
                }
                try Input.scroll(at: p, dx: dx, dy: dy, modifiers: args.strings("modifiers"))
                return try respond("Scrolled \(direction) \(n) at \(describe(p))", args, settleMs: 300)
            },

            Tool(
                name: "mouse_look",
                description: "Move the mouse by a relative amount without moving the pointer: what games with a locked pointer read, e.g. turning the camera in Minecraft. Brings the scoped window to the front first. Positive dx turns right, positive dy looks down. In Minecraft at default sensitivity one unit is 0.15° (2400 units is a full turn). To aim at a specific angle or block, use look_at.",
                schema: object([
                    "dx": num("Horizontal movement in mouse units (+ right, - left)."),
                    "dy": num("Vertical movement in mouse units (+ down, - up)."),
                    "duration_ms": num("Spread the movement over this long (default 150)."),
                    "screenshot": screenshotProp,
                ])
            ) { args in
                let dx = args.int("dx") ?? 0, dy = args.int("dy") ?? 0
                guard dx != 0 || dy != 0 else { throw ToolError("Give dx and/or dy.") }
                try prepareInput(keyboard: true)
                if Input.route != nil { throw ToolError("mouse_look needs the window in front; use set_scope with background:false.") }
                Input.look(dx: dx, dy: dy, durationMs: min(max(args.double("duration_ms") ?? 150, 0), 5000))
                Aim.moved(dx: dx, dy: dy)
                let camera = Aim.yaw == nil ? "" : " (tracked camera now \(Aim.cameraLabel))"
                return try respond("Moved the mouse by (\(dx), \(dy))\(camera)", args, settleMs: 150)
            },

            Tool(
                name: "look_at",
                description: """
                Aim a game camera exactly, without computing mouse movements yourself (Minecraft Java conventions: \
                yaw 0 = south/+z, 90 = west/-x; positive pitch looks down; eye 1.62 above the feet). \
                Target one of: yaw/pitch (absolute angles); point [x,y,z]; block [x,y,z] + face (aims at that face's centre); \
                or place [x,y,z] + against (aims at the face to right-click so a new block lands there; against \"down\" = on top of the block below). \
                Read the camera once from F3 ('Facing: … (yaw / pitch)') and pass from_yaw/from_pitch, and the player's feet from F3 'XYZ' as position. \
                The server then tracks the camera across look_at and mouse_look calls, and remembers position, so later calls need only the target. \
                Pass from_yaw/from_pitch again if the user or the game turned the camera, and position again after moving. \
                Use targets for a batch, with click \"right\" to place or \"left\" to break after each aim. \
                Batches go far to near by default so new blocks don't block the view of later ones. \
                Targets beyond reach are skipped when clicking. The server doesn't know the world, so it can't see if a block is in the way.
                """,
                schema: object([
                    "yaw": num("Target yaw in degrees."),
                    "pitch": num("Target pitch in degrees (-90 up to 90 down)."),
                    "point": ["type": "array", "items": ["type": "number"], "description": "World point [x,y,z] to look at."],
                    "block": ["type": "array", "items": ["type": "integer"], "description": "Block [x,y,z] to aim at (F3 'Targeted Block' coordinates)."],
                    "face": oneOf(["up", "down", "north", "south", "east", "west"], "Face of block to aim at (default up = top)."),
                    "place": ["type": "array", "items": ["type": "integer"], "description": "Where a new block should appear [x,y,z]; aims at the right face of its neighbour."],
                    "against": oneOf(["down", "up", "north", "south", "east", "west"], "Which neighbour of place to build against (default down = the block below)."),
                    "targets": ["type": "array", "items": ["type": "object"], "description": "Batch: a list of objects, each with one target (yaw/pitch, point, block+face or place+against)."],
                    "click": oneOf(["none", "right", "left"], "Click in place after each aim: right places/uses, left breaks/attacks. Default none."),
                    "order": oneOf(["far_first", "given"], "Batch order (default far_first)."),
                    "from_yaw": num("Current camera yaw from F3. Needed on the first call, or to resync."),
                    "from_pitch": num("Current camera pitch from F3. Needed on the first call, or to resync."),
                    "position": ["type": "array", "items": ["type": "number"], "description": "Player feet [x,y,z] from F3 'XYZ'. Remembered."],
                    "eye_height": num("Eye height above the feet (default 1.62; 1.27 while sneaking). Remembered."),
                    "sensitivity": num("Minecraft mouse sensitivity in percent as shown in Options → Controls → Mouse Settings (default 100). Remembered."),
                    "degrees_per_unit": num("Override: degrees the camera turns per mouse unit (default 0.15 = Minecraft at 100%). Remembered."),
                    "reach": num("Maximum click distance in blocks (default 4.5 survival; 5 in creative). Remembered."),
                    "interval_ms": num("Pause after each click in a batch (default 120)."),
                    "screenshot": screenshotProp,
                ])
            ) { args in
                if let s = args.double("sensitivity") { Aim.degreesPerUnit = Aim.minecraftDegreesPerUnit(sensitivityPercent: s) }
                if let d = args.double("degrees_per_unit"), d > 0 { Aim.degreesPerUnit = d }
                if let h = args.double("eye_height") { Aim.eyeHeight = h }
                if let r = args.double("reach") { Aim.reach = r }
                if let p = try Aim.vec(args["position"], "position") { Aim.feet = p }
                if let y = args.double("from_yaw") { Aim.yaw = Aim.normalized(y) }
                if let p = args.double("from_pitch") { Aim.pitch = p }
                if (args["from_yaw"] == nil) != (args["from_pitch"] == nil), Aim.yaw == nil || Aim.pitch == nil {
                    throw ToolError("Pass both from_yaw and from_pitch.")
                }

                let specs = (args["targets"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? (Aim.hasTarget(args) ? [args] : [])
                guard !specs.isEmpty else {
                    return [Content.text(String(format: "Camera %@; position %@; eye height %.2f; %.4f° per mouse unit; reach %.1f.",
                                                Aim.cameraLabel, Aim.feet?.label ?? "unknown", Aim.eyeHeight, Aim.degreesPerUnit, Aim.reach))]
                }
                var targets = try specs.map(Aim.resolve)
                if args.string("order") != "given" {
                    targets.sort { ($0.distance ?? 0) > ($1.distance ?? 0) }
                }
                let button = try MouseButton.parse(args.string("click") == "none" ? nil : args.string("click"))
                let clicking = args.string("click").map { $0 != "none" } ?? false
                let interval = min(max(args.double("interval_ms") ?? 120, 0), 5000)

                try prepareInput(keyboard: true)
                if Input.route != nil { throw ToolError("look_at needs the window in front; use set_scope with background:false.") }
                var lines: [String] = []
                for t in targets {
                    let dist = t.distance.map { String(format: ", %.2f away", $0) } ?? ""
                    if clicking, let d = t.distance, d > Aim.reach {
                        lines.append("skipped \(t.label)\(dist): beyond reach \(Aim.reach)")
                        continue
                    }
                    let (dx, dy) = try Aim.delta(to: t)
                    if dx != 0 || dy != 0 {
                        Input.look(dx: dx, dy: dy, durationMs: 40)
                        Aim.moved(dx: dx, dy: dy)
                    }
                    var line = String(format: "%@: yaw %.1f, pitch %.1f%@, moved (%d, %d)", t.label, t.yaw, t.pitch, dist, dx, dy)
                    if clicking {
                        // Let a frame render with the new angle before the game reads the click.
                        sleepMs(80)
                        try Input.click(at: nil, button: button, count: 1)
                        sleepMs(interval)
                        line += ", \(button.rawValue)-clicked"
                    }
                    lines.append(line)
                }
                lines.append("Camera now \(Aim.cameraLabel) (tracked).")
                return try respond(lines.joined(separator: "\n"), args, settleMs: 150)
            },

            Tool(
                name: "cursor_position",
                description: "Report where Claude's cursor is, in screenshot coordinates.",
                schema: object([:])
            ) { _ in
                guard let global = Overlay.position else { return [Content.text("Claude's cursor hasn't moved yet.")] }
                let g = try Scope.shared.geometry()
                let inside = g.contains(imagePoint: g.toImage(global)) ? "" : " (outside the current scope)"
                return [Content.text("Claude's cursor is at \(describe(global))\(inside); global (\(fmt(global.x)), \(fmt(global.y))) pt")]
            },

            // MARK: Keyboard

            Tool(
                name: "type_text",
                description: "Type text into the focused field. Supports any Unicode, newlines (Return) and tabs. Long text is pasted for speed unless method is \"keystrokes\"; the clipboard is restored afterwards.",
                schema: object([
                    "text": str("Text to type."),
                    "method": oneOf(["auto", "keystrokes", "paste"], "auto (default): keystrokes up to 200 chars, paste beyond."),
                    "screenshot": screenshotProp,
                ], required: ["text"])
            ) { args in
                let text = try args.requireString("text")
                let method = args.string("method") ?? "auto"
                try prepareInput(keyboard: true)
                let paste = method == "paste" || (method == "auto" && text.count > 200)
                if paste, let route = Input.route, Background.insertText(pid: route.pid, text) {
                    return try respond("Inserted \(text.count) characters (background)", args)
                }
                if paste {
                    let saved = Clipboard.snapshot()
                    Clipboard.setText(text)
                    try Keyboard.perform("cmd+v")
                    sleepMs(300)
                    Clipboard.restore(saved)
                } else {
                    for ch in text {
                        Input.typeCharacter(ch)
                        sleepMs(ch == "\n" ? 30 : 6)
                    }
                }
                return try respond("Typed \(text.count) characters\(paste ? " (via paste)" : "")", args)
            },

            Tool(
                name: "key",
                description: "Press keys or shortcuts. Separate several with spaces, e.g. \"cmd+a delete\", \"cmd+shift+t\", \"return\", \"escape\", \"down down return\", \"cmd+space\". Names: return, tab, space, delete, forwarddelete, escape, arrows (left/right/up/down), home, end, pageup, pagedown, f1–f20, volumeup/down, mute; modifiers cmd, shift, option, ctrl, fn.",
                schema: object([
                    "keys": str("Key combo(s), space separated."),
                    "action": oneOf(["press", "down", "up"], "press (default), or hold down / release for chords and press-and-hold."),
                    "repeat": int("Repeat the whole sequence this many times (default 1)."),
                    "hold_ms": num("Hold all the given keys down together for this long, then release (e.g. \"w\" for 2000 to walk forward in a game)."),
                    "screenshot": screenshotProp,
                ], required: ["keys"])
            ) { args in
                let keys = try args.requireString("keys")
                guard let action = Keyboard.Action(rawValue: args.string("action") ?? "press") else {
                    throw ToolError("action must be press, down or up.")
                }
                let combos = keys.split(separator: " ").map(String.init)
                let times = min(max(args.int("repeat") ?? 1, 1), 500)
                try prepareInput(keyboard: true)
                if let hold = args.double("hold_ms"), hold > 0 {
                    for combo in combos { try Keyboard.perform(combo, action: .down) }
                    sleepMs(min(hold, 30_000))
                    for combo in combos.reversed() { try Keyboard.perform(combo, action: .up) }
                    return try respond("Held \(keys) for \(Int(hold)) ms", args, settleMs: 100)
                }
                var notes: [String] = []
                for _ in 0..<times {
                    for combo in combos {
                        if let note = try Keyboard.perform(combo, action: action), !notes.contains(note) { notes.append(note) }
                        sleepMs(40)
                    }
                }
                let detail = notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n")
                return try respond("Key \(action.rawValue): \(keys)\(times > 1 ? " ×\(times)" : "")\(detail)", args)
            },

            // MARK: Clipboard

            Tool(
                name: "copy",
                description: "Press cmd+c in the focused app and return what was copied.",
                schema: object([:])
            ) { _ in
                try prepareInput(keyboard: true)
                let before = Clipboard.pasteboard.changeCount
                try Keyboard.perform("cmd+c")
                for _ in 0..<20 where Clipboard.pasteboard.changeCount == before { sleepMs(50) }
                if Clipboard.pasteboard.changeCount == before {
                    return [Content.text("Nothing new was copied (is there a selection?). Clipboard still holds:\n\(Clipboard.text()?.truncated(20_000) ?? "(no text)")")]
                }
                return clipboardContent()
            },

            Tool(
                name: "paste",
                description: "Paste into the focused app (cmd+v). If text is given it is placed on the clipboard first.",
                schema: object(["text": str("Optional text to put on the clipboard before pasting."), "screenshot": screenshotProp])
            ) { args in
                if let text = args.string("text") { Clipboard.setText(text) }
                try prepareInput(keyboard: true)
                let note = try Keyboard.perform("cmd+v")
                return try respond(note ?? "Pasted", args)
            },

            Tool(
                name: "clipboard",
                description: "Read the clipboard (text, image, or file paths) or write text to it.",
                schema: object([
                    "action": oneOf(["read", "write"], "read (default) or write."),
                    "text": str("Text to write."),
                ])
            ) { args in
                if args.string("action") == "write" {
                    Clipboard.setText(try args.requireString("text"))
                    return [Content.text("Clipboard set.")]
                }
                return clipboardContent()
            },

            // MARK: Accessibility

            Tool(
                name: "ui_tree",
                description: "Read the accessibility tree of the scoped window (or frontmost app, or a named app): roles, labels, values, focus, and each element's centre @(x,y w×h) in screenshot coordinates. Use [id]s with ui_action. Great for finding exact click targets and reading text.",
                schema: object([
                    "filter": str("Only list elements whose line contains this text (case-insensitive)."),
                    "app": str("Inspect this app instead of the current scope."),
                    "max_depth": int("Default 30."),
                    "max_nodes": int("Default 350."),
                    "include_menu_bar": bool("Window scope: also include the app's menu bar."),
                ])
            ) { args in
                let (roots, label) = try axRoots(args)
                var options = AX.DumpOptions()
                options.filter = args.string("filter")
                if let d = args.int("max_depth") { options.maxDepth = d }
                if let n = args.int("max_nodes") { options.maxNodes = n }
                let tree = AX.dump(roots: roots, geometry: try Scope.shared.geometry(), options: options)
                var header = "Accessibility tree of \(label)"
                if let focused = AX.describeFocused() { header += " | keyboard focus: \(focused)" }
                return [Content.text(header + "\n" + tree)]
            },

            Tool(
                name: "ui_action",
                description: "Act on an element from the last ui_tree: press, click, double_click, right_click, focus, set_value, show_menu, raise, increment, decrement, confirm, cancel, select, or any raw AX action name.",
                schema: object([
                    "id": int("Element id from ui_tree."),
                    "action": str("Action (default press)."),
                    "value": str("Value for set_value."),
                    "screenshot": screenshotProp,
                ], required: ["id"])
            ) { args in
                try AX.requireTrusted()
                guard let id = args.int("id") else { throw ToolError("Missing 'id'.") }
                let el = try AX.element(id: id)
                let action = args.string("action") ?? "press"
                let center = AX.frame(el).map { CGPoint(x: $0.midX, y: $0.midY) }
                let summary: String
                switch action {
                case "click", "double_click", "right_click":
                    guard let center else { throw ToolError("Element [\(id)] has no on-screen frame.") }
                    try prepareInput(keyboard: false)
                    if let route = Input.route {
                        Input.glide(to: center)
                        let note = try Background.click(pid: route.pid, at: center, button: action == "right_click" ? .right : .left, count: action == "double_click" ? 2 : 1)
                        Overlay.ripple()
                        return try respond("\(note) (background)", args)
                    }
                    try Input.click(at: center, button: action == "right_click" ? .right : .left, count: action == "double_click" ? 2 : 1)
                    summary = "\(action) on [\(id)] at \(describe(center))"
                default:
                    if let center {
                        Overlay.show(at: center)
                        Overlay.ripple()
                    }
                    summary = try AX.perform(el, action: action, value: args.string("value")) + " on [\(id)]"
                }
                return try respond(summary, args)
            },

            // MARK: Apps & windows

            Tool(
                name: "open",
                description: "Open an app (name or bundle id), a file or folder, or a URL (http, mailto, app deep links, x-apple.systempreferences:…). Optionally choose the app to open a file/URL with.",
                schema: object([
                    "target": str("App name, bundle id, path (~ allowed) or URL."),
                    "app": str("Open the target with this app."),
                    "background": bool("Open without bringing the app to the front (default false)."),
                    "screenshot": screenshotProp,
                ], required: ["target"])
            ) { args in
                let summary = try Apps.open(try args.requireString("target"), with: args.string("app"), background: args.bool("background") ?? false)
                return try respond(summary, args, settleMs: 1200)
            },

            Tool(
                name: "list_apps",
                description: "List running apps (name, bundle id, pid, state).",
                schema: object([:])
            ) { _ in
                let lines = Apps.running().map { app -> String in
                    var s = "\(app.localizedName ?? "?") | \(app.bundleIdentifier ?? "-") | pid \(app.processIdentifier)"
                    if app.isActive { s += " | active" }
                    if app.isHidden { s += " | hidden" }
                    return s
                }
                return [Content.text(lines.joined(separator: "\n"))]
            },

            Tool(
                name: "window_control",
                description: "Move, resize, minimize, restore, close, fullscreen or raise a window (the scoped window by default). Positions and sizes are in global screen points (see list_displays).",
                schema: object([
                    "action": oneOf(["raise", "move", "resize", "minimize", "restore", "close", "fullscreen", "exit_fullscreen"], "What to do."),
                    "window_id": int("Target window (default: scoped window, else frontmost window)."),
                    "x": num("move: new left edge (points)."), "y": num("move: new top edge (points)."),
                    "width": num("resize: width (points)."), "height": num("resize: height (points)."),
                    "screenshot": screenshotProp,
                ], required: ["action"])
            ) { args in
                try AX.requireTrusted()
                let action = try args.requireString("action")
                let info: WindowInfo
                if let id = args.int("window_id") {
                    guard let w = WindowList.find(CGWindowID(id)) else { throw ToolError("No window \(id).") }
                    info = w
                } else if let w = try Scope.shared.scopedWindow() {
                    info = w
                } else {
                    guard let pid = Apps.frontmostPID(), let w = WindowList.appWindows().first(where: { $0.pid == pid }) else {
                        throw ToolError("No target window. Pass window_id.")
                    }
                    info = w
                }
                guard let el = AX.window(info) else { throw ToolError("Window \(info.id) is not reachable via Accessibility.") }

                func set(_ attr: String, _ value: CFTypeRef) throws {
                    let r = AXUIElementSetAttributeValue(el, attr as CFString, value)
                    guard r == .success else { throw ToolError("Could not set \(attr) (\(r.rawValue)).") }
                }
                switch action {
                case "raise": Apps.raise(info)
                case "move":
                    var p = CGPoint(x: try args.requireDouble("x"), y: try args.requireDouble("y"))
                    try set(kAXPositionAttribute, AXValueCreate(.cgPoint, &p)!)
                case "resize":
                    var s = CGSize(width: try args.requireDouble("width"), height: try args.requireDouble("height"))
                    try set(kAXSizeAttribute, AXValueCreate(.cgSize, &s)!)
                case "minimize": try set(kAXMinimizedAttribute, kCFBooleanTrue)
                case "restore":
                    try set(kAXMinimizedAttribute, kCFBooleanFalse)
                    Apps.raise(info)
                case "fullscreen": try set("AXFullScreen", kCFBooleanTrue)
                case "exit_fullscreen": try set("AXFullScreen", kCFBooleanFalse)
                case "close":
                    guard let button = AX.element(el, kAXCloseButtonAttribute) else { throw ToolError("Window has no close button.") }
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                default: throw ToolError("Unknown action '\(action)'.")
                }
                let closedScope = action == "close" && info.id == Scope.shared.scopedWindowID
                if closedScope || action == "minimize" && info.id == Scope.shared.scopedWindowID {
                    Scope.shared.set(.display(Displays.best(for: info.bounds)))
                }
                let note = Scope.shared.scopedWindowID == nil && (action == "close" || action == "minimize") ? " Scope reset to the display." : ""
                return try respond("\(action) window \(info.id) [\(info.label)].\(note)", args, settleMs: 500)
            },

            // MARK: Scripting

            Tool(
                name: "run_applescript",
                description: "Run AppleScript (or JavaScript for Automation) to script apps directly: Finder, Safari, Mail, Music, System Events, etc. Returns the script result.",
                schema: object([
                    "script": str("Script source."),
                    "language": oneOf(["applescript", "javascript"], "Default applescript."),
                    "timeout": num("Seconds (default 60)."),
                ], required: ["script"])
            ) { args in
                let lang = args.string("language") == "javascript" ? "JavaScript" : "AppleScript"
                let r = try Shell.run("/usr/bin/osascript", ["-l", lang, "-"], stdin: try args.requireString("script"), timeout: args.double("timeout") ?? 60)
                if r.status != 0 { throw ToolError(r.summary) }
                return [Content.text(r.stdout.nonEmpty ?? "(no result)")]
            },

            Tool(
                name: "run_shell",
                description: "Run a shell command (zsh login shell) on the user's Mac and return stdout/stderr/exit status. Use for file operations, CLI tools, system info, defaults, etc.",
                schema: object([
                    "command": str("Command line."),
                    "cwd": str("Working directory (default home)."),
                    "timeout": num("Seconds (default 120, max 600)."),
                ], required: ["command"])
            ) { args in
                let timeout = min(args.double("timeout") ?? 120, 600)
                let r = try Shell.run("/bin/zsh", ["-lc", try args.requireString("command")], cwd: args.string("cwd") ?? NSHomeDirectory(), timeout: timeout)
                return [Content.text(r.summary)]
            },

            // MARK: Misc

            Tool(
                name: "wait",
                description: "Wait for something to load or animate, then (by default) take a screenshot.",
                schema: object(["seconds": num("Seconds to wait (default 1, max 60)."), "screenshot": screenshotProp])
            ) { args in
                let s = min(max(args.double("seconds") ?? 1, 0), 60)
                sleepMs(s * 1000)
                return try respond("Waited \(s)s", args, settleMs: 0)
            },

            Tool(
                name: "permissions",
                description: "Check (and with request:true, prompt for) the macOS Accessibility and Screen Recording permissions this server needs.",
                schema: object(["request": bool("Show the system prompts and open System Settings if missing.")])
            ) { args in
                if args.bool("request") == true { Permissions.request() }
                return [Content.text(Permissions.status())]
            },
        ]
    }
}

private func clipboardContent() -> [[String: Any]] {
    var out: [[String: Any]] = []
    let files = Clipboard.fileURLs()
    if !files.isEmpty { out.append(Content.text("Files:\n" + files.map(\.path).joined(separator: "\n"))) }
    if let text = Clipboard.text(), files.isEmpty { out.append(Content.text(text.truncated(20_000))) }
    if let png = Clipboard.imagePNG(), png.count < 5_000_000 { out.append(Content.image(png, mimeType: "image/png")) }
    return out.isEmpty ? [Content.text("(clipboard is empty)")] : out
}
