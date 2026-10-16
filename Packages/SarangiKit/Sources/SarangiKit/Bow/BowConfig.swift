import Foundation

/// Bow-physics and control-law scalars from `bowed_string.json`.
public struct BowParams: Sendable {
    public var num: [String: Double]

    /// Scalar with the same fallback semantics as python's `bp.get(k, d)` —
    /// the defaults are `default_bow_params`' values, passed at call sites so
    /// the two stay greppably side by side.
    public func v(_ k: String, _ d: Double) -> Double { num[k] ?? d }

    public init(num: [String: Double] = [:]) {
        self.num = num
    }

    public init?(json: [String: Any]) {
        num = [:]
        for (k, v) in json {
            if let n = v as? NSNumber { num[k] = n.doubleValue }
        }
    }

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        self.init(json: dict)
    }
}
