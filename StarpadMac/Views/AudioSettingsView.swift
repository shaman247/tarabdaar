import CoreAudio
import StarpadCore
import SwiftUI

/// Output device routing + reverb mix. The device picker enumerates
/// CoreAudio output devices on appear; pick one to route AVAudioEngine
/// through that HAL device. "System Default" routes via the
/// `kAudioHardwarePropertyDefaultOutputDevice` device, so changing the
/// system default in System Settings follows automatically.
struct AudioSettingsView: View {
    @ObservedObject var controller: AppController

    @State private var devices: [AudioOutputDevice] = []
    @State private var selectedID: AudioDeviceID = 0
    /// Persisted across launches.
    @AppStorage("starpad.reverbMix") private var reverbMix: Double = 25
    @State private var sampleRate: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AUDIO")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
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
