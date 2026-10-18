import Foundation

/// Precise camera aiming for first-person games with a locked pointer, using Minecraft Java's
/// conventions: yaw 0 faces south (+z) and 90 faces west (-x); positive pitch looks down; the eye is
/// 1.62 above the feet. The camera angle is tracked across every relative move the server sends, so
/// after one reading from the F3 screen the next aims need no re-reading.
enum Aim {
    struct Vec3 {
        var x, y, z: Double
        static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
        var length: Double { (x * x + y * y + z * z).squareRoot() }
        var block: Vec3 { Vec3(x: x.rounded(.down), y: y.rounded(.down), z: z.rounded(.down)) }
        var label: String { [x, y, z].map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.2f", $0) }.joined(separator: ",") }
    }

    static var yaw: Double?
    static var pitch: Double?
    static var feet: Vec3?
    static var eyeHeight = 1.62
    static var degreesPerUnit = 0.15
    static var reach = 4.5

    /// Minecraft's mouse formula: the sensitivity slider's percentage s maps to f = s/200·0.6 + 0.2,
    /// and one mouse unit turns the camera f³·8·0.15 degrees (0.15° at the default 100%).
    static func minecraftDegreesPerUnit(sensitivityPercent s: Double) -> Double {
        let f = s / 200 * 0.6 + 0.2
        return f * f * f * 8 * 0.15
    }

    static var cameraLabel: String {
        guard let yaw, let pitch else { return "unknown" }
        return String(format: "yaw %.1f, pitch %.1f", yaw, pitch)
    }

    /// Keeps the tracked camera in step with a relative mouse move that was just sent.
    static func moved(dx: Int, dy: Int) {
        guard let y = yaw, let p = pitch else { return }
        yaw = normalized(y + Double(dx) * degreesPerUnit)
        pitch = min(90, max(-90, p + Double(dy) * degreesPerUnit))
    }

    /// Wraps an angle into (-180, 180].
    static func normalized(_ a: Double) -> Double {
        let r = (a + 180).truncatingRemainder(dividingBy: 360)
        return (r <= 0 ? r + 360 : r) - 180
    }

    // MARK: Targets

    /// Unit offsets of the six faces. A block's "up" face is its top, "north" faces -z, "east" +x.
    static let faces: [String: Vec3] = [
        "up": Vec3(x: 0, y: 1, z: 0), "down": Vec3(x: 0, y: -1, z: 0),
        "north": Vec3(x: 0, y: 0, z: -1), "south": Vec3(x: 0, y: 0, z: 1),
        "west": Vec3(x: -1, y: 0, z: 0), "east": Vec3(x: 1, y: 0, z: 0),
    ]

    struct Target {
        let yaw: Double
        let pitch: Double
        let distance: Double?
        let label: String
    }

    static func vec(_ value: Any?, _ name: String) throws -> Vec3? {
        guard let value else { return nil }
        guard let a = value as? [Any], a.count == 3,
              let x = (a[0] as? NSNumber)?.doubleValue, let y = (a[1] as? NSNumber)?.doubleValue, let z = (a[2] as? NSNumber)?.doubleValue
        else { throw ToolError("'\(name)' must be [x, y, z].") }
        return Vec3(x: x, y: y, z: z)
    }

    private static func face(_ name: String?, default fallback: String) throws -> (String, Vec3) {
        let key = (name ?? fallback).lowercased()
        guard let n = faces[key] else { throw ToolError("Face must be up, down, north, south, east or west (got '\(key)').") }
        return (key, n)
    }

    /// Whether the arguments name something to aim at.
    static func hasTarget(_ a: Args) -> Bool {
        ["yaw", "pitch", "point", "block", "place"].contains { a[$0] != nil }
    }

    /// Resolves one target: absolute angles, a world point, the centre of a block face, or the
    /// face to click so a new block lands at a given spot.
    static func resolve(_ a: Args) throws -> Target {
        if a["yaw"] != nil || a["pitch"] != nil {
            guard let current = yaw, let currentPitch = pitch else { throw unknownCamera }
            let y = a.double("yaw") ?? current, p = a.double("pitch") ?? currentPitch
            return Target(yaw: normalized(y), pitch: min(90, max(-90, p)), distance: nil, label: String(format: "yaw %.1f, pitch %.1f", y, p))
        }
        let point: Vec3, label: String
        if let p = try vec(a["point"], "point") {
            point = p
            label = "point \(p.label)"
        } else if let b = try vec(a["block"], "block")?.block {
            let (name, n) = try face(a.string("face"), default: "up")
            point = faceCentre(b, n)
            label = "\(name) face of \(b.label)"
        } else if let target = try vec(a["place"], "place")?.block {
            // The new block goes on the face of its neighbour in the `against` direction.
            let (name, n) = try face(a.string("against"), default: "down")
            let support = target + n
            point = faceCentre(support, Vec3(x: -n.x, y: -n.y, z: -n.z))
            label = "place \(target.label) against \(name) (\(support.label))"
        } else {
            throw ToolError("Give a target: yaw/pitch, point, block (+face) or place (+against).")
        }
        guard let feet else { throw ToolError("Player position unknown: pass position [x, y, z] from F3's 'XYZ' line.") }
        let v = point - (feet + Vec3(x: 0, y: eyeHeight, z: 0))
        let yaw = atan2(-v.x, v.z) * 180 / .pi
        let pitch = -atan2(v.y, (v.x * v.x + v.z * v.z).squareRoot()) * 180 / .pi
        return Target(yaw: yaw, pitch: pitch, distance: v.length, label: label)
    }

    private static func faceCentre(_ block: Vec3, _ n: Vec3) -> Vec3 {
        Vec3(x: block.x + 0.5 + n.x / 2, y: block.y + 0.5 + n.y / 2, z: block.z + 0.5 + n.z / 2)
    }

    static let unknownCamera = ToolError("Current camera angle unknown: pass from_yaw and from_pitch, read from F3's 'Facing' line (the two numbers in brackets are yaw / pitch).")

    /// Mouse units that turn the tracked camera onto `t`, the short way round.
    static func delta(to t: Target) throws -> (dx: Int, dy: Int) {
        guard let yaw, let pitch else { throw unknownCamera }
        let dx = Int((normalized(t.yaw - yaw) / degreesPerUnit).rounded())
        let dy = Int(((t.pitch - pitch) / degreesPerUnit).rounded())
        return (dx, dy)
    }
}
