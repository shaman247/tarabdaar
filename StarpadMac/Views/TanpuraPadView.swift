import StarpadCore
import StarpadDSP
import SwiftUI

/// Tanpura tab: four modeled drone strings with traditional tuning
/// controls, an auto-strum cycle, and fine-grained per-harmonic editing.
///
/// The synthesis model is harmonic-resolved: every string is a set of
/// individually-enveloped harmonics whose peaks are staggered in time (the
/// tanpura's defining behavior). The "Harmonics" editor exposes exactly
/// that: per-harmonic gain, bloom-peak time, and decay trims on top of the
/// smooth laws set in the "Model" section.
struct TanpuraPadView: View {
    @ObservedObject var controller: AppController
    @State private var tuning = TanpuraTuning.load()
    @State private var selectedString = 3
    @State private var trimMode: TrimMode = .gain
    @State private var pressedButton: Int? = nil
    /// One-shot guard for the Reset button: lets it snap `tuning` back to
    /// the measured reference without the tuning `onChange` recomputing
    /// the f0s — the baked defaults carry the matched unison detune,
    /// which a tuning-derived rewrite would erase.
    @State private var suppressTuningF0Write = false

    enum TrimMode: String, CaseIterable {
        case gain = "Gain"
        case peak = "Peak time"
        case decay = "Decay"
    }

    private static let stringRoles = ["Pa", "sa", "sa", "SA"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                toolbar
                stringButtons
                tuningSection
                harmonicsSection
                modelSection
                roomSection
                Text("Click a string to pluck it (keys 1–4). Auto-drone cycles the pattern; Harmonics edits each individual harmonic of the selected string.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Button("") { controller.tanpuraPluck(i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                }
            }
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Toggle("Auto drone", isOn: $controller.tanpuraAutoDrone)
                .toggleStyle(.switch)
            HStack(spacing: 6) {
                Text("Step").font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.tanpuraStepSeconds, in: 0.3...2.0)
                    .frame(width: 120)
                Text(String(format: "%.2fs", controller.tanpuraStepSeconds))
                    .font(.caption).monospacedDigit()
            }
            HStack(spacing: 6) {
                Text("Pattern").font(.caption).foregroundStyle(.secondary)
                TextField("1 2 3 4", text: $controller.tanpuraPattern)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .help("Space-separated string numbers 1–4; '-' is a rest")
            }
            HStack(spacing: 6) {
                Text("Velocity").font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.tanpuraVelocity, in: 0.1...1.0)
                    .frame(width: 110)
            }
            HStack(spacing: 6) {
                Text("Gain").font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.tanpuraGainDB, in: -24...24)
                    .frame(width: 110)
                    .help("Drone output gain, applied after the matched master gain")
                Text(String(format: "%+.0f dB", controller.tanpuraGainDB))
                    .font(.caption).monospacedDigit()
            }
            Spacer()
            Button("Reset") {
                if tuning != .measuredReference {
                    suppressTuningF0Write = true
                    tuning = .measuredReference
                }
                controller.tanpuraParams = TanpuraParams()
            }
            .help("Restore every model parameter to the matched bake (TanpuraParams defaults, including the baked string frequencies) and the tuning to the measured reference")
            Button("Silence") {
                controller.tanpuraAutoDrone = false
                controller.audio.clearTanpuraState()
            }
        }
    }

    // MARK: - Room (shared tanpura + sitar reverb/filter)

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Room (tanpura + sitar)").font(.headline)
            Text("Shared reverb + low-pass filter for the tanpura and sitar. The sarangi has its own per-voice FX (the FX tab) and does not use this.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            roomRow("Reverb mix", $controller.reverbMix, 0...100)
            roomRow("Filter cutoff (Hz)", $controller.filterCutoff, 20...20000)
            roomRow("Filter resonance", $controller.filterResonance, 0...1)
        }
    }

    private func roomRow(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 130, alignment: .leading).font(.caption)
            Slider(value: value, in: range)
            Text(String(format: range.upperBound >= 100 ? "%.0f" : "%.2f", value.wrappedValue))
                .frame(width: 56, alignment: .trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: - String buttons

    private var stringButtons: some View {
        HStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { i in
                stringButton(i)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stringButton(_ i: Int) -> some View {
        let f0 = controller.tanpuraParams.strings[i].f0
        let midi = 69.0 + 12.0 * log2(f0 / 440.0)
        let noteName = Scale.noteName(for: Int(midi.rounded()))
        let isSelected = selectedString == i
        return VStack(spacing: 8) {
            Button {
                pressedButton = i
                controller.tanpuraPluck(i)
                selectedString = i
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if pressedButton == i { pressedButton = nil }
                }
            } label: {
                VStack(spacing: 4) {
                    Text(Self.stringRoles[i])
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                    Text(noteName)
                        .font(.system(.body, design: .monospaced))
                    Text(String(format: "%.2f Hz", f0))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(pressedButton == i
                              ? Color.accentColor.opacity(0.55)
                              : Color(white: isSelected ? 0.24 : 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.accentColor : Color(white: 0.3),
                                lineWidth: isSelected ? 2 : 1)
                )
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Text("Lvl").font(.caption2).foregroundStyle(.secondary)
                Slider(value: paramBinding(\.strings[i].level), in: 0...1.5)
            }
        }
    }

    // MARK: - Tuning

    private var tuningSection: some View {
        section("Tuning") {
            HStack(spacing: 14) {
                Text("Tonic (middle sa)").font(.body)
                Picker("", selection: $tuning.tonicNote) {
                    ForEach(0..<12, id: \.self) { n in
                        Text(TanpuraTuning.noteNames[n]).tag(n)
                    }
                }
                .frame(width: 70)
                Picker("", selection: $tuning.tonicOctave) {
                    ForEach(2...5, id: \.self) { o in Text("\(o)").tag(o) }
                }
                .frame(width: 56)
                HStack(spacing: 6) {
                    Text("trim").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $tuning.tonicCents, in: -50...50)
                        .frame(width: 130)
                    Text(String(format: "%+.1f¢", tuning.tonicCents))
                        .font(.caption).monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Spacer()
                Button("Apply measured reference tuning") {
                    tuning = .measuredReference
                }
                .help("Tonic C4 +4¢, Pa +2¢ — the tuning measured from tanpura.mp3")
            }
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: 12) {
                    Text("String \(i + 1) (\(Self.stringRoles[i]))")
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: $tuning.intervals[i]) {
                        ForEach(TanpuraTuning.Interval.allCases, id: \.self) { iv in
                            Text(iv.label).tag(iv)
                        }
                    }
                    .frame(width: 150)
                    Text("fine").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $tuning.fineCents[i], in: -50...50)
                        .frame(width: 150)
                    Text(String(format: "%+.1f¢", tuning.fineCents[i]))
                        .font(.caption).monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                    Text(String(format: "%.2f Hz", tuning.frequency(of: i)))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                    Spacer()
                }
            }
        }
        .onChange(of: tuning) { newTuning in
            newTuning.save()
            if suppressTuningF0Write {
                suppressTuningF0Write = false
                return
            }
            var p = controller.tanpuraParams
            for i in 0..<4 { p.strings[i].f0 = newTuning.frequency(of: i) }
            controller.tanpuraParams = p
        }
    }

    // MARK: - Harmonics (per-harmonic fine-grained control)

    private var harmonicsSection: some View {
        section("Harmonics — string \(selectedString + 1) (\(Self.stringRoles[selectedString]))") {
            HStack(spacing: 12) {
                Picker("", selection: $selectedString) {
                    ForEach(0..<4, id: \.self) { i in
                        Text("\(i + 1) \(Self.stringRoles[i])").tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Picker("", selection: $trimMode) {
                    ForEach(TrimMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                Button("Reset trims") {
                    var p = controller.tanpuraParams
                    switch trimMode {
                    case .gain: p.strings[selectedString].gainTrimDB = TanpuraParams.neutralGainTrims
                    case .peak: p.strings[selectedString].peakTrim = TanpuraParams.neutralMulTrims
                    case .decay: p.strings[selectedString].decayTrim = TanpuraParams.neutralMulTrims
                    }
                    controller.tanpuraParams = p
                }
            }
            HarmonicBarEditor(
                count: controller.tanpuraParams.harmonicCount,
                values: trimBinding,
                range: trimMode == .gain ? -24...12 : log2(0.125)...log2(8.0),
                neutral: trimMode == .gain ? 0 : 0,
                transform: trimMode == .gain
                    ? .init(toDisplay: { $0 }, fromDisplay: { $0 })
                    : .init(toDisplay: { log2(max(0.05, $0)) }, fromDisplay: { pow(2, $0) }),
                unit: trimMode == .gain ? "dB" : "×"
            )
            .frame(height: 150)
            Text(trimDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var trimDescription: String {
        switch trimMode {
        case .gain: return "Per-harmonic gain trim in dB on top of the falloff/pluck-position law. Drag bars; double-click a bar to reset it."
        case .peak: return "Per-harmonic multiplier on the bloom peak time (when this harmonic's envelope peaks after the pluck). Up = peaks later."
        case .decay: return "Per-harmonic multiplier on the decay time. Up = this harmonic rings longer."
        }
    }

    private var trimBinding: Binding<[Double]> {
        Binding(
            get: {
                let s = controller.tanpuraParams.strings[selectedString]
                switch trimMode {
                case .gain: return s.gainTrimDB
                case .peak: return s.peakTrim
                case .decay: return s.decayTrim
                }
            },
            set: { newValues in
                var p = controller.tanpuraParams
                switch trimMode {
                case .gain: p.strings[selectedString].gainTrimDB = newValues
                case .peak: p.strings[selectedString].peakTrim = newValues
                case .decay: p.strings[selectedString].decayTrim = newValues
                }
                controller.tanpuraParams = p
            }
        )
    }

    // MARK: - Model laws + globals

    private var modelSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                section("String \(selectedString + 1) bloom laws") {
                    rowFree("Spectral falloff", value: paramBinding(\.strings[selectedString].falloff), range: 0...3)
                    rowFree("Pluck position", value: paramBinding(\.strings[selectedString].pluckPos), range: 0.02...0.5)
                    rowFree("Decay (s)", value: paramBinding(\.strings[selectedString].decay), range: 0.2...16)
                    rowFree("Decay tilt", value: paramBinding(\.strings[selectedString].dampTilt), range: 0...2)
                    rowFree("Bloom delay (s)", value: paramBinding(\.strings[selectedString].bloomDelay), range: 0...1.0)
                    rowFree("Bloom skew", value: paramBinding(\.strings[selectedString].bloomSkew), range: 0...1.8)
                    rowFree("Attack level", value: paramBinding(\.strings[selectedString].attackLevel), range: 0...1)
                    rowFree("Attack decay (s)", value: paramBinding(\.strings[selectedString].attackDecay), range: 0.005...0.3)
                    rowFree("Inharmonicity", value: paramBinding(\.strings[selectedString].inharmonicity), range: 0...0.0005)
                    // Jawari period-2 partials at (k+0.5)·f0; −60 = off.
                    rowFree("Sub-partials (dB)", value: paramBinding(\.strings[selectedString].subLevelDB), range: -60 ... -2)
                    rowFree("Sub falloff", value: paramBinding(\.strings[selectedString].subFalloff), range: 0...4)
                    rowFree("Sub knee (h)", value: paramBinding(\.strings[selectedString].subKneeH), range: 1...64)
                }
                section("Life (jiva / drift / variation)") {
                    rowFree("Jiva depth", value: paramBinding(\.jivaDepth), range: 0...0.9)
                    rowFree("Jiva rate (Hz)", value: paramBinding(\.jivaRate), range: 0.05...2.5)
                    rowFree("Jiva mid-harmonic tilt", value: paramBinding(\.jivaTilt), range: 0...1)
                    rowFree("Jiva energy conserve", value: paramBinding(\.jivaConserve), range: 0...1)
                    rowFree("Jiva rate spread", value: paramBinding(\.jivaRateSpread), range: 0...1.5)
                    rowFree("Pitch drift (¢)", value: paramBinding(\.pitchDriftCents), range: 0...8)
                    rowFree("Pitch drift rate (Hz)", value: paramBinding(\.pitchDriftRate), range: 0.01...2)
                    rowFree("Pluck variation (dB)", value: paramBinding(\.pluckVariationDB), range: 0...5)
                    rowFree("Cross-excitation", value: paramBinding(\.crossExcite), range: 0...0.4)
                }
                section("Attack noise") {
                    rowFree("Level", value: paramBinding(\.noiseLevel), range: 0...0.8)
                    rowFree("Decay (s)", value: paramBinding(\.noiseDecay), range: 0.003...0.08)
                    rowFree("Center (Hz)", value: paramBinding(\.noiseFreq), range: 500...7000)
                    rowFree("Q", value: paramBinding(\.noiseQ), range: 0.4...6)
                }
                section("Body & output") {
                    ForEach(0..<3, id: \.self) { b in
                        rowFree("Band \(b + 1) freq (Hz)", value: paramBinding(\.body[b].freq), range: b == 0 ? 70...180 : (b == 1 ? 150...450 : 500...1800))
                        rowFree("Band \(b + 1) gain", value: paramBinding(\.body[b].gain), range: 0...1.4)
                        // High Q = a true ringing body mode (Q 300 @ 300 Hz ≈ 0.3 s ring).
                        rowFree("Band \(b + 1) Q", value: paramBinding(\.body[b].q), range: 1...300)
                    }
                    rowFree("Dry mix", value: paramBinding(\.bodyDry), range: 0...1)
                    rowFree("Tilt (dB @1.5k)", value: paramBinding(\.tiltDB), range: -10...10)
                    rowFree("Pan spread", value: paramBinding(\.panSpread), range: 0...1)
                    rowFree("Master gain", value: paramBinding(\.masterGain), range: 0...0.9)
                }
                section("Room (in-model; −60 = off)") {
                    rowFree("Wet (dB)", value: paramBinding(\.roomWetDB), range: -60 ... -3)
                    rowFree("Decay (s)", value: paramBinding(\.roomDecayS), range: 0.15...2.5)
                    rowFree("Damping", value: paramBinding(\.roomDamp), range: 0...1)
                    rowFree("Predelay (ms)", value: paramBinding(\.roomPredelayMs), range: 0...40)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("MODEL").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    /// Write-through binding into the tanpura params struct (didSet on the
    /// controller pushes to the engine and persists).
    private func paramBinding(_ keyPath: WritableKeyPath<TanpuraParams, Double>) -> Binding<Double> {
        Binding(
            get: { controller.tanpuraParams[keyPath: keyPath] },
            set: { controller.tanpuraParams[keyPath: keyPath] = $0 }
        )
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func rowFree(_ label: String,
                         value: Binding<Double>,
                         range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 180, alignment: .leading)
                .font(.system(.body))
            Slider(value: value, in: range)
                .frame(maxWidth: .infinity)
            Text(String(format: "%.4f", value.wrappedValue))
                .font(.system(.caption))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

// MARK: - Per-harmonic bar editor

/// Draggable bar graph over the harmonics of one string. Drag to set the
/// selected trim per harmonic; double-click a bar to reset it to neutral.
/// `transform` maps between the stored value (e.g. a multiplier) and the
/// linear display value (e.g. log2 of it).
struct HarmonicBarEditor: View {
    struct Transform {
        let toDisplay: (Double) -> Double
        let fromDisplay: (Double) -> Double
    }

    let count: Int
    @Binding var values: [Double]
    let range: ClosedRange<Double>   // display-space range
    let neutral: Double              // display-space neutral line
    let transform: Transform
    let unit: String

    @State private var hoverIndex: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { ctx, size in
                let barW = size.width / CGFloat(max(count, 1))
                let span = range.upperBound - range.lowerBound
                func y(of display: Double) -> CGFloat {
                    let t = (display - range.lowerBound) / span
                    return size.height * (1 - CGFloat(t))
                }
                // Neutral line.
                let ny = y(of: neutral)
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: ny))
                    p.addLine(to: CGPoint(x: size.width, y: ny))
                }, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                for k in 0..<count {
                    let v = k < values.count ? values[k] : neutral
                    let d = min(max(transform.toDisplay(v), range.lowerBound), range.upperBound)
                    let by = y(of: d)
                    let x = CGFloat(k) * barW + 1
                    let rect = CGRect(x: x, y: min(by, ny),
                                      width: barW - 2, height: max(2, abs(by - ny)))
                    let above = d >= neutral
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(hoverIndex == k
                                          ? .accentColor
                                          : (above ? Color.accentColor.opacity(0.65)
                                                   : Color.orange.opacity(0.65))))
                    if k % 4 == 0 {
                        ctx.draw(Text("\(k + 1)").font(.system(size: 8))
                                    .foregroundColor(.gray),
                                 at: CGPoint(x: x + barW / 2, y: size.height - 7))
                    }
                }
                if let hi = hoverIndex, hi < values.count {
                    let label = unit == "dB"
                        ? String(format: "h%d %+.1f dB", hi + 1, values[hi])
                        : String(format: "h%d ×%.2f", hi + 1, values[hi])
                    ctx.draw(Text(label).font(.system(size: 10).monospacedDigit()),
                             at: CGPoint(x: size.width / 2, y: 8))
                }
            }
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let k = barIndex(at: g.location.x, width: w)
                        hoverIndex = k
                        guard k < values.count else { return }
                        let t = 1 - min(max(g.location.y / h, 0), 1)
                        let display = range.lowerBound + (range.upperBound - range.lowerBound) * Double(t)
                        var newValues = values
                        newValues[k] = transform.fromDisplay(display)
                        values = newValues
                    }
                    .onEnded { _ in hoverIndex = nil }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { g in
                        let k = barIndex(at: g.location.x, width: w)
                        guard k < values.count else { return }
                        var newValues = values
                        newValues[k] = transform.fromDisplay(neutral)
                        values = newValues
                    }
            )
        }
    }

    private func barIndex(at x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return min(max(Int(x / (width / CGFloat(max(count, 1)))), 0), count - 1)
    }
}

// MARK: - Tuning model

/// Traditional tanpura tuning: a tonic (middle sa) plus a just-intonation
/// interval per string. Persisted independently of the model params; any
/// change writes the resulting Hz into `tanpuraParams.strings[i].f0`.
struct TanpuraTuning: Codable, Equatable {
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let defaultsKey = "starpad.tanpuraTuning"

    enum Interval: String, Codable, CaseIterable {
        case paBelow, maBelow, niBelow, sa, saBelow

        var label: String {
            switch self {
            case .paBelow: return "Pa below (3/4)"
            case .maBelow: return "Ma below (2/3)"
            case .niBelow: return "Ni below (15/16)"
            case .sa: return "sa (1/1)"
            case .saBelow: return "SA octave (1/2)"
            }
        }

        var ratio: Double {
            switch self {
            case .paBelow: return 3.0 / 4.0
            case .maBelow: return 2.0 / 3.0
            case .niBelow: return 15.0 / 16.0
            case .sa: return 1.0
            case .saBelow: return 0.5
            }
        }
    }

    var tonicNote: Int = 0       // 0 = C
    var tonicOctave: Int = 4     // middle sa = C4
    var tonicCents: Double = 0
    var intervals: [Interval] = [.paBelow, .sa, .sa, .saBelow]
    var fineCents: [Double] = [0, 0, 0, 0]

    /// The tuning measured from tanpura.mp3 by the calibration tool:
    /// tonic C4 +4¢, Pa needs +2.1¢ on top of the just 3/4.
    static var measuredReference: TanpuraTuning {
        var t = TanpuraTuning()
        t.tonicNote = 0
        t.tonicOctave = 4
        t.tonicCents = 4.0
        t.intervals = [.paBelow, .sa, .sa, .saBelow]
        t.fineCents = [2.1, 0, 0, 0]
        return t
    }

    var tonicFrequency: Double {
        let midi = Double(12 * (tonicOctave + 1) + tonicNote)
        return 440 * pow(2, (midi - 69) / 12 + tonicCents / 1200)
    }

    func frequency(of string: Int) -> Double {
        tonicFrequency * intervals[string].ratio * pow(2, fineCents[string] / 1200)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    static func load() -> TanpuraTuning {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let t = try? JSONDecoder().decode(TanpuraTuning.self, from: data) {
            return t
        }
        return .measuredReference
    }
}
