import Foundation

struct ToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias Args = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }

    func int(_ key: String) -> Int? {
        double(key).map { Int($0.rounded()) }
    }

    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let s = self[key] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }

    /// Accepts either a JSON array of strings or a "cmd+shift" / "cmd,shift" string.
    func strings(_ key: String) -> [String] {
        if let a = self[key] as? [Any] { return a.compactMap { $0 as? String } }
        if let s = self[key] as? String {
            return s.split(whereSeparator: { $0 == "+" || $0 == "," || $0 == " " }).map(String.init)
        }
        return []
    }

    func requireDouble(_ key: String) throws -> Double {
        guard let v = double(key) else { throw ToolError("Missing required numeric argument '\(key)'") }
        return v
    }

    func requireString(_ key: String) throws -> String {
        guard let v = string(key) else { throw ToolError("Missing required argument '\(key)'") }
        return v
    }
}

enum Content {
    static func text(_ s: String) -> [String: Any] {
        ["type": "text", "text": s]
    }

    static func image(_ data: Data, mimeType: String) -> [String: Any] {
        ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
    }
}

/// Bridges a completion-handler API onto the calling (background) thread.
final class Box<T>: @unchecked Sendable {
    var value: T?
    var error: Error?
}

func blocking<T>(timeout: TimeInterval = 10, _ body: (Box<T>, @escaping @Sendable () -> Void) -> Void) throws -> T {
    let box = Box<T>()
    let sem = DispatchSemaphore(value: 0)
    body(box) { sem.signal() }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        throw ToolError("Timed out after \(Int(timeout))s")
    }
    if let error = box.error { throw error }
    guard let value = box.value else { throw ToolError("Operation returned no result") }
    return value
}

/// Runs `body` on the main thread and returns its result; safe to call from any thread.
func onMainSync<T>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
    return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
}

func sleepMs(_ ms: Double) {
    if ms > 0 { usleep(UInt32(ms * 1000)) }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func truncated(_ n: Int) -> String {
        count > n ? String(prefix(n)) + "…" : self
    }
}

func fmt(_ v: CGFloat) -> String { String(Int(v.rounded())) }
