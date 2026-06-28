import StarpadCore
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
        if let raw = UserDefaults.standard.string(forKey: "starpad.macSelectedTab"),
           let t = Tab(rawValue: raw) {
            return t
        }
        return .live
    }()

    enum Tab: String, Hashable, CaseIterable {
        case live = "Live"
        case sarangi = "Sarangi"
        case tarab = "Tarab"
        case fx = "FX"
        case simulator = "Simulator"
        case pitchPad = "Pitch Pad"
        case chordPad = "Chord Pad"
        case stringPad = "String Pad"
        case tanpura = "Tanpura"
        case sitar = "Sitar"
        case setup = "Setup"
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
            // Hidden buttons for keyboard shortcuts: ⌘1..⌘9 jump to the first
            // nine tabs. Plain Buttons don't render anything since they're sized
            // to zero and clipped — the keyboardShortcut modifiers register with
            // the window's responder chain. Only the first 9 get a shortcut: a
            // two-digit `KeyEquivalent(Character("10"))` traps at runtime, and
            // there's no single ⌘ key for a 10th tab anyway (Setup; use the picker).
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
        UserDefaults.standard.set(t.rawValue, forKey: "starpad.macSelectedTab")
        switch t {
        case .pitchPad:  controller.ipadLayout = .pitchPad
        case .chordPad:  controller.ipadLayout = .chordPad
        case .stringPad: controller.ipadLayout = .stringPad
        default: break
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            ConnectionPill(controller: controller)
            PresetMenu(controller: controller)
            HostedAUPill(controller: controller)
            Spacer(minLength: 12)
            Picker("", selection: Binding(get: { tab }, set: { selectTab($0) })) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 440)
            Spacer(minLength: 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .live:      LiveVisualizerView(controller: controller)
        case .sarangi:   SarangiEditorView(controller: controller)
        case .tarab:     TarabView(controller: controller)
        case .fx:        FXView(controller: controller)
        case .simulator: SimulatorView(controller: controller)
        case .pitchPad:  PitchPadView(controller: controller)
        case .chordPad:  ChordPadView(controller: controller)
        case .stringPad: StringPadView(controller: controller)
        case .tanpura:   TanpuraPadView(controller: controller)
        case .sitar:     SitarPadView(controller: controller)
        case .setup:     SetupView(controller: controller)
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
                Text(label).font(.system(.caption))
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

private struct PresetMenu: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Menu {
            ForEach(SoundPreset.allCases, id: \.rawValue) { preset in
                Button {
                    controller.applyPreset(preset)
                } label: {
                    if controller.currentPreset == preset {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.stack")
                Text(controller.currentPreset?.label ?? "Preset")
                    .font(.system(.caption, design: .default).weight(.medium))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Surfaces the hosted-AU load status (e.g. SWAM Viola). Tappable to
/// pop a more detailed status string when load fails or MIDI events
/// aren't reaching the AU, plus a button to open the AU's own view
/// for in-app configuration.
private struct HostedAUPill: View {
    @ObservedObject var controller: AppController
    @ObservedObject var audio: AudioEngine
    @State private var showDetails = false

    init(controller: AppController) {
        self.controller = controller
        self.audio = controller.audio
    }

    var body: some View {
        if audio.hostedInstrumentStatus == "no instrument" {
            EmptyView()
        } else {
            Button {
                showDetails = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.caption)
                    Text(shortLabel)
                        .font(.system(.caption))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(pillColor.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hosted AU").font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(audio.hostedInstrumentStatus)
                        .font(.system(.body))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("MIDI forwarded:").foregroundStyle(.secondary)
                        Text("\(audio.hostedMIDIEventCount)")
                            .font(.system(.body))
                    }
                    HStack {
                        Text("AU output peak:").foregroundStyle(.secondary)
                        Text(String(format: "%.4f", audio.hostedOutputPeak))
                            .font(.system(.body))
                            .foregroundStyle(audio.hostedOutputPeak > 0.0001 ? .green : .red)
                    }
                    Divider()
                    Button {
                        controller.openHostedInstrumentWindow()
                        showDetails = false
                    } label: {
                        Label("Open AU view", systemImage: "rectangle.inset.filled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button {
                        audio.resetHostedInstrumentControllers()
                    } label: {
                        Label("Reset AU controllers",
                              systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Send All-Notes-Off + Reset-All-Controllers + safe-default CCs on all MPE channels. Useful if an iPad CC has left the AU in a silent state.")
                    Button {
                        controller.reloadHostedInstrument()
                    } label: {
                        Label("Reload AU instance",
                              systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Tear down the AU and instantiate a fresh copy. Useful when a load lands in a silent or stuck state and a full app restart isn't desired.")
                    Divider()
                    Button {
                        controller.captureSwamState()
                    } label: {
                        Label("Capture SWAM State",
                              systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Snapshot SWAM's current full state (incl. the MIDI CC assignments you set in its UI) into SwamDefaultState.swift, so it's restored on every launch. Configure SWAM's MIDI mapping first, then capture and rebuild. Dev/source builds only.")
                    if !controller.swamCaptureStatus.isEmpty {
                        Text(controller.swamCaptureStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(width: 360, alignment: .leading)
            }
        }
    }

    private var shortLabel: String {
        let s = audio.hostedInstrumentStatus
        if s.hasPrefix("loaded ") {
            return "AU: \(audio.hostedMIDIEventCount) ev"
        } else if s.hasPrefix("loading ") {
            return "AU: loading…"
        } else {
            return "AU: error"
        }
    }

    private var pillColor: Color {
        let s = audio.hostedInstrumentStatus
        if s.hasPrefix("loaded ") { return .green }
        if s.hasPrefix("loading ") { return .yellow }
        return .red
    }
}

