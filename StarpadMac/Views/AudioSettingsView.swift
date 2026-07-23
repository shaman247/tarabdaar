import CoreAudio
import SarangiKit
import StarpadCore
import SwiftUI

/// Output device routing + reverb mix. The device picker enumerates
/// CoreAudio output devices on appear; pick one to route AVAudioEngine
/// through that HAL device. "System Default" routes via the
/// `kAudioHardwarePropertyDefaultOutputDevice` device, so changing the
/// system default in System Settings follows automatically.
struct AudioSettingsView: View {
    @ObservedObject var controller: AppController
    // Observed so the coupled toggle + loop-stability readout refresh live.
    @ObservedObject var store: SarangiStore
    @ObservedObject var audio: AudioEngine

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sarangi
        self.audio = controller.audio
    }

    @State private var devices: [AudioOutputDevice] = []
    @State private var selectedID: AudioDeviceID = 0
    /// Persisted across launches.
    @AppStorage("starpad.reverbMix") private var reverbMix: Double = 25
    @State private var sampleRate: Double = 0
    // Model-voice control axes (0..1 slider positions; defaults = the fitted
    // operating point — pair-3 gated medians). Not persisted: the voice
    // resets to the validated defaults each launch, like the upstream app.
    @State private var modelExpr = BowControlMapper.defaultExpr
    @State private var modelPress = BowControlMapper.defaultPress
    @State private var modelPos = BowControlMapper.defaultPos
    @State private var modelTilt = BowControlMapper.defaultTilt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AUDIO")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            instrumentPanel
            outputDevicePanel
            reverbPanel
            infoPanel
        }
        .padding(20)
        .onAppear {
            refreshDevices()
            // Apply persisted reverb mix on appear (engine starts at 25%
            // by default; sync to whatever the user last picked).
            controller.audio.setReverbMix(Float(reverbMix))
            sampleRate = controller.audio.outputSampleRate
        }
    }

    // MARK: - Panels

    private var instrumentPanel: some View {
        Panel(title: "Base voice") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Base voice", selection: $controller.baseVoice) {
                    ForEach(BaseVoice.allCases) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.menu)
                Text(baseVoiceCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if controller.baseVoice.isSarangiModel {
                    modelVoiceAxes
                }
            }
        }
    }

    private var baseVoiceCaption: String {
        if controller.baseVoice.isSarangiModel {
            return "The String physics sarangi (bowed_string.json) — the pure-physics bowed gut string with the modal-jawari taraf in-kernel; poly gut strings on one bridge, per-finger MPE bend."
        }
        if controller.baseVoice.isSitar {
            return "Our sitar model is the excitation the sarangi transforms — played by note (pluck) with pitch-bend glide."
        }
        return "The dry SWAM voice the sarangi model transforms. Bow timbre and DRY routing apply to all four."
    }

    /// The model voice's four control axes (the same CC map hardware/iPad
    /// controllers use: CC11 expr · CC1 press · CC74 pos · CC2/75 tilt).
    /// Defaults = the fitted operating point (pair-3 gated medians).
    private var modelVoiceAxes: some View {
        VStack(alignment: .leading, spacing: 6) {
            modelAxisSlider("Expression (CC11)", $modelExpr, cc: 11)
            modelAxisSlider("Bow pressure (CC1)", $modelPress, cc: 1)
            modelAxisSlider("Bow position (CC74)", $modelPos, cc: 74)
            modelAxisSlider("Harmonic tilt (CC2/75)", $modelTilt, cc: 2)
        }
        .padding(.top, 4)
    }

    private func modelAxisSlider(_ label: String, _ value: Binding<Double>, cc: UInt8) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 150, alignment: .leading)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { v in
                    value.wrappedValue = v
                    controller.audio.setSarangiModelVoiceAxis(cc: cc, value01: v)
                }), in: 0...1)
        }
    }

    private var outputDevicePanel: some View {
        Panel(title: "Output device") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Device", selection: $selectedID) {
                    Text("System Default").tag(AudioDeviceID(0))
                    Divider()
                    ForEach(devices) { d in
                        Text(d.isDefault ? "\(d.name) (system default)" : d.name)
                            .tag(d.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedID) { newID in
                    let target: AudioDeviceID = newID == 0
                        ? CoreAudioDevices.systemDefaultOutputDevice()
                        : newID
                    controller.audio.setOutputDevice(target)
                    sampleRate = controller.audio.outputSampleRate
                }

                HStack {
                    Button {
                        refreshDevices()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    if let dev = devices.first(where: { $0.id == selectedID }),
                       let mfg = dev.manufacturer {
                        Text(mfg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var reverbPanel: some View {
        Panel(title: "Reverb") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Mix")
                        .font(.system(.body))
                        .frame(width: 56, alignment: .leading)
                    Slider(value: $reverbMix, in: 0...100) {
                        EmptyView()
                    }
                    .onChange(of: reverbMix) { newValue in
                        controller.audio.setReverbMix(Float(newValue))
                    }
                    Text(String(format: "%.0f%%", reverbMix))
                        .font(.system(.caption))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Text("Mac-only — does not affect the iPad's local audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var infoPanel: some View {
        Panel(title: "Engine") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Running", value: controller.audio.isRunning ? "yes" : "no")
                LabeledContent("Sample rate", value: sampleRate > 0
                               ? String(format: "%.0f Hz", sampleRate)
                               : "—")
                LabeledContent("DSP sample rate", value: String(format: "%.0f Hz", Config.sampleRate))
                LabeledContent("Max poly voices", value: "\(Config.maxPolyVoices)")
            }
            .font(.system(.body))
        }
    }

    // MARK: - Helpers

    private func refreshDevices() {
        devices = CoreAudioDevices.listOutputDevices()
        // Pre-select whatever the engine is currently using; if it
        // matches the system default, leave selection at 0 ("System
        // Default") so changing the OS default keeps working.
        let current = controller.audio.currentOutputDevice
        let systemDefault = CoreAudioDevices.systemDefaultOutputDevice()
        if current == 0 || current == systemDefault {
            selectedID = 0
        } else {
            selectedID = current
        }
    }
}
