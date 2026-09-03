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

    /// 2026-07-24 parameter unification: the Sarangi tab is gone — its
    /// physics sliders merged into the one Parameters list (which also
    /// carries the preset toolbar it used to own).
    enum Tab: String, Hashable, CaseIterable {
        case live = "Live"
        case strings = "Strings"
        case fretPad = "Fret Pad"
        case tilt = "Controls"
        case parameters = "Parameters"
        case fx = "FX"
        case setup = "Setup"
        /// 2026-09-01: the performance scope — touched vs sounding
        /// pitches and every taraf row's level + harmonic character.
        case scope = "Scope"
        /// 2026-09-02: the per-row taraf panel — level, radiated vs modal
        /// spectra, the radiation-tap comb.
        case taraf = "Taraf"
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
        }
        .background(
            // Hidden buttons for keyboard shortcuts: ⌘1..⌘9 jump to each tab
            // (Live … Taraf). Plain Buttons don't render anything since they're
            // sized to zero and clipped — the keyboardShortcut modifiers register
            // with the window's responder chain.
            ZStack {
                ForEach(Array(Tab.allCases.enumerated()), id: \.element) { i, t in
                    if i < 9 {
                        Button("") { selectTab(t) }
                            .keyboardShortcut(
                                KeyEquivalent(Character("\(i + 1)")),
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
            .frame(maxWidth: 800)
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
        }
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
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.padCaption)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(white: 0.15)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetails) {
            ConnectionStatusView(controller: controller)
                .frame(width: 360, height: 380)
        }
    }

    private var color: Color {
        if !midi.isActive { return .red }
        return midi.sourceCount > 0 ? .green : .yellow
    }

    private var label: String {
        if !midi.isActive { return "MIDI off" }
        return midi.sourceCount > 0 ? "MIDI: \(midi.sourceCount) src" : "no MIDI in"
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
