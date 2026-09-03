import SwiftUI
import TarabdaarCore

/// FX tab (⌘6): the four-insert FX rack. Each point carries a
/// 10-band graphic EQ and a selectable reverb (Bigverb / Room), everything
/// off by default. All controls are ordinary registry parameters
/// (`fx_<point>_*`, all `.live`) driven through the unified
/// `paramValue`/`setParamValue` path — so presets capture them, the
/// Parameters tab lists them, and tilt/composites can bind them; this tab
/// is just the curated surface.
struct FXView: View {
    @ObservedObject var controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    /// The four insert points, in signal order. Prefixes must match
    /// `SarangiKit.FXPoint.keyPrefix` (guarded by `FXRackTests`).
    private static let points: [(prefix: String, title: String, sub: String)] = [
        ("fx_drive_", "Voice → Taraf",
         "What the sympathetic strings hear — shapes only the taraf's excitation, not the radiated voice."),
        ("fx_voice_", "Voice",
         "The main voice bus (bridge + bow noise) after the taraf tap."),
        ("fx_taraf_", "Taraf",
         "The sympathetic web's own radiated output, drones included."),
        ("fx_global_", "Global",
         "The final stereo output, after the whole fitted chain."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.points, id: \.prefix) { p in
                    FXPointPanel(controller: controller,
                                 prefix: p.prefix, title: p.title, sub: p.sub)
                }
            }
            .padding(16)
        }
    }
}

/// One insert point: an EQ strip and a reverb block, side by side.
private struct FXPointPanel: View {
    @ObservedObject var controller: AppController
    let prefix: String
    let title: String
    let sub: String

    private func bind(_ suffix: String) -> Binding<Double> {
        let key = prefix + suffix
        return Binding(get: { controller.paramValue(key) },
                       set: { controller.setParamValue(key, $0) })
    }

    private func flag(_ suffix: String) -> Binding<Bool> {
        let key = prefix + suffix
        return Binding(get: { controller.paramValue(key) >= 0.5 },
                       set: { controller.setParamValue(key, $0 ? 1 : 0) })
    }

    private var isActive: Bool {
        controller.paramValue(prefix + "eq_on") >= 0.5
            || controller.paramValue(prefix + "rev_on") >= 0.5
    }

    private static let bandLabels =
        ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    if isActive {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { resetPoint() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Reset this insert point to defaults (all off)")
                }
                HStack(alignment: .top, spacing: 24) {
                    eqBlock
                    Divider()
                    reverbBlock
                    Spacer(minLength: 0)
                }
            }
            .padding(6)
        }
    }

    private var eqBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Graphic EQ", isOn: flag("eq_on"))
                .toggleStyle(.switch)
                .controlSize(.small)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(1...10, id: \.self) { b in
                    EQFader(label: Self.bandLabels[b - 1],
                            value: bind("eq_b\(b)"))
                }
            }
            .opacity(controller.paramValue(prefix + "eq_on") >= 0.5 ? 1 : 0.45)
        }
    }

    private var reverbBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("Reverb", isOn: flag("rev_on"))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Picker("", selection: Binding<Int>(
                    get: { Int(controller.paramValue(prefix + "rev_type").rounded()) },
                    set: { controller.setParamValue(prefix + "rev_type", Double($0)) })) {
                    Text("Bigverb").tag(0)
                    Text("Room").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .labelsHidden()
                .help("Bigverb: 8 jittered feedback delay lines — a wide modulated hall. Room: the Freeverb-style tank — tighter, energy-matched.")
            }
            Group {
                fxSlider("mix", "rev_mix", 0...1, "%.2f")
                fxSlider("size", "rev_size", 0...1, "%.2f")
                fxSlider("cutoff", "rev_cut", 500...20000, "%.0f Hz")
            }
            .opacity(controller.paramValue(prefix + "rev_on") >= 0.5 ? 1 : 0.45)
        }
        .frame(width: 300)
    }

    private func fxSlider(_ label: String, _ suffix: String,
                          _ range: ClosedRange<Double>,
                          _ fmt: String) -> some View {
        ParamSliderRow(
            label: label, value: bind(suffix), range: range,
            readout: String(format: fmt, controller.paramValue(prefix + suffix)),
            labelFont: .caption, labelColor: .primary,
            labelWidth: 42, labelAlignment: .trailing,
            readoutFont: .caption.monospacedDigit(), readoutColor: .secondary,
            readoutWidth: 56,
            onLabelDoubleTap: { controller.resetParam(prefix + suffix) })
    }

    private func resetPoint() {
        for spec in ParamRegistry.all where spec.key.hasPrefix(prefix) {
            controller.resetParam(spec.key)
        }
    }
}

/// A compact vertical fader for one EQ band: ±12 dB around a centre
/// detent. Drag to set, double-click to reset to 0 dB.
private struct EQFader: View {
    let label: String
    @Binding var value: Double   // -12…+12 dB

    private let range = 24.0
    private let height = 92.0

    var body: some View {
        VStack(spacing: 3) {
            Text(value == 0 ? " " : String(format: "%+.0f", value))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let h = geo.size.height
                let y = (0.5 - value / range) * h
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 4)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(height: 1)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(value == 0 ? Color.secondary : Color.accentColor)
                        .frame(width: 14, height: 7)
                        .position(x: geo.size.width / 2,
                                  y: min(max(y, 4), h - 4))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let v = (0.5 - g.location.y / h) * range
                    value = min(max((v * 2).rounded() / 2, -range / 2),
                                range / 2)
                })
            }
            .frame(width: 22, height: height)
            .onTapGesture(count: 2) { value = 0 }
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .help("\(label) Hz band, ±12 dB — double-click to reset")
    }
}
