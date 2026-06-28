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

/// Identifies each mappable parameter.
public enum MappableParameter: Int, Codable, CaseIterable, Hashable {
    // The iPad owns only MIDI / Glide parameters now; everything
    // voice/sym/FX-related lives on the Mac as direct AppController
    // state. Raw values must stay contiguous from 0 — the per-tick
    // lookup caches (`cachedBindings`/`cachedDefaults`) are indexed by
    // `rawValue` but built in `allCases` order. Persistence keys on
    // `storageKey` (string), so unknown keys from older builds — incl.
    // the removed vibrato params — deserialize and are silently dropped.
    case velocity         = 0
    case glideSpeed       = 1
    case glideCompression = 2
    case amplitude        = 3
    case dragSmoothing    = 4
    case glideCurve       = 5
    case aftertouch       = 6
    case midiCC74         = 7
    case midiCC1          = 8
    case midiCC11         = 9
    case midiCC71         = 10
    case midiCC73         = 11
    case midiCC75         = 12

    public static let count = 13

    /// Display order for the mapping panel, grouped by category.
    public static let displayOrder: [(group: String, params: [MappableParameter])] = [
        ("MIDI / Volume", [.velocity, .amplitude, .aftertouch, .midiCC74, .midiCC1, .midiCC11, .midiCC71, .midiCC73, .midiCC75]),
        ("Glide", [.glideSpeed, .glideCompression, .glideCurve, .dragSmoothing]),
    ]

    public var storageKey: String {
        switch self {
        case .velocity:         return "velocity"
        case .glideSpeed:       return "glideSpeed"
        case .glideCompression: return "glideCompression"
        case .amplitude:        return "amplitude"
        case .dragSmoothing:    return "dragSmoothing"
        case .glideCurve:       return "glideCurve"
        case .aftertouch:       return "aftertouch"
        case .midiCC74:         return "midiCC74"
        case .midiCC1:          return "midiCC1"
        case .midiCC11:         return "midiCC11"
        case .midiCC71:         return "midiCC71"
        case .midiCC73:         return "midiCC73"
        case .midiCC75:         return "midiCC75"
        }
    }

    public var label: String {
        switch self {
        case .velocity:         return "Velocity"
        case .glideSpeed:       return "Glide Speed"
        case .glideCompression: return "Compression"
        case .amplitude:        return "Amplitude"
        case .dragSmoothing:    return "Drag Smooth"
        case .glideCurve:       return "Glide Curve"
        case .aftertouch:       return "Aftertouch"
        case .midiCC74:         return "CC74 Slide"
        case .midiCC1:          return "CC1 Modwheel"
        case .midiCC11:         return "CC11 Expression"
        case .midiCC71:         return "CC71 Resonance"
        case .midiCC73:         return "CC73 Attack"
        case .midiCC75:         return "CC75 Decay"
        }
    }

    /// Short label for matrix headers.
    public var shortLabel: String {
        switch self {
        case .velocity:         return "Vel"
        case .glideSpeed:       return "Gld"
        case .glideCompression: return "Cmp"
        case .amplitude:        return "Amp"
        case .dragSmoothing:    return "DrS"
        case .glideCurve:       return "GlC"
        case .aftertouch:       return "AT"
        case .midiCC74:         return "C74"
        case .midiCC1:          return "C1"
        case .midiCC11:         return "C11"
        case .midiCC71:         return "C71"
        case .midiCC73:         return "C73"
        case .midiCC75:         return "C75"
        }
    }

    public var detail: String? {
        switch self {
        case .velocity:         return "MIDI note-on velocity, set once when the note fires"
        case .glideSpeed:       return "How long pitch takes to glide between notes"
        case .glideCompression: return "How quickly queued notes interrupt the current glide"
        case .amplitude:        return "Volume multiplier applied to each note"
        case .dragSmoothing:    return "How tightly pitch follows your finger during drag"
        case .glideCurve:       return "Shape of the glide: low = linear, high = sharp S-curve"
        case .aftertouch:       return "MIDI channel pressure, continuous per voice"
        case .midiCC74:         return "MPE Slide — mapped to filter cutoff in most synths"
        case .midiCC1:          return nil
        case .midiCC11:         return "Secondary volume/dynamics control"
        case .midiCC71:         return nil
        case .midiCC73:         return nil
        case .midiCC75:         return nil
        }
    }

    public var unit: String {
        switch self {
        case .glideSpeed:       return "ms/st"
        case .glideCompression: return "ms"
        case .amplitude:        return "x"
        default:                return ""
        }
    }

    public var midiCC: UInt8? {
        switch self {
        case .midiCC74: return 74
        case .midiCC1:  return 1
        case .midiCC11: return 11
        case .midiCC71: return 71
        case .midiCC73: return 73
        case .midiCC75: return 75
        default:        return nil
        }
    }

    public var isMIDI: Bool { midiCC != nil || self == .aftertouch }

    /// True if this parameter's value is always used even when no dimension is bound.
    /// MIDI parameters (CCs and aftertouch) are only sent when bound; all others always have an active value.
    public var defaultAlwaysActive: Bool { !isMIDI }

    public var defaultRange: (Double, Double) {
        switch self {
        case .velocity:         return (1, 127)
        case .glideSpeed:       return (20, 200)
        case .glideCompression: return (15, 40)
        case .amplitude:        return (0.3, 1.5)
        case .dragSmoothing:    return (0.1, 0.5)
        case .glideCurve:       return (3, 12)
        case .aftertouch, .midiCC74, .midiCC1, .midiCC11, .midiCC71, .midiCC73, .midiCC75:
            return (0, 127)
        }
    }

    /// Default value when no dimension is bound. Geometric midpoint of
    /// `defaultRange` for every surviving param.
    public var midpointValue: Double {
        let r = defaultRange
        return (r.0 + r.1) / 2.0
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

/// All bindings for a single parameter (many:many support).
public struct ParameterMapping: Codable, Equatable {
    public var bindings: [DimensionBinding]
    /// Value used when no dimension is bound (or all are at midpoint).
    public var defaultValue: Double

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
        for param in MappableParameter.allCases {
            let range = param.defaultRange
            let dims: [InputDimension]
            switch param {
            case .glideSpeed, .glideCompression, .amplitude, .aftertouch:
                dims = [.tilt1]
            case .velocity:
                dims = [.accelPressure]
            default:
                dims = []
            }
            let bindings = dims.map { DimensionBinding(dimension: $0, rangeMin: range.0, rangeMax: range.1) }
            m[param.storageKey] = ParameterMapping(bindings: bindings, defaultValue: param.midpointValue)
        }
        return DimensionMapping(mappings: m)
    }

    // MARK: - Persistence

    private static let storageKey = "starpad_dimensionMapping_v5"

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    public static func load() -> DimensionMapping {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           var mapping = try? JSONDecoder().decode(DimensionMapping.self, from: data) {
            let defaults = makeDefault()
            for param in MappableParameter.allCases {
                if var existing = mapping.mappings[param.storageKey] {
                    // Refresh defaultValue from code for any param the user has
                    // not bound — catches changes like resonance midpoint moving
                    // from the geometric midpoint to 0 (opt-in).
                    if existing.bindings.isEmpty {
                        existing.defaultValue = param.midpointValue
                        mapping.mappings[param.storageKey] = existing
                    }
                } else {
                    mapping.mappings[param.storageKey] = defaults.mapping(for: param)
                }
            }
            return mapping
        }
        return makeDefault()
    }

    // MARK: - Lookup

    public func mapping(for param: MappableParameter) -> ParameterMapping {
        mappings[param.storageKey] ?? ParameterMapping(bindings: [], defaultValue: param.midpointValue)
    }

    public func isConnected(_ param: MappableParameter, _ dim: InputDimension) -> Bool {
        mapping(for: param).hasBinding(for: dim)
    }

    public mutating func toggleBinding(for param: MappableParameter, dimension dim: InputDimension) {
        var m = mapping(for: param)
        m.toggleBinding(for: dim, defaultRange: param.defaultRange)
        mappings[param.storageKey] = m
    }

    public mutating func setBinding(for param: MappableParameter, dimension dim: InputDimension, to binding: DimensionBinding) {
        var m = mapping(for: param)
        m.setBinding(for: dim, to: binding)
        mappings[param.storageKey] = m
    }

    /// All dimensions connected to a given parameter.
    public func dimensions(for param: MappableParameter) -> [InputDimension] {
        mapping(for: param).bindings.map(\.dimension)
    }

    /// All parameters connected to a given dimension.
    public func parameters(for dim: InputDimension) -> [MappableParameter] {
        MappableParameter.allCases.filter { isConnected($0, dim) }
    }
}

