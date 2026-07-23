import Foundation

/// The v57 instrument's parameter set: the ParamSpec values live in `values`
/// (keyed by name, for generic slider binding) + the gin/gout level trims.
/// Loads the offline preset JSON leniently (unknown/offline-only keys are
/// ignored).
public struct SarangiParams: Codable, Sendable, Equatable {
    public var values: [String: Double]
    public var gin: Double
    public var gout: Double

    public init(values: [String: Double], gin: Double = 1.0, gout: Double = 1.0) {
        self.values = values; self.gin = gin; self.gout = gout
    }

    public subscript(_ name: String) -> Double {
        get { values[name] ?? ParamSpec.byName[name]?.default ?? 0 }
        set { values[name] = newValue }
    }

    public static var defaults: SarangiParams {
        var v: [String: Double] = [:]
        for d in ParamSpec.all { v[d.id] = d.default }
        return SarangiParams(values: v)
    }

    /// Load an offline preset JSON. Reads every ParamSpec key it finds plus
    /// gin/gout; silently ignores offline-only keys. Missing keys keep their
    /// defaults.
    public static func loadPreset(data: Data) throws -> SarangiParams {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PresetError.malformed
        }
        var p = SarangiParams.defaults
        for d in ParamSpec.all {
            if let n = obj[d.id] as? NSNumber { p.values[d.id] = n.doubleValue }
        }
        if let n = obj["gin"] as? NSNumber { p.gin = n.doubleValue }
        if let n = obj["gout"] as? NSNumber { p.gout = n.doubleValue }
        return p
    }

    public enum PresetError: Error { case malformed }
}
