import Foundation

/// An input dimension that can drive a mappable parameter.
///
/// Dimensions 1-3 are **global** (same value for all voices).
/// Dimensions 4-5 are **per-note** (each voice has its own value).
/// Dimensions 6-7 are **global** (slider panels in UI).
enum Dimension: Int, Codable, CaseIterable, Hashable {
    case tilt1          = 0
    case tilt2          = 1
    case tilt3          = 2
    case accelPressure  = 3
    case keyY           = 4
    case slider1        = 5
    case slider2        = 6
    case none           = -1

    var label: String {
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
    var shortLabel: String {
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

    var isPerNote: Bool { self == .accelPressure || self == .keyY }
    var isTilt: Bool { self == .tilt1 || self == .tilt2 || self == .tilt3 }
    var isSlider: Bool { self == .slider1 || self == .slider2 }

    /// The 7 real dimensions (excludes .none).
    static let real: [Dimension] = [.tilt1, .tilt2, .tilt3, .accelPressure, .keyY, .slider1, .slider2]
}

/// Identifies each mappable parameter.
enum MappableParameter: Int, Codable, CaseIterable, Hashable {
    case velocity         = 0
    case glideSpeed       = 1
    case glideCompression = 2
    case amplitude        = 3
    case vibratoDepth     = 4
    case vibratoRate      = 5
    case vibratoIntensity = 6
    case dragSmoothing    = 7
    case glideCurve       = 8
    case aftertouch       = 9
    case midiCC74         = 10
    case midiCC1          = 11
    case midiCC11         = 12
    case midiCC71         = 13
    case midiCC73         = 14
    case midiCC75         = 15

    static let count = 16

    /// Display order for the mapping panel, grouped by category.
    static let displayOrder: [(group: String, params: [MappableParameter])] = [
        ("MIDI / Volume", [.velocity, .amplitude, .aftertouch, .midiCC74, .midiCC1, .midiCC11, .midiCC71, .midiCC73, .midiCC75]),
        ("Glide", [.glideSpeed, .glideCompression, .glideCurve, .dragSmoothing]),
        ("Vibrato", [.vibratoDepth, .vibratoRate, .vibratoIntensity]),
    ]

    var storageKey: String {
        switch self {
        case .velocity:         return "velocity"
        case .glideSpeed:       return "glideSpeed"
        case .glideCompression: return "glideCompression"
        case .amplitude:        return "amplitude"
        case .vibratoDepth:     return "vibratoDepth"
        case .vibratoRate:      return "vibratoRate"
        case .vibratoIntensity: return "vibratoIntensity"
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

    var label: String {
        switch self {
        case .velocity:         return "Velocity"
        case .glideSpeed:       return "Glide Speed"
        case .glideCompression: return "Compression"
        case .amplitude:        return "Amplitude"
        case .vibratoDepth:     return "Vib Depth"
        case .vibratoRate:      return "Vib Rate"
        case .vibratoIntensity: return "Vib Intensity"
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
    var shortLabel: String {
        switch self {
        case .velocity:         return "Vel"
        case .glideSpeed:       return "Gld"
        case .glideCompression: return "Cmp"
        case .amplitude:        return "Amp"
        case .vibratoDepth:     return "VbD"
        case .vibratoRate:      return "VbR"
        case .vibratoIntensity: return "VbI"
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

    var detail: String? {
        switch self {
        case .velocity:         return "MIDI note-on velocity, set once when the note fires"
        case .glideSpeed:       return "How long pitch takes to glide between notes"
        case .glideCompression: return "How quickly queued notes interrupt the current glide"
        case .amplitude:        return "Volume multiplier applied to each note"
        case .vibratoDepth:     return "Max pitch wobble at full vibrato intensity"
        case .vibratoRate:      return "Speed of the vibrato wobble"
        case .vibratoIntensity: return "How much vibrato is applied (default: Key Y, top = max)"
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

    var unit: String {
        switch self {
        case .glideSpeed:       return "ms/st"
        case .glideCompression: return "ms"
        case .amplitude:        return "x"
        case .vibratoDepth:     return "st"
        case .vibratoRate:      return "Hz"
        default:                return ""
        }
    }

    var midiCC: UInt8? {
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

    var isMIDI: Bool { midiCC != nil || self == .aftertouch }

    /// True if this parameter's value is always used even when no dimension is bound.
    /// MIDI parameters (CCs and aftertouch) are only sent when bound; all others always have an active value.
    var defaultAlwaysActive: Bool { !isMIDI }

    var defaultRange: (Double, Double) {
        switch self {
        case .velocity:         return (1, 127)
        case .glideSpeed:       return (20, 200)
        case .glideCompression: return (15, 40)
        case .amplitude:        return (0.3, 1.5)
        case .vibratoDepth:     return (0, 0.5)
        case .vibratoRate:      return (4, 10)
        case .vibratoIntensity: return (0, 1)
        case .dragSmoothing:    return (0.1, 0.5)
        case .glideCurve:       return (3, 12)
        default:                return (0, 127)
        }
    }

    /// Midpoint value when no dimension is bound.
    var midpointValue: Double {
        let r = defaultRange
        return (r.0 + r.1) / 2.0
    }
}

// MARK: - Binding Model

/// A control point on a dimension-to-parameter transfer curve.
struct ControlPoint: Codable, Equatable {
    var x: Double  // 0..1 normalized input
    var y: Double  // output in parameter's native units
}

/// One dimension's contribution to a parameter, defined by a piecewise-linear transfer curve.
struct DimensionBinding: Codable, Equatable {
    var dimension: Dimension
    var controlPoints: [ControlPoint]  // sorted by x, 2-4 points

    /// Convenience initializer for a simple linear mapping.
    init(dimension: Dimension, rangeMin: Double, rangeMax: Double) {
        self.dimension = dimension
        self.controlPoints = [ControlPoint(x: 0, y: rangeMin), ControlPoint(x: 1, y: rangeMax)]
    }

    /// Backward-compatible access to the first endpoint.
    var rangeMin: Double { controlPoints.first?.y ?? 0 }
    /// Backward-compatible access to the last endpoint.
    var rangeMax: Double { controlPoints.last?.y ?? 0 }

    /// Evaluates the transfer curve at a normalized input value (0..1).
    /// Uses Catmull-Rom spline interpolation for smooth curves through control points.
    func evaluate(_ normalized: Double) -> Double {
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
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dimension = try container.decode(Dimension.self, forKey: .dimension)
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dimension, forKey: .dimension)
        try container.encode(controlPoints, forKey: .controlPoints)
    }

    mutating func sortPoints() {
        controlPoints.sort { $0.x < $1.x }
    }
}

/// All bindings for a single parameter (many:many support).
struct ParameterMapping: Codable, Equatable {
    var bindings: [DimensionBinding]
    /// Value used when no dimension is bound (or all are at midpoint).
    var defaultValue: Double

    var isEmpty: Bool { bindings.isEmpty }

    func hasBinding(for dim: Dimension) -> Bool {
        bindings.contains { $0.dimension == dim }
    }

    func binding(for dim: Dimension) -> DimensionBinding? {
        bindings.first { $0.dimension == dim }
    }

    mutating func toggleBinding(for dim: Dimension, defaultRange: (Double, Double)) {
        if let idx = bindings.firstIndex(where: { $0.dimension == dim }) {
            bindings.remove(at: idx)
        } else {
            bindings.append(DimensionBinding(dimension: dim, rangeMin: defaultRange.0, rangeMax: defaultRange.1))
        }
    }

    mutating func setBinding(for dim: Dimension, to binding: DimensionBinding) {
        if let idx = bindings.firstIndex(where: { $0.dimension == dim }) {
            bindings[idx] = binding
        }
    }
}

// MARK: - DimensionMapping

/// The complete set of parameter-to-dimension mappings. Persisted via UserDefaults.
struct DimensionMapping: Codable, Equatable {
    var mappings: [String: ParameterMapping]

    // MARK: - Defaults

    static func makeDefault() -> DimensionMapping {
        var m: [String: ParameterMapping] = [:]
        for param in MappableParameter.allCases {
            let range = param.defaultRange
            let dims: [Dimension]
            switch param {
            case .glideSpeed, .glideCompression, .amplitude, .aftertouch:
                dims = [.tilt1]
            case .velocity:
                dims = [.accelPressure]
            case .vibratoIntensity:
                dims = [.keyY]
            default:
                dims = []
            }
            let bindings = dims.map { DimensionBinding(dimension: $0, rangeMin: range.0, rangeMax: range.1) }
            m[param.storageKey] = ParameterMapping(bindings: bindings, defaultValue: param.midpointValue)
        }
        return DimensionMapping(mappings: m)
    }

    // MARK: - Persistence

    private static let storageKey = "armpad_dimensionMapping_v5"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func load() -> DimensionMapping {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           var mapping = try? JSONDecoder().decode(DimensionMapping.self, from: data) {
            let defaults = makeDefault()
            for param in MappableParameter.allCases {
                if mapping.mappings[param.storageKey] == nil {
                    mapping.mappings[param.storageKey] = defaults.mapping(for: param)
                }
            }
            return mapping
        }
        return makeDefault()
    }

    // MARK: - Lookup

    func mapping(for param: MappableParameter) -> ParameterMapping {
        mappings[param.storageKey] ?? ParameterMapping(bindings: [], defaultValue: param.midpointValue)
    }

    func isConnected(_ param: MappableParameter, _ dim: Dimension) -> Bool {
        mapping(for: param).hasBinding(for: dim)
    }

    mutating func toggleBinding(for param: MappableParameter, dimension dim: Dimension) {
        var m = mapping(for: param)
        m.toggleBinding(for: dim, defaultRange: param.defaultRange)
        mappings[param.storageKey] = m
    }

    mutating func setBinding(for param: MappableParameter, dimension dim: Dimension, to binding: DimensionBinding) {
        var m = mapping(for: param)
        m.setBinding(for: dim, to: binding)
        mappings[param.storageKey] = m
    }

    /// All dimensions connected to a given parameter.
    func dimensions(for param: MappableParameter) -> [Dimension] {
        mapping(for: param).bindings.map(\.dimension)
    }

    /// All parameters connected to a given dimension.
    func parameters(for dim: Dimension) -> [MappableParameter] {
        MappableParameter.allCases.filter { isConnected($0, dim) }
    }
}
