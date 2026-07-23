import Foundation

/// (Renamed from upstream `EQBand` — Starpad already has an `EQBand` type in the
/// per-voice FX rack. Content otherwise verbatim from the Sarangi Live app.)
/// One band of the dry-branch **voice EQ** — the live form of the offline
/// chain's stage A (`blocks.parametric_eq`, `params["A_bands"]`). The JSON
/// schema mirrors the python dicts `{type, f, gain_db, Q}` exactly so settings
/// round-trip between the app, the presets, and the offline fit ("copy
/// A_bands JSON" in the EQ panel → paste into params/seeds).
///
/// The DE-HORN default (`EQBand.dehornA`) is the ear-approved 2026-07-06
/// inverse-horn EQ: the render carried a +3..+9 dB "honk" at 483–975 Hz where
/// the real sarangi has a body-antiresonance valley (the tar-shehnai
/// diagnosis — see memory: sarangi-tar-shehnai-honk); these cuts carve it.
public struct VoiceEQBand: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case peak, low, high            // python: "peak" | "low" | "high"
        public var label: String {
            switch self {
            case .peak: return "Peak"
            case .low: return "Low shelf"
            case .high: return "High shelf"
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    public var f: Double
    public var gainDB: Double
    public var q: Double                // peaks only (shelves use S=0.7)
    public var enabled: Bool

    public init(kind: Kind, f: Double, gainDB: Double, q: Double = 1.0,
                enabled: Bool = true) {
        self.kind = kind; self.f = f; self.gainDB = gainDB; self.q = q
        self.enabled = enabled
    }

    // -- Codable: python A_bands schema ({type, f, gain_db, Q}); `enabled`
    //    is app-only and optional so raw python dicts decode cleanly.
    enum CodingKeys: String, CodingKey {
        case kind = "type", f, gainDB = "gain_db", q = "Q", enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        f = try c.decode(Double.self, forKey: .f)
        gainDB = try c.decode(Double.self, forKey: .gainDB)
        q = try c.decodeIfPresent(Double.self, forKey: .q) ?? 1.0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(f, forKey: .f)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(q, forKey: .q)
        try c.encode(enabled, forKey: .enabled)
    }

    /// The biquad realizing this band (RBJ designs, 1:1 with blocks.py).
    public func biquad(sr: Double) -> Biquad {
        switch kind {
        case .peak: return .peaking(f0: f, gainDB: gainDB, q: q, sr: sr)
        case .low: return .lowShelf(f0: f, gainDB: gainDB, sr: sr)
        case .high: return .highShelf(f0: f, gainDB: gainDB, sr: sr)
        }
    }

    /// Magnitude response of this band alone (dB) — for the UI curve.
    public func responseDB(at freq: Double, sr: Double) -> Double {
        enabled ? biquad(sr: sr).magnitudeDB(at: freq, sr: sr) : 0.0
    }

    /// The ear-approved de-horn EQ (2026-07-06): cuts only, no shelf — the
    /// per-frame renormalization restores the air band by itself.
    public static let dehornA: [VoiceEQBand] = [
        VoiceEQBand(kind: .peak, f: 540.0, gainDB: -3.5, q: 2.2),
        VoiceEQBand(kind: .peak, f: 690.0, gainDB: -3.2, q: 2.2),
        VoiceEQBand(kind: .peak, f: 860.0, gainDB: -7.5, q: 2.0),
    ]

    /// Clean python-side A_bands JSON of the enabled bands (offline round-trip).
    public static func aBandsJSON(_ bands: [VoiceEQBand]) -> String {
        let entries = bands.filter(\.enabled).map { b -> String in
            var s = "{\"type\": \"\(b.kind.rawValue)\", \"f\": \(fmt(b.f)), " +
                    "\"gain_db\": \(fmt(b.gainDB))"
            if b.kind == .peak { s += ", \"Q\": \(fmt(b.q))" }
            return s + "}"
        }
        return "[" + entries.joined(separator: ", ") + "]"
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.1f", v) : String(format: "%.4g", v)
    }
}

public extension Biquad {
    /// |H(e^jw)| in dB at `freq` — coefficient-exact (for UI response curves).
    func magnitudeDB(at freq: Double, sr: Double) -> Double {
        let w = 2.0 * Double.pi * freq / sr
        let c1 = cos(w), s1 = sin(w)
        let c2 = cos(2 * w), s2 = sin(2 * w)
        let nRe = b0 + b1 * c1 + b2 * c2
        let nIm = -(b1 * s1 + b2 * s2)
        let dRe = 1.0 + a1 * c1 + a2 * c2
        let dIm = -(a1 * s1 + a2 * s2)
        let mag2 = (nRe * nRe + nIm * nIm) / max(dRe * dRe + dIm * dIm, 1e-30)
        return 10.0 * log10(max(mag2, 1e-30))
    }
}
