import Foundation
/// The bindable input dimensions. Raw values are Codable by rawValue and
/// persist in saved bindings, so cases are never renumbered or removed —
/// retired cases (`accelPressure`, `keyY`, the sliders) survive so old
/// documents still decode. Live axes: `ControlAxes.bindableDims`.
public enum InputDimension: Int, Codable, CaseIterable, Hashable {
    case tilt1          = 0    // shared tilt up/down
    case tilt2          = 1    // shared tilt in/out
    case tilt3          = 2    // shared tilt rotation
    case accelPressure  = 3
    case keyY           = 4
    case slider1        = 5
    case slider2        = 6
    case tilt4          = 7    // retired wrist up/down; migrates to tilt1
    case stickX         = 8    // retired; migrated to Left/Right
    case stickY         = 9    // retired; migrated to Down/Up
    /// The accelerometer STRIKE/ACCELERATION pair: both ride the iPad's
    /// 0…1 strike-scale envelope (`MotionSource.strikeScale01`, the
    /// PERF_STATE `strike` byte); what separates them is TIME SINCE THE
    /// NOTE STARTED — per target the applied value blends (1−w)·Strike +
    /// w·Acceleration with w ramping 0→1 over the note window
    /// (`StrikeBlendWindow`; an unbound side reads as the target's
    /// default). UNIPOLAR: rest (silence) sits at the curve's LEFT end
    /// (x 0), a hard strike at x 1 — unlike the tilts, whose rest is the
    /// centre. (`accelPressure` above is the retired per-note onset
    /// value; these are live global axes.)
    case strike         = 10
    case acceleration   = 11
    /// FINGER ACCELERATION: the SIGNED second derivative of the newest
    /// sounding touch's pitch trajectory, soft-saturated to −1…+1
    /// (`FingerAccelTracker`, ±1 half-way at 25 000 ¢/s²; up = +).
    /// BIPOLAR like the tilts: rest / constant-rate meend = 0 = curve
    /// centre. Mac-evaluated from the wire pitch stream; the iPad's
    /// toolbar scope runs its own display-only copy of the law.
    case fingerAccel    = 12
    // Retired wrist dimensions, retained for saved-binding migration.
    case wrist2         = 13
    case wrist3         = 14
    /// JOY-CON ACCELERATION: the Joy-Con's gravity-removed acceleration
    /// magnitude through the iPad strike law (`StrikeLaw`: log-scale 0…1 +
    /// fast-attack/150 ms-decay envelope). UNIPOLAR like `.acceleration`
    /// — rest reads at the curve's LEFT end (x 0).
    case jcAccel        = 15
    /// TOUCH SIZE: the newest sounding touch's fingertip contact radius
    /// (`UITouch.majorRadius`, the PERF_STATE `radius` byte) mapped
    /// 31.3 → 73.0 pt onto 0…1 through `TouchSizeTracker`'s finger
    /// estimate — normal playing rests near 0, a deliberately flattened
    /// fingertip sweeps the range. UNIPOLAR like `.strike`:
    /// rest is the curve's LEFT end (x 0), so a binding reads its first
    /// offset with the finger relaxed. Mac-evaluated from the wire radius
    /// stream; the iPad's touch ring draws its own display-only copy.
    case touchSize      = 16
    case stickLeft      = 17
    case stickRight     = 18
    case stickUp        = 19
    case stickDown      = 20
    /// Finger position along the fret: inner end 0, outer end 1.
    case fretPosition   = 21
    case none           = -1

    public var label: String {
        switch self {
        case .tilt1:         return "Tilt ↕"
        case .tilt2:         return "Tilt ↔"
        case .tilt3:         return "Tilt ⟲"
        case .tilt4:         return "Wrist ↕"
        case .wrist2:        return "Wrist ↔"
        case .wrist3:        return "Wrist ⟲"
        case .jcAccel:       return "Joy-Con Accel"
        case .stickX:        return "Stick X"
        case .stickY:        return "Stick Y"
        case .stickLeft:     return "Stick Left"
        case .stickRight:    return "Stick Right"
        case .stickUp:       return "Stick Up"
        case .stickDown:     return "Stick Down"
        case .strike:        return "Strike"
        case .acceleration:  return "Acceleration"
        case .fingerAccel:   return "Finger Accel"
        case .touchSize:     return "Touch Size"
        case .fretPosition:  return "Fret Position"
        case .accelPressure: return "Pressure"
        case .keyY:          return "Key Y"
        case .slider1:       return "Slider 1"
        case .slider2:       return "Slider 2"
        case .none:          return "None"
        }
    }

    /// Where the axis RESTS in the curve's 0…1 domain — also the reference
    /// for legacy bindings without an explicit offset origin. The
    /// bipolar axes (tilts, wrist, stick, finger accel) rest at the
    /// centre; the unipolar ones (the strike pair, Joy-Con accel, touch
    /// size) rest at the left end, silence.
    public var restX: Double {
        switch self {
        case .strike, .acceleration, .jcAccel, .touchSize, .fretPosition: return 0.0
        case .stickLeft, .stickRight, .stickUp, .stickDown: return 0.0
        default: return 0.5
        }
    }

    /// Short label for matrix column/row headers.
    public var shortLabel: String {
        switch self {
        case .tilt1:         return "T↕"
        case .tilt2:         return "T↔"
        case .tilt3:         return "T⟲"
        case .tilt4:         return "W↕"
        case .wrist2:        return "W↔"
        case .wrist3:        return "W⟲"
        case .jcAccel:       return "JA"
        case .stickX:        return "SX"
        case .stickY:        return "SY"
        case .stickLeft:     return "S←"
        case .stickRight:    return "S→"
        case .stickUp:       return "S↑"
        case .stickDown:     return "S↓"
        case .strike:        return "St"
        case .acceleration:  return "Ac"
        case .fingerAccel:   return "FA"
        case .touchSize:     return "TS"
        case .fretPosition:  return "FP"
        case .accelPressure: return "Pr"
        case .keyY:          return "Y"
        case .slider1:       return "S1"
        case .slider2:       return "S2"
        case .none:          return "—"
        }
    }
}

/// What a control axis can drive: a **composite parameter** (a named 0…1
/// control built from several parameters) or **any single parameter** in
/// `ParamRegistry` directly.
///
/// Endpoints are always in the target's NATIVE units: 0…1 for a
/// composite, the parameter's own `lo…hi` for a direct binding.
///
/// All Mac-evaluated (the iPad streams only its raw sensor report).
/// Persistence keys on `storageKey`; the composite keys keep their legacy
/// spellings so saved bindings survive.
public struct MapTarget: Hashable {
    public enum Kind: Hashable {
        case composite(slot: Int)
        case param(key: String)
    }

    public let kind: Kind

    public init(compositeSlot: Int) { kind = .composite(slot: compositeSlot) }
    public init(paramKey: String) { kind = .param(key: paramKey) }
    public init(kind: Kind) { self.kind = kind }

    /// Legacy per-slot storage keys (kept so saved
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
        case .param(let key): return ParamRegistry.spec(key)?.qualifiedLabel ?? key
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
/// `x` is the PERSISTED curve domain, 0…1 — the live axis value is
/// −1…+1 (rest 0) and callers map it to this domain ((v+1)/2) before
/// evaluating.
public struct ControlPoint: Codable, Equatable {
    public var x: Double  // 0..1 normalized input (axis −1…+1 ↔ x 0…1)
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
    // A migrated stick direction evaluates one half of its original spline.
    // Retaining the original points preserves curved mappings exactly.
    private var inputStart: Double = 0
    private var inputEnd: Double = 1
    // Explicit offset edits keep a fixed reference; older curves retain
    // their original rest-relative evaluation until edited.
    private var offsetOrigin: Double?

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
        let x = max(0, min(1, normalized))
        let n = inputStart + x * (inputEnd - inputStart)
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
        // Include the resting anchor when both endpoint offsets have the same sign.
        let lo = pts.map(\.y).min()!
        let hi = pts.map(\.y).max()!
        return max(lo, min(hi, result))
    }

    /// The binding's offset from the target's base at curve x. Legacy
    /// curves subtract their rest reading; edited curves use a fixed origin.
    public func swing(atX x: Double) -> Double {
        evaluate(x) - (offsetOrigin ?? evaluate(dimension.restX))
    }

    /// Edit both offsets independently; only bipolar curves anchor zero at centre.
    public func withOffsets(lo: Double, hi: Double) -> DimensionBinding {
        let origin = offsetOrigin ?? evaluate(dimension.restX)
        var points = [ControlPoint(x: 0, y: origin + lo)]
        if dimension.restX != 0 {
            points.append(ControlPoint(x: dimension.restX, y: origin))
        }
        points.append(ControlPoint(x: 1, y: origin + hi))
        var edited = DimensionBinding(dimension: dimension, controlPoints: points)
        edited.offsetOrigin = origin
        return edited
    }

    fileprivate func stickHalf(_ direction: InputDimension, end: Double) -> DimensionBinding {
        var half = self
        half.dimension = direction
        half.inputStart = inputStart + 0.5 * (inputEnd - inputStart)
        half.inputEnd = inputStart + end * (inputEnd - inputStart)
        return half
    }

    /// Backward-compatible migration from old format.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dimension = try container.decode(InputDimension.self, forKey: .dimension)
        inputStart = try container.decodeIfPresent(Double.self, forKey: .inputStart) ?? 0
        inputEnd = try container.decodeIfPresent(Double.self, forKey: .inputEnd) ?? 1
        offsetOrigin = try container.decodeIfPresent(Double.self, forKey: .offsetOrigin)
        if let pts = try? container.decode([ControlPoint].self, forKey: .controlPoints) {
            controlPoints = pts
        } else {
            let rMin = try container.decode(Double.self, forKey: .rangeMin)
            let rMax = try container.decode(Double.self, forKey: .rangeMax)
            controlPoints = [ControlPoint(x: 0, y: rMin), ControlPoint(x: 1, y: rMax)]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case dimension, controlPoints, rangeMin, rangeMax, inputStart, inputEnd, offsetOrigin
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dimension, forKey: .dimension)
        try container.encode(controlPoints, forKey: .controlPoints)
        try container.encodeIfPresent(offsetOrigin, forKey: .offsetOrigin)
        if inputStart != 0 || inputEnd != 1 {
            try container.encode(inputStart, forKey: .inputStart)
            try container.encode(inputEnd, forKey: .inputEnd)
        }
    }
}

/// All bindings for a single target. Many dimensions may bind one
/// target: each contributes its SWING about the target's resting value
/// (`DimensionBinding.swing`) and the swings add —
/// `value = rest + Σ swing_i`, clamped to the target's range
/// (`ControlAxisEvaluator`). Two axes on one target therefore never fight;
/// a one-way axis at zero input contributes its first edited offset.
public struct ParameterMapping: Codable, Equatable {
    public var bindings: [DimensionBinding]
    /// The base value for a COMPOSITE target, before binding offsets,
    /// editable in the Controls tab. A parameter
    /// target's rest is its resting store value (the Parameters tab knob),
    /// not this field.
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

    public init(mappings: [String: ParameterMapping]) {
        self.mappings = Self.unifyTiltBindings(Self.splitStickBindings(mappings))
    }

    /// Prefer the primary wrist curve when an old target bound both devices.
    private static func unifyTiltBindings(_ mappings: [String: ParameterMapping])
        -> [String: ParameterMapping] {
        mappings.mapValues { pm in
            var result = pm
            for (legacy, shared) in [(InputDimension.tilt4, InputDimension.tilt1),
                                     (.wrist2, .tilt2), (.wrist3, .tilt3)] {
                guard var binding = pm.binding(for: legacy) else { continue }
                binding.dimension = shared
                result.bindings.removeAll { $0.dimension == legacy || $0.dimension == shared }
                result.bindings.append(binding)
            }
            return result
        }
    }

    private static func splitStickBindings(_ mappings: [String: ParameterMapping])
        -> [String: ParameterMapping] {
        mappings.mapValues { pm in
            var result = pm
            result.bindings.removeAll { $0.dimension == .stickX || $0.dimension == .stickY }
            for binding in pm.bindings {
                let directions: [(InputDimension, Double)]
                switch binding.dimension {
                case .stickX: directions = [(.stickLeft, 0), (.stickRight, 1)]
                case .stickY: directions = [(.stickDown, 0), (.stickUp, 1)]
                default: continue
                }
                for (direction, end) in directions where !result.hasBinding(for: direction) {
                    result.bindings.append(binding.stickHalf(direction, end: end))
                }
            }
            return result
        }
    }

    // MARK: - Defaults

    public static func makeDefault() -> DimensionMapping {
        var m: [String: ParameterMapping] = [:]
        // Default tilt→composite bindings (slots map to the shipped
        // `CompositeParam.defaults()`): the resting device (tilt
        // calibrated-neutral = axis 0 = curve x 0.5) must keep the
        // default sound. Purity/decay use a 3-point curve that stays 0 through
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
            let bindings = defaults[slot].map { [$0] } ?? []
            // The composite's rest is what its default curve reads with
            // the axis at rest (0 for the rest-zero shapes, 0.5 linear).
            m[target.storageKey] = ParameterMapping(
                bindings: bindings,
                defaultValue: defaults[slot].map(Self.restOfFirstCurve)
                    ?? target.midpointValue)
        }
        // The strum-expression default binding is seeded by `pruned()`
        // (shared with the existing-install path).
        return DimensionMapping(mappings: m).pruned()
    }

    // MARK: - Persistence

    /// v6: arbitrary targets (composites AND single parameters) with
    /// endpoints in native units.
    private static let storageKey = "tarabdaar_dimensionMapping_v6"

    /// A binding's value with its axis at rest.
    static func restOfFirstCurve(_ b: DimensionBinding) -> Double {
        b.evaluate(b.dimension.restX)
    }

    private enum CodingKeys: String, CodingKey {
        case mappings
        /// Present (1) once the document's composite rests are
        /// authoritative. A document without it predates the swing law:
        /// its curves were applied ABSOLUTELY, so each bound target's rest
        /// is what its first curve read with the axis at rest — adopting
        /// that keeps every old preset bit-identical at rest and under one
        /// axis.
        case restLaw
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var m = try c.decode([String: ParameterMapping].self, forKey: .mappings)
        if (try c.decodeIfPresent(Int.self, forKey: .restLaw)) == nil {
            for (key, var pm) in m {
                if let first = pm.bindings.first {
                    pm.defaultValue = Self.restOfFirstCurve(first)
                    m[key] = pm
                }
            }
        }
        mappings = Self.unifyTiltBindings(Self.splitStickBindings(m))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mappings, forKey: .mappings)
        try c.encode(1, forKey: .restLaw)
    }

    public func save() {
        DefaultsStore.save(self, key: Self.storageKey)
    }

    public static func load() -> DimensionMapping {
        if let mapping = DefaultsStore.load(DimensionMapping.self, key: storageKey) {
            return mapping.pruned()
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
        // The controller strum's expression ships bound to the Joy-Con
        // Up/Down directions: split the original full-throw Y curve so its
        // offsets are preserved. Seeded only when the key is ENTIRELY absent; an
        // entry the user emptied persists as an empty mapping.
        let strumKey = MapTarget(paramKey: "ctl_strum_expr").storageKey
        if m[strumKey] == nil {
            m[strumKey] = ParameterMapping(
                bindings: [DimensionBinding(dimension: .stickY,
                                            rangeMin: 0, rangeMax: 1)],
                defaultValue: 1.0)
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

    /// Set a composite target's resting value (the Controls tab's Rest
    /// slider); no-op for a parameter target, whose rest is its store value.
    public mutating func setRest(for target: MapTarget, _ rest: Double) {
        guard target.compositeSlot != nil else { return }
        var m = mapping(for: target)
        m.defaultValue = rest
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
