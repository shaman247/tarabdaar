import Foundation

/// A body resonance (parchment/wood formant): `(f, gainDB, q)` peaking biquad.
public struct BodyMode: Codable, Sendable, Hashable {
    public var f: Double, gainDB: Double, q: Double
    public init(_ f: Double, _ gainDB: Double, _ q: Double) { self.f = f; self.gainDB = gainDB; self.q = q }

    /// chain.py BODY_MODES — parchment+wood modal ring (throat ~620, ring ~2.6k).
    public static let defaults: [BodyMode] = [
        BodyMode(420, -3, 9), BodyMode(620, 0, 7), BodyMode(950, -2, 6),
        BodyMode(1450, -3, 6), BodyMode(2600, -1, 5), BodyMode(4500, -7, 3),
    ]
}

/// The full model parameter set. The 27 `PARAM_SPEC` values live in `values`
/// (keyed by name, for generic slider binding); the non-fitted constants are
/// explicit. Loads the offline `params/pairN.json` presets leniently (ignoring
/// the offline-only `_fir` / `_post_eq_db` / `A_bands`).
public struct SarangiParams: Codable, Sendable, Equatable {
    public var values: [String: Double]
    public var gin: Double
    public var gout: Double
    public var dNHarm: Int
    public var eModes: [BodyMode]

    public init(values: [String: Double], gin: Double = 1.0, gout: Double = 1.0,
                dNHarm: Int = 3, eModes: [BodyMode] = BodyMode.defaults) {
        self.values = values; self.gin = gin; self.gout = gout
        self.dNHarm = dNHarm; self.eModes = eModes
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

    /// Load an offline `params/pairN.json` preset. Reads every PARAM_SPEC key it
    /// finds, plus gin/gout/D_nharm/E_modes; silently ignores `_fir`,
    /// `_post_eq_db`, `A_bands` (offline-only). Missing keys keep their defaults.
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
        if let n = obj["D_nharm"] as? NSNumber { p.dNHarm = n.intValue }
        if let modes = obj["E_modes"] as? [[Any]] {
            let parsed: [BodyMode] = modes.compactMap { row in
                guard row.count >= 3,
                      let f = (row[0] as? NSNumber)?.doubleValue,
                      let g = (row[1] as? NSNumber)?.doubleValue,
                      let q = (row[2] as? NSNumber)?.doubleValue else { return nil }
                return BodyMode(f, g, q)
            }
            if !parsed.isEmpty { p.eModes = parsed }
        }
        return p
    }

    public enum PresetError: Error { case malformed }
}
