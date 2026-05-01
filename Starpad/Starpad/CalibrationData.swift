import Foundation

/// A 3D orientation point capturing pitch, roll, and yaw.
struct CalibrationPoint3D: Codable, Equatable {
    var pitch: Double  // radians
    var roll: Double   // radians
    var yaw: Double    // radians

    var pitchDegrees: Double { pitch * 180.0 / .pi }
    var rollDegrees: Double { roll * 180.0 / .pi }
    var yawDegrees: Double { yaw * 180.0 / .pi }

    /// 3D vector from this point to another
    func vector(to other: CalibrationPoint3D) -> (dp: Double, dr: Double, dy: Double) {
        (other.pitch - pitch, other.roll - roll, other.yaw - yaw)
    }
}

/// A calibrated tilt axis defined by two endpoints relative to a rest position.
struct TiltAxis: Codable, Equatable {
    var name: String
    var instruction_positive: String
    var instruction_negative: String
    var icon_positive: String
    var icon_negative: String
    var positiveEnd: CalibrationPoint3D
    var negativeEnd: CalibrationPoint3D
}

/// Three-axis calibration data with 3D vector projection.
///
/// The calibration captures 7 positions: 1 rest + 2 endpoints per axis.
/// Each axis defines a direction in (pitch, roll, yaw) space. Live
/// orientation is projected onto each axis to produce a normalized
/// value from -1 (negative endpoint) to +1 (positive endpoint),
/// with 0 at the rest position.
struct CalibrationData: Codable, Equatable {
    var rest: CalibrationPoint3D
    var axes: [TiltAxis]  // exactly 3

    /// Default axis definitions with suggested motions.
    static let defaultAxes: [(name: String, instrPos: String, instrNeg: String, iconPos: String, iconNeg: String)] = [
        ("Tilt 1", "Move your forearm up", "Move your forearm down",
         "arrow.up", "arrow.down"),
        ("Tilt 2", "Tilt the iPad towards you", "Tilt the iPad away from you",
         "arrow.left", "arrow.right"),
        ("Tilt 3", "Rotate your arm inward", "Rotate your arm outward",
         "arrow.counterclockwise", "arrow.clockwise")
    ]

    /// Projects current orientation onto the 3 calibrated axes.
    /// Returns an array of 3 values, each in the range -1 to +1.
    /// -1 = negative endpoint, 0 = rest, +1 = positive endpoint.
    func normalize(pitch: Double, roll: Double, yaw: Double) -> [Double] {
        let offset = (dp: pitch - rest.pitch, dr: roll - rest.roll, dy: yaw - rest.yaw)

        return axes.map { axis in
            // Full axis vector from negative to positive endpoint
            let axisVec = (
                dp: axis.positiveEnd.pitch - axis.negativeEnd.pitch,
                dr: axis.positiveEnd.roll - axis.negativeEnd.roll,
                dy: axis.positiveEnd.yaw - axis.negativeEnd.yaw
            )

            // Midpoint of the axis (in offset space from rest)
            let mid = (
                dp: (axis.positiveEnd.pitch + axis.negativeEnd.pitch) / 2 - rest.pitch,
                dr: (axis.positiveEnd.roll + axis.negativeEnd.roll) / 2 - rest.roll,
                dy: (axis.positiveEnd.yaw + axis.negativeEnd.yaw) / 2 - rest.yaw
            )

            // Offset from the axis midpoint
            let fromMid = (
                dp: offset.dp - mid.dp,
                dr: offset.dr - mid.dr,
                dy: offset.dy - mid.dy
            )

            // Project onto axis direction
            let dot = fromMid.dp * axisVec.dp + fromMid.dr * axisVec.dr + fromMid.dy * axisVec.dy
            let mag2 = axisVec.dp * axisVec.dp + axisVec.dr * axisVec.dr + axisVec.dy * axisVec.dy
            guard mag2 > 1e-10 else { return 0 }

            // Result: dot/mag2 gives a value where ±0.5 = endpoints.
            // Scale to -1..+1
            return dot / mag2 * 2.0
        }
    }

    // MARK: - Persistence

    private static let storageKey = "starpad_calibration_v2"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func load() -> CalibrationData? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let cal = try? JSONDecoder().decode(CalibrationData.self, from: data)
        else { return nil }
        return cal
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
