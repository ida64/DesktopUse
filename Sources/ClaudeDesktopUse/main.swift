import AppKit

signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // Accessory: no Dock icon, never steals focus, but can show the overlay windows.
    app.setActivationPolicy(.accessory)
    CursorOverlay.shared.setup()
}

if !AX.isTrusted(prompt: false) || !CGPreflightScreenCaptureAccess() {
    log(Permissions.status())
}

let server = MCPServer(tools: ToolRegistry())
Thread.detachNewThread { server.run() }

MainActor.assumeIsolated {
    NSApplication.shared.run()
}
