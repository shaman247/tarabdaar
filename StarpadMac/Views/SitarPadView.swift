import StarpadCore
import StarpadDSP
import SwiftUI

/// Sitar tab: a single plucked voice built from the SAME harmonic-resolved
/// string model as the tanpura (`TanpuraParams`/`TanpuraModel`), fitted to
/// `sitar1.wav` (three C#4 plucks) and baked into `TanpuraParams.sitar`.
/// The fit is ONE pitch-invariant timbre — its eventual home is the
/// sympathetic-string layer — so the tab plays string 0, retuning it per
/// pluck across a one-octave scale from the matched Sa (280.4 Hz, C#4 +20¢).
///
/// The "Harmonics" editor and "Model" disclosure expose the same controls
/// as the Tanpura tab so the matched voice can be auditioned and refined.
struct SitarPadView: View {
    @ObservedObject var controller: AppController
    @State private var trimMode: TrimMode = .gain
    @State private var pressed: Int? = nil

    enum TrimMode: String, CaseIterable {
        case gain = "Gain"
        case peak = "Peak time"
        case decay = "Decay"
    }

    /// The matched tonic (sitar Sa): C#4 +20¢ measured from `sitar1.wav`.
    private static let saF0 = 280.4
    /// One octave of 12-TET pads from Sa, with Indian sargam labels.
    private static let sargam = ["Sa", "re", "Re", "ga", "Ga", "ma",
                                 "Ma", "Pa", "dha", "Dha", "ni", "Ni", "Sá"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                toolbar
                padRow
                harmonicsSection
                modelSection
                Text("Click a pad to pluck (the pitch-invariant timbre is retuned per note). \"Play phrase\" reproduces the three-pluck reference for A/B against sitar1.wav. Harmonics edits each individual harmonic; Model exposes the bloom/jiva/body/room laws.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button {
                controller.sitarPlayReferencePhrase()
            } label: {
                Label("Play phrase", systemImage: "play.fill")
            }
            .help("Reproduce the three measured plucks (C#4) for A/B against sitar1.wav")
            HStack(spacing: 6) {
                Text("Velocity").font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.sitarVelocity, in: 0.1...1.0)
                    .frame(width: 120)
            }
            HStack(spacing: 6) {
                Text("Gain").font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.sitarGainDB, in: -24...24)
                    .frame(width: 120)
                    .help("Sitar output gain, applied after the matched master gain")
                Text(String(format: "%+.0f dB", controller.sitarGainDB))
                    .font(.caption).monospacedDigit()
            }
            Spacer()
            Button("Reset") {
                controller.sitarParams = TanpuraParams.sitar
            }
            .help("Restore every model parameter to the matched bake (TanpuraParams.sitar)")
            Button("Silence") {
                controller.audio.clearSitarState()
            }
        }
    }

    // MARK: - Pluck pads

    private var padRow: some View {
        HStack(spacing: 6) {
            ForEach(0..<13, id: \.self) { i in
                pad(i)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pad(_ i: Int) -> some View {
        let f0 = Self.saF0 * pow(2.0, Double(i) / 12.0)
        let isTonic = (i == 0 || i == 12)
        return Button {
            pressed = i
            controller.sitarPluck(0, f0: f0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if pressed == i { pressed = nil }
            }
        } label: {
            VStack(spacing: 4) {
                Text(Self.sargam[i])
                    .font(.system(size: 18, weight: isTonic ? .bold : .regular,
                                  design: .serif))
                Text(String(format: "%.0f", f0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(pressed == i
                          ? Color.accentColor.opacity(0.6)
                          : Color(white: isTonic ? 0.22 : 0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isTonic ? Color.accentColor.opacity(0.7)
                                    : Color(white: 0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Harmonics editor (string 0)

    private var harmonicsSection: some View {
        section("Harmonics") {
            HStack(spacing: 12) {
                Picker("", selection: $trimMode) {
                    ForEach(TrimMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer()
                Button("Reset trims") {
                    var p = controller.sitarParams
                    switch trimMode {
                    case .gain: p.strings[0].gainTrimDB = TanpuraParams.neutralGainTrims
                    case .peak: p.strings[0].peakTrim = TanpuraParams.neutralMulTrims
                    case .decay: p.strings[0].decayTrim = TanpuraParams.neutralMulTrims
                    }
                    controller.sitarParams = p
                }
            }
            HarmonicBarEditor(
                count: controller.sitarParams.harmonicCount,
                values: trimBinding,
                range: trimMode == .gain ? -24...12 : log2(0.125)...log2(8.0),
                neutral: 0,
                transform: trimMode == .gain
                    ? .init(toDisplay: { $0 }, fromDisplay: { $0 })
                    : .init(toDisplay: { log2(max(0.05, $0)) }, fromDisplay: { pow(2, $0) }),
                unit: trimMode == .gain ? "dB" : "×"
            )
            .frame(height: 150)
        }
    }

    private var trimBinding: Binding<[Double]> {
        Binding(
            get: {
                let s = controller.sitarParams.strings[0]
                switch trimMode {
                case .gain: return s.gainTrimDB
                case .peak: return s.peakTrim
                case .decay: return s.decayTrim
                }
            },
            set: { v in
                var p = controller.sitarParams
                switch trimMode {
                case .gain: p.strings[0].gainTrimDB = v
                case .peak: p.strings[0].peakTrim = v
                case .decay: p.strings[0].decayTrim = v
                }
                controller.sitarParams = p
            }
        )
    }

    // MARK: - Model laws + globals

    private var modelSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                section("Bloom laws") {
                    rowFree("Spectral falloff", value: paramBinding(\.strings[0].falloff), range: 0...3)
                    rowFree("Pluck position", value: paramBinding(\.strings[0].pluckPos), range: 0.02...0.5)
                    rowFree("Decay (s)", value: paramBinding(\.strings[0].decay), range: 0.2...8)
                    rowFree("Decay tilt", value: paramBinding(\.strings[0].dampTilt), range: 0...2)
                    rowFree("Bloom delay (s)", value: paramBinding(\.strings[0].bloomDelay), range: 0...1.0)
                    rowFree("Bloom skew", value: paramBinding(\.strings[0].bloomSkew), range: 0...1.8)
                    rowFree("Attack level", value: paramBinding(\.strings[0].attackLevel), range: 0...1)
                    rowFree("Attack decay (s)", value: paramBinding(\.strings[0].attackDecay), range: 0.005...0.3)
                    rowFree("Inharmonicity", value: paramBinding(\.strings[0].inharmonicity), range: 0...0.0005)
                    rowFree("Sub-partials (dB)", value: paramBinding(\.strings[0].subLevelDB), range: -60 ... -2)
                    rowFree("Sub falloff", value: paramBinding(\.strings[0].subFalloff), range: 0...4)
                    rowFree("Sub knee (h)", value: paramBinding(\.strings[0].subKneeH), range: 1...64)
                }
                section("Life (jiva / drift / variation)") {
                    rowFree("Jiva depth", value: paramBinding(\.jivaDepth), range: 0...0.9)
                    rowFree("Jiva rate (Hz)", value: paramBinding(\.jivaRate), range: 0.05...8)
                    rowFree("Jiva mid-harmonic tilt", value: paramBinding(\.jivaTilt), range: 0...1)
                    rowFree("Jiva energy conserve", value: paramBinding(\.jivaConserve), range: 0...1)
                    rowFree("Jiva rate spread", value: paramBinding(\.jivaRateSpread), range: 0...1.5)
                    rowFree("Pitch drift (¢)", value: paramBinding(\.pitchDriftCents), range: 0...8)
                    rowFree("Pitch drift rate (Hz)", value: paramBinding(\.pitchDriftRate), range: 0.01...2)
                    rowFree("Pluck variation (dB)", value: paramBinding(\.pluckVariationDB), range: 0...5)
                }
                section("Attack noise (chik)") {
                    rowFree("Level", value: paramBinding(\.noiseLevel), range: 0...1)
                    rowFree("Decay (s)", value: paramBinding(\.noiseDecay), range: 0.003...0.08)
                    rowFree("Center (Hz)", value: paramBinding(\.noiseFreq), range: 500...7000)
                    rowFree("Q", value: paramBinding(\.noiseQ), range: 0.4...6)
                }
                section("Body & output") {
                    ForEach(0..<3, id: \.self) { b in
                        rowFree("Band \(b + 1) freq (Hz)", value: paramBinding(\.body[b].freq), range: b == 0 ? 200...360 : (b == 1 ? 460...720 : 900...2400))
                        rowFree("Band \(b + 1) gain", value: paramBinding(\.body[b].gain), range: 0...1.4)
                        rowFree("Band \(b + 1) Q", value: paramBinding(\.body[b].q), range: 1...300)
                    }
                    rowFree("Dry mix", value: paramBinding(\.bodyDry), range: 0...1)
                    rowFree("Tilt (dB @1.5k)", value: paramBinding(\.tiltDB), range: -10...10)
                    rowFree("Pan spread", value: paramBinding(\.panSpread), range: 0...1)
                    rowFree("Master gain", value: paramBinding(\.masterGain), range: 0...1)
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

    // MARK: - Helpers (mirror TanpuraPadView)

    private func paramBinding(_ keyPath: WritableKeyPath<TanpuraParams, Double>) -> Binding<Double> {
        Binding(
            get: { controller.sitarParams[keyPath: keyPath] },
            set: { controller.sitarParams[keyPath: keyPath] = $0 }
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
