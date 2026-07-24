import Foundation
public enum InputDimension: Int, Codable, CaseIterable, Hashable {
    case tilt1          = 0
    case tilt2          = 1
    case tilt3          = 2
    case accelPressure  = 3
    case keyY           = 4
    case slider1        = 5
    case slider2        = 6
    case none           = -1

    public var label: String {
        switch self {
        case .tilt1:         return "Tilt 1"
        case .tilt2:         return "Tilt 2"
        case .tilt3:         return "Tilt 3"
        case .accelPressure: return "Pressure"
        case .keyY:          return "Key Y"
        case .slider1:       return "Slider 1"
        case .slider2:       return "Slider 2"
        case .none:          return "None"
        }
    }

    /// Short label for matrix column/row headers.
    public var shortLabel: String {
        switch self {
        case .tilt1:         return "T1"
        case .tilt2:         return "T2"
        case .tilt3:         return "T3"
        case .accelPressure: return "Pr"
        case .keyY:          return "Y"
        case .slider1:       return "S1"
        case .slider2:       return "S2"
        case .none:          return "—"
        }
    }

    public var isPerNote: Bool { self == .accelPressure || self == .keyY }
    public var isTilt: Bool { self == .tilt1 || self == .tilt2 || self == .tilt3 }
    public var isSlider: Bool { self == .slider1 || self == .slider2 }

    /// The 7 real dimensions (excludes .none).
    public static let real: [InputDimension] = [.tilt1, .tilt2, .tilt3, .accelPressure, .keyY, .slider1, .slider2]
}

/// What a tilt can drive — since the 2026-07-24 PARAMETER UNIFICATION a
/// tilt binds either to a **composite parameter** (a named 0…1 control
/// built from several parameters) or **directly to any single parameter**
/// in `ParamRegistry`. The old `MappableParameter` enum — which was
/// exactly the 8 composite slots — is gone: nothing is mappable-or-not
/// anymore, every parameter is.
///
/// Endpoints are always in the target's NATIVE units: 0…1 for a composite,
/// the parameter's own `lo…hi` for a direct binding (the old 0…127
/// transport units are migrated away on load).
///
/// All Mac-evaluated (the iPad streams only its raw tilt report).
/// Persistence keys on `storageKey`; the composite keys keep their legacy
/// spellings so bindings saved by older builds survive.
public struct MapTarget: Hashable {
    public enum Kind: Hashable {
        case composite(slot: Int)
        case param(key: String)
    }

    public let kind: Kind

    public init(compositeSlot: Int) { kind = .composite(slot: compositeSlot) }
    public init(paramKey: String) { kind = .param(key: paramKey) }
    public init(kind: Kind) { self.kind = kind }

    /// Legacy per-slot storage keys (pre-unification names, kept so saved
    /// mappings deserialize unchanged).
    public static let compositeStorageKeys = [
        "midiCC71", "midiCC73", "midiCC72", "composite4",
        "composite5", "composite6", "composite7", "composite8",
    ]

    public static let paramPrefix = "param:"

    public var storageKey: String {
        switch kind {
        case .composite(let slot):
            return slot < MapTarget.compositeStorageKeys.count
                ? MapTarget.compositeStorageKeys[slot] : "composite\(slot + 1)"
        case .param(let key):
            return MapTarget.paramPrefix + key
        }
    }

    public static func from(storageKey: String) -> MapTarget? {
        if let i = compositeStorageKeys.firstIndex(of: storageKey) {
            return MapTarget(compositeSlot: i)
        }
        if storageKey.hasPrefix(paramPrefix) {
            let key = String(storageKey.dropFirst(paramPrefix.count))
            guard ParamRegistry.spec(key) != nil else { return nil }
            return MapTarget(paramKey: key)
        }
        return nil
    }

    public var compositeSlot: Int? {
        if case .composite(let s) = kind { return s }
        return nil
    }

    public var paramKey: String? {
        if case .param(let k) = kind { return k }
        return nil
    }

    /// Fallback label — for composites the app shows the live name via
    /// `AppController.targetDisplayName`.
    public var label: String {
        switch kind {
        case .composite(let slot): return "Composite \(slot + 1)"
        case .param(let key): return ParamRegistry.spec(key)?.label ?? key
        }
    }

    /// Binding endpoints live in these units.
    public var defaultRange: (Double, Double) {
        switch kind {
        case .composite: return (0, 1)
        case .param(let key):
            guard let s = ParamRegistry.spec(key) else { return (0, 1) }
            return (s.lo, s.hi)
        }
    }

    public var midpointValue: Double {
        let r = defaultRange
        return (r.0 + r.1) / 2.0
    }

    /// Every composite slot, then every parameter — the Add-binding menu's
    /// full candidate list.
    public static func allTargets(compositeSlots: Int = CompositeParam.maxSlots)
        -> [MapTarget] {
        (0..<compositeSlots).map { MapTarget(compositeSlot: $0) }
            + ParamRegistry.all.map { MapTarget(paramKey: $0.key) }
    }
}

// MARK: - Binding Model

/// A control point on a dimension-to-parameter transfer curve.
public struct ControlPoint: Codable, Equatable {
    public var x: Double  // 0..1 normalized input
    public var y: Double  // output in parameter's native units

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One dimension's contribution to a parameter, defined by a piecewise-linear transfer curve.
public struct DimensionBinding: Codable, Equatable {
    public var dimension: InputDimension
    public var controlPoints: [ControlPoint]  // sorted by x, 2-4 points

    public init(dimension: InputDimension, controlPoints: [ControlPoint]) {
        self.dimension = dimension
        self.controlPoints = controlPoints
    }

    /// Convenience initializer for a simple linear mapping.
    public init(dimension: InputDimension, rangeMin: Double, rangeMax: Double) {
        self.dimension = dimension
        self.controlPoints = [ControlPoint(x: 0, y: rangeMin), ControlPoint(x: 1, y: rangeMax)]
    }

    /// Backward-compatible access to the first endpoint.
    public var rangeMin: Double { controlPoints.first?.y ?? 0 }
    /// Backward-compatible access to the last endpoint.
    public var rangeMax: Double { controlPoints.last?.y ?? 0 }

    /// Evaluates the transfer curve at a normalized input value (0..1).
    /// Uses Catmull-Rom spline interpolation for smooth curves through control points.
    public func evaluate(_ normalized: Double) -> Double {
        let n = max(0, min(1, normalized))
        let pts = controlPoints
        guard pts.count >= 2 else { return pts.first?.y ?? 0 }

        // Find the segment containing n
        var seg = 0
        for i in 1..<pts.count {
            if n <= pts[i].x { seg = i - 1; break }
            seg = i - 1
        }

        let p1 = pts[seg]
        let p2 = pts[seg + 1]
        let dx = p2.x - p1.x
        if dx <= 0 { return p1.y }
        let t = (n - p1.x) / dx

        // With only 2 points, use linear interpolation
        if pts.count == 2 { return p1.y + t * (p2.y - p1.y) }

        // Catmull-Rom: use neighboring points (clamp at boundaries)
        let y0 = seg > 0 ? pts[seg - 1].y : p1.y
        let y1 = p1.y
        let y2 = p2.y
        let y3 = seg + 2 < pts.count ? pts[seg + 2].y : p2.y

        let t2 = t * t
        let t3 = t2 * t
        let result = 0.5 * ((2 * y1) +
                             (-y0 + y2) * t +
                             (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2 +
                             (-y0 + 3 * y1 - 3 * y2 + y3) * t3)
        // Clamp to the range defined by the endpoints (first and last point Y)
        let lo = min(pts.first!.y, pts.last!.y)
        let hi = max(pts.first!.y, pts.last!.y)
        return max(lo, min(hi, result))
    }

    /// Backward-compatible migration from old format.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dimension = try container.decode(InputDimension.self, forKey: .dimension)
        if let pts = try? container.decode([ControlPoint].self, forKey: .controlPoints) {
            controlPoints = pts
        } else {
            let rMin = try container.decode(Double.self, forKey: .rangeMin)
            let rMax = try container.decode(Double.self, forKey: .rangeMax)
            controlPoints = [ControlPoint(x: 0, y: rMin), ControlPoint(x: 1, y: rMax)]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case dimension, controlPoints, rangeMin, rangeMax
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dimension, forKey: .dimension)
        try container.encode(controlPoints, forKey: .controlPoints)
    }

    public mutating func sortPoints() {
        controlPoints.sort { $0.x < $1.x }
    }
}

/// All bindings for a single target (many:many support).
public struct ParameterMapping: Codable, Equatable {
    public var bindings: [DimensionBinding]
    /// Value used when no dimension is bound (or all are at midpoint).
    public var defaultValue: Double

    public init(bindings: [DimensionBinding], defaultValue: Double = 0) {
        self.bindings = bindings
        self.defaultValue = defaultValue
    }

    public var isEmpty: Bool { bindings.isEmpty }

    public func hasBinding(for dim: InputDimension) -> Bool {
        bindings.contains { $0.dimension == dim }
    }

    public func binding(for dim: InputDimension) -> DimensionBinding? {
        bindings.first { $0.dimension == dim }
    }

    public mutating func toggleBinding(for dim: InputDimension, defaultRange: (Double, Double)) {
        if let idx = bindings.firstIndex(where: { $0.dimension == dim }) {
            bindings.remove(at: idx)
        } else {
            bindings.append(DimensionBinding(dimension: dim, rangeMin: defaultRange.0, rangeMax: defaultRange.1))
        }
    }

    public mutating func setBinding(for dim: InputDimension, to binding: DimensionBinding) {
        if let idx = bindings.firstIndex(where: { $0.dimension == dim }) {
            bindings[idx] = binding
        }
    }
}

// MARK: - DimensionMapping

/// The complete set of parameter-to-dimension mappings. Persisted via UserDefaults.
public struct DimensionMapping: Codable, Equatable {
    public var mappings: [String: ParameterMapping]

    // MARK: - Defaults

    public static func makeDefault() -> DimensionMapping {
        var m: [String: ParameterMapping] = [:]
        // Default tilt→composite bindings (slots map to the shipped
        // `CompositeParam.defaults()`): the resting device (tilt
        // calibrated-neutral = 0.5 normalized) must keep the default
        // sound. Purity/decay use a 3-point curve that stays 0 through
        // neutral and sweeps past it; tone tilt is linear (neutral ≈ flat);
        // Expression (slot 3) is linear full-throw so rest lands on the
        // fitted median. Endpoints are the composite's native 0…1.
        let restZeroCurve = [ControlPoint(x: 0, y: 0),
                             ControlPoint(x: 0.5, y: 0),
                             ControlPoint(x: 1, y: 1)]
        let defaults: [Int: DimensionBinding] = [
            0: DimensionBinding(dimension: .tilt1, controlPoints: restZeroCurve),
            1: DimensionBinding(dimension: .tilt2, controlPoints: restZeroCurve),
            2: DimensionBinding(dimension: .tilt3, rangeMin: 0, rangeMax: 1),
            3: DimensionBinding(dimension: .tilt1, rangeMin: 0, rangeMax: 1),
        ]
        for slot in 0..<CompositeParam.maxSlots {
            let target = MapTarget(compositeSlot: slot)
            m[target.storageKey] = ParameterMapping(
                bindings: defaults[slot].map { [$0] } ?? [],
                defaultValue: target.midpointValue)
        }
        return DimensionMapping(mappings: m)
    }

    // MARK: - Persistence

    /// v6 = the 2026-07-24 unification: arbitrary targets (composites AND
    /// single parameters) with endpoints in native units. v5 stored only
    /// the 8 composite slots with 0…127 endpoints — migrated on first load.
    private static let storageKey = "starpad_dimensionMapping_v6"
    private static let legacyStorageKey = "starpad_dimensionMapping_v5"

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    public static func load() -> DimensionMapping {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let mapping = try? JSONDecoder().decode(DimensionMapping.self, from: data) {
            return mapping.pruned()
        }
        // Migrate the v5 document: same composite slots, endpoints scaled
        // from the old 0…127 transport units into the composite's 0…1.
        if let data = UserDefaults.standard.data(forKey: legacyStorageKey),
           var mapping = try? JSONDecoder().decode(DimensionMapping.self, from: data) {
            for (key, var pm) in mapping.mappings {
                guard let target = MapTarget.from(storageKey: key),
                      target.compositeSlot != nil else { continue }
                for i in pm.bindings.indices {
                    for j in pm.bindings[i].controlPoints.indices {
                        pm.bindings[i].controlPoints[j].y /= 127.0
                    }
                }
                pm.defaultValue = target.midpointValue
                mapping.mappings[key] = pm
            }
            let migrated = mapping.pruned()
            migrated.save()
            return migrated
        }
        return makeDefault()
    }

    /// Drop entries whose storage key no longer resolves (a parameter that
    /// was renamed or deleted) and fill in any composite slot the saved
    /// document predates.
    private func pruned() -> DimensionMapping {
        var m = mappings.filter { MapTarget.from(storageKey: $0.key) != nil }
        for slot in 0..<CompositeParam.maxSlots {
            let key = MapTarget(compositeSlot: slot).storageKey
            if m[key] == nil {
                m[key] = ParameterMapping(bindings: [], defaultValue: 0.5)
            }
        }
        return DimensionMapping(mappings: m)
    }

    // MARK: - Lookup

    public func mapping(for target: MapTarget) -> ParameterMapping {
        mappings[target.storageKey]
            ?? ParameterMapping(bindings: [], defaultValue: target.midpointValue)
    }

    public func isConnected(_ target: MapTarget, _ dim: InputDimension) -> Bool {
        mapping(for: target).hasBinding(for: dim)
    }

    public mutating func setBinding(for target: MapTarget,
                                    dimension dim: InputDimension,
                                    to binding: DimensionBinding) {
        var m = mapping(for: target)
        m.setBinding(for: dim, to: binding)
        mappings[target.storageKey] = m
    }

    /// All dimensions connected to a given target.
    public func dimensions(for target: MapTarget) -> [InputDimension] {
        mapping(for: target).bindings.map(\.dimension)
    }

    /// Every target that has at least one binding, resolved from the
    /// stored keys (composites first, then parameters in registry order).
    public var boundTargets: [MapTarget] {
        let live = mappings.compactMap { (key, pm) -> MapTarget? in
            pm.bindings.isEmpty ? nil : MapTarget.from(storageKey: key)
        }
        let order = Dictionary(uniqueKeysWithValues:
            MapTarget.allTargets().enumerated().map { ($1.storageKey, $0) })
        return live.sorted {
            (order[$0.storageKey] ?? .max) < (order[$1.storageKey] ?? .max)
        }
    }

    /// All targets driven by a given dimension.
    public func targets(for dim: InputDimension) -> [MapTarget] {
        boundTargets.filter { isConnected($0, dim) }
    }
}

