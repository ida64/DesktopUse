import AppKit

enum Shell {
    struct Result {
        var stdout: String
        var stderr: String
        var status: Int32
        var timedOut: Bool

        var summary: String {
            var parts: [String] = []
            if timedOut { parts.append("⚠️ timed out and was terminated") }
            parts.append("exit status: \(status)")
            if !stdout.isEmpty { parts.append("stdout:\n\(stdout.truncated(40_000))") }
            if !stderr.isEmpty { parts.append("stderr:\n\(stderr.truncated(10_000))") }
            return parts.joined(separator: "\n")
        }
    }

    static func run(_ path: String, _ args: [String], stdin: String? = nil, cwd: String? = nil, timeout: TimeInterval = 60) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath) }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()

        // Drain pipes concurrently so a chatty process can't block on a full buffer.
        let outBox = Box<Data>(), errBox = Box<Data>()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            DispatchQueue.global().async {
                box.value = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        _ = group.wait(timeout: .now() + 2)
        return Result(
            stdout: String(decoding: outBox.value ?? Data(), as: UTF8.self),
            stderr: String(decoding: errBox.value ?? Data(), as: UTF8.self),
            status: process.terminationStatus,
            timedOut: timedOut
        )
    }
}

enum Apps {
    static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    /// Finds a running app by name (case-insensitive, exact before prefix/contains), bundle id or pid.
    static func find(_ query: String) -> NSRunningApplication? {
        if let pid = pid_t(query), let app = NSRunningApplication(processIdentifier: pid) { return app }
        let q = query.lowercased()
        let all = NSWorkspace.shared.runningApplications
        return all.first { $0.bundleIdentifier?.lowercased() == q }
            ?? all.first { $0.localizedName?.lowercased() == q }
            ?? running().first { $0.localizedName?.lowercased().hasPrefix(q) == true }
            ?? running().first { $0.localizedName?.lowercased().contains(q) == true }
    }

    static func activate(_ pid: pid_t) {
        _ = NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementSetAttributeValue(AX.app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    static func raise(_ window: WindowInfo) {
        activate(window.pid)
        if let w = AX.window(window) {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }

    static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Opens a URL, file/folder (optionally with a specific app), app name or bundle id.
    static func open(_ target: String, with app: String?, background: Bool = false) throws -> String {
        let expanded = (target as NSString).expandingTildeInPath
        var args: [String] = background ? ["-g"] : []
        if let app { args += ["-a", app] }

        if target.contains("://") || target.hasPrefix("mailto:") || target.hasPrefix("tel:") {
            args.append(target)
        } else if FileManager.default.fileExists(atPath: expanded) {
            args.append(expanded)
        } else if app == nil, target.contains("."), !target.contains(" "),
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) != nil {
            args += ["-b", target]
        } else if app == nil {
            args += ["-a", target]
        } else {
            throw ToolError("'\(target)' is not a URL or an existing path.")
        }
        let r = try Shell.run("/usr/bin/open", args, timeout: 20)
        guard r.status == 0 else { throw ToolError("open failed: \(r.stderr.nonEmpty ?? "exit \(r.status)")") }
        return "Opened \(target)\(app.map { " with \($0)" } ?? "")\(background ? " in the background" : "")"
    }
}

enum Permissions {
    static func status() -> String {
        let ax = AX.isTrusted(prompt: false)
        let screen = CGPreflightScreenCaptureAccess()
        let host = hostAppName()
        var lines = [
            "Accessibility (mouse, keyboard, UI tree): \(ax ? "granted ✅" : "MISSING ❌")",
            "Screen Recording (screenshots): \(screen ? "granted ✅" : "MISSING ❌")",
        ]
        if !ax || !screen {
            lines.append("Grant both in System Settings → Privacy & Security to the app that launched this server (\(host)), then restart that app.")
        }
        return lines.joined(separator: "\n")
    }

    static func request() {
        if !AX.isTrusted(prompt: true) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// macOS attributes privacy permissions to the "responsible" GUI app, usually our host.
    static func hostAppName() -> String {
        var pid = getppid()
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName, app.activationPolicy == .regular {
                return name
            }
            guard let r = try? Shell.run("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"], timeout: 2),
                  let parent = pid_t(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), parent > 1
            else { break }
            pid = parent
        }
        return "your terminal or Claude app"
    }
}
