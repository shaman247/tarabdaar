import TarabdaarCore
import SwiftUI

/// Top-level macOS window: a single content area driven by a segmented
/// tab control at the top. Connection state, preset, and mode all live
/// in the top bar so they're visible from every tab without needing to
/// navigate.
struct MacMainWindow: View {
    @ObservedObject var controller: AppController
    /// Selected tab, persisted across launches so the app reopens on
    /// whatever surface you were working in.
    @State private var tab: Tab = {
        if let raw = UserDefaults.standard.string(forKey: "tarabdaar.macSelectedTab"),
           let t = Tab(rawValue: raw) {
            return t
        }
        return .live
    }()

    /// The Mac's tabs, in ⌘-number order.
    enum Tab: String, Hashable, CaseIterable {
        case live = "Live"
        case strings = "Strings"
        case fretPad = "Fret Pad"
        case tilt = "Controls"
        case parameters = "Parameters"
        case fx = "FX"
        case setup = "Setup"
        /// the performance scope — touched vs sounding
        /// pitches and every taraf row's level + harmonic character.
        case scope = "Scope"
        /// the per-row taraf panel — level, radiated vs modal
        /// spectra, the radiation-tap comb.
        case taraf = "Taraf"
        /// the formula body's frequency response as built (⌘0).
        case body = "Body"
        case transforms = "Transforms"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.08))
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            FinalOutputStrip(controller: controller)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.08))
        }
        .background(
            // Hidden buttons for keyboard shortcuts: ⌘1..⌘9 jump to each tab
            // (Live … Taraf) and ⌘0 to the tenth (Body). Plain Buttons don't
            // render anything since they're sized to zero and clipped — the
            // keyboardShortcut modifiers register with the window's responder
            // chain.
            ZStack {
                ForEach(Array(Tab.allCases.enumerated()), id: \.element) { i, t in
                    if i < 10 {
                        Button("") { selectTab(t) }
                            .keyboardShortcut(
                                KeyEquivalent(Character("\((i + 1) % 10)")),
                                modifiers: .command
                            )
                            .opacity(0)
                            .frame(width: 0, height: 0)
                    }
                }
            }
        )
    }

    /// Switch tabs. The two playing-surface tabs also tell the iPad which
    /// layout to perform (`ipadLayout` rides the synced state); other tabs
    /// leave the iPad on whatever pad it last showed. Routed through here so
    /// both the segmented picker and the ⌘-number shortcuts stay in sync.
    private func selectTab(_ t: Tab) {
        tab = t
        UserDefaults.standard.set(t.rawValue, forKey: "tarabdaar.macSelectedTab")
        // The Fret Pad is the only playing surface; make sure the iPad performs
        // it. (It's forced to `.fretPad` at launch too.)
        if t == .fretPad { controller.ipadLayout = .fretPad }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            ConnectionPill(controller: controller)
            KeyboardPlayPill(controller: controller)
            Spacer(minLength: 12)
            Picker("", selection: Binding(get: { tab }, set: { selectTab($0) })) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 920)
            Spacer(minLength: 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .live:      LiveVisualizerView(controller: controller)
        case .strings:   StringsView(controller: controller)
        case .fretPad:    FretPadView(controller: controller)
        case .tilt:       TiltControlsView(controller: controller)
        case .parameters: ParametersView(controller: controller)
        case .fx:         FXView(controller: controller)
        case .setup:      SetupView(controller: controller)
        case .scope:      ScopeView(controller: controller)
        case .taraf:      TarafScopeView(controller: controller)
        case .body:       BodyView(controller: controller)
        case .transforms: BowTransformsView(controller: controller)
        }
    }
}

// MARK: - Final output

private struct FinalOutputStrip: View {
    @ObservedObject var controller: AppController
    @State private var editingGain = false
    @FocusState private var gainFocused: Bool
    private let spec = ParamRegistry.spec("output_gain_db")!

    private var gain: Binding<Double> {
        Binding(get: { controller.paramValue(spec.key) }, set: { value in
            guard value.isFinite else { return }
            controller.setParamValue(spec.key, spec.clamp(value))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            outputControls
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("BUS RMS · dBFS · PRE-OUTPUT GAIN")
                    .font(.padCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                    let buses = controller.audio.performanceReadout()
                    HStack(spacing: 24) {
                        busMeter("Main", level: buses.voiceRMS,
                                 maximum: buses.maximumVoiceRMS, color: .orange)
                        busMeter("Chromatic taraf", level: buses.chromaticRMS,
                                 maximum: buses.maximumChromaticRMS, color: .cyan)
                        busMeter("Raga taraf", level: buses.ragaRMS,
                                 maximum: buses.maximumRagaRMS, color: .purple)
                    }
                }
            }
        }
        .font(.padCaption)
        .onChange(of: gainFocused) { focused in
            if !focused { editingGain = false }
        }
    }

    private var outputControls: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("OUTPUT GAIN")
                    .font(.padCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) { controller.setParamValue(spec.key, spec.def) }
                HStack(spacing: 8) {
                    Slider(value: gain, in: spec.lo...spec.hi, step: 0.5)
                        .accessibilityLabel("Final output gain")
                    gainEntry
                    Text("dB").foregroundStyle(.secondary)
                }
            }
            .frame(width: 280)

            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                let peaks = controller.audio.outputPeaks()
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OUTPUT PEAK · dBFS")
                            .font(.padCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        peakRow("L", level: peaks.left, maximum: peaks.maximumLeft)
                        peakRow("R", level: peaks.right, maximum: peaks.maximumRight)
                    }
                    VStack(spacing: 4) {
                        Text("LIMIT").font(.padCaption.weight(.semibold))
                        Text(peaks.gainReductionDB >= 0.05
                             ? String(format: "−%.1f dB", peaks.gainReductionDB) : "0.0 dB")
                            .monospacedDigit()
                    }
                    .foregroundStyle(peaks.gainReductionDB >= 0.05 ? Color.orange : Color.secondary)
                    .frame(width: Typography.scaledWidth(68))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Output gain reduction")
                    .accessibilityValue(String(format: "%.1f decibels", peaks.gainReductionDB))
                    VStack(spacing: 6) {
                        Label("CLIP", systemImage: "circle.fill")
                            .font(.padCaption.weight(.bold))
                            .foregroundStyle(peaks.clipped ? Color.red : Color.secondary)
                            .accessibilityLabel(peaks.clipped ? "Output clipped" : "Output not clipped")
                        Button("Reset meters") { controller.audio.resetOutputPeaks() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var gainEntry: some View {
        Group {
            if editingGain {
                TextField("Gain", value: gain, format: .number.precision(.fractionLength(1)))
                    .focused($gainFocused)
                    .onAppear { DispatchQueue.main.async { gainFocused = true } }
                    .onSubmit { editingGain = false; gainFocused = false }
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            } else {
                Button { editingGain = true } label: {
                    Text(gain.wrappedValue, format: .number.precision(.fractionLength(1)))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.bordered)
            }
        }
        .monospacedDigit()
        .frame(width: Typography.scaledWidth(50))
        .accessibilityLabel("Final output gain in decibels")
    }

    private func peakRow(_ channel: String, level: Double, maximum: Double) -> some View {
        let db = level > 0 ? 20 * log10(level) : -.infinity
        let color: Color = db >= 0 ? .red : db >= -6 ? .yellow : .green
        return HStack(spacing: 8) {
            Text(channel).frame(width: Typography.scaledWidth(10))
            levelBar(level, color: color)
            Text(dbText(level)).monospacedDigit().frame(width: Typography.scaledWidth(40), alignment: .trailing)
            Text("max \(dbText(maximum))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: Typography.scaledWidth(72), alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(channel == "L" ? "Left" : "Right") output peak")
        .accessibilityValue("\(dbText(level)) dBFS, maximum \(dbText(maximum)) dBFS")
    }

    private func busMeter(_ name: String, level: Double, maximum: Double, color: Color) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(name).foregroundStyle(color)
                Spacer(minLength: 4)
                Text(dbText(level)).monospacedDigit()
                    .frame(width: Typography.scaledWidth(40), alignment: .trailing)
                Text("max \(dbText(maximum))").monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: Typography.scaledWidth(72), alignment: .trailing)
            }
            levelBar(level, color: color)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) bus RMS before final output gain")
        .accessibilityValue("\(dbText(level)) dBFS, maximum \(dbText(maximum)) dBFS")
    }

    private func levelBar(_ amplitude: Double, color: Color) -> some View {
        let db = amplitude > 0 ? 20 * log10(amplitude) : -.infinity
        let fraction = max(0, min(1, (db + 60) / 60))
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color).frame(width: geometry.size.width * fraction)
                ForEach([-24.0, -12, -6, 0], id: \.self) { tick in
                    Rectangle().fill(Color.primary.opacity(0.35))
                        .frame(width: 1)
                        .offset(x: (geometry.size.width - 1) * (tick + 60) / 60)
                }
            }
        }
        .frame(height: 8)
    }

    private func dbText(_ amplitude: Double) -> String {
        guard amplitude.isFinite else { return "+∞" }
        guard amplitude > 0 else { return "−∞" }
        let db = 20 * log10(amplitude)
        return db < -60 ? "≤−60" : String(format: "%.1f", db)
    }
}

// MARK: - Top bar widgets

private struct ConnectionPill: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var midi: MIDIEngine
    @State private var showDetails = false

    init(controller: AppController) {
        self.controller = controller
        self.midi = controller.midi
    }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            let readout = LinkReadout(midi: midi, status: controller.linkStatus)
            HStack(spacing: 6) {
                Circle().fill(readout.color).frame(width: 8, height: 8)
                Image(systemName: readout.symbol)
                    .font(.padCaption)
                    .foregroundStyle(readout.color)
                Text(readout.short).font(.padCaption.monospacedDigit())
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(white: 0.15)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetails) {
            ConnectionStatusView(controller: controller)
                .frame(width: 420, height: 560)
        }
    }
}

/// Top-bar control for computer-keyboard note input. The pill shows the
/// on/off state; tapping opens a popover with the enable toggle, an octave
/// stepper, and a legend of the key layout. Reachable from every tab since
/// keyboard play is app-wide.
private struct KeyboardPlayPill: View {
    @ObservedObject var keyboard: KeyboardNotePlayer
    @State private var showDetails = false

    init(controller: AppController) {
        self.keyboard = controller.keyboard
    }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "keyboard").font(.padCaption)
                Text(keyboard.enabled ? "Keys" : "Keys off")
                    .font(.padCaption)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(
                (keyboard.enabled ? Color.green : Color(white: 0.5)).opacity(0.25)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Play notes with the computer keyboard",
                       isOn: $keyboard.enabled)
                Divider()
                HStack {
                    Text("Octave shift").foregroundStyle(.secondary)
                    Spacer()
                    Stepper(value: $keyboard.octaveOffset, in: -3...3) {
                        Text(keyboard.octaveOffset >= 0
                             ? "+\(keyboard.octaveOffset)"
                             : "\(keyboard.octaveOffset)")
                            .monospacedDigit()
                    }
                    .disabled(!keyboard.enabled)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keys play ascending degrees of the Pitch Pad scale:")
                        .foregroundStyle(.secondary)
                    Text("Q W E R T Y U I O P").monospaced()
                    Text("A S D F G H J K L ;").monospaced()
                    Text("Z X C V B N M , . /").monospaced()
                    Text("[ / ] shift down / up an octave")
                        .foregroundStyle(.secondary)
                    Text("Works on any tab; pauses while you type in a field.")
                        .foregroundStyle(.secondary)
                }
                .font(.padCaption)
            }
            .padding(16)
            .frame(width: 340, alignment: .leading)
        }
    }
}
