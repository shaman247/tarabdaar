import CoreAudio
import SarangiKit
import StarpadCore
import SwiftUI

/// Output device routing + the String voice's control axes. The device
/// picker enumerates CoreAudio output devices on appear; pick one to route
/// AVAudioEngine through that HAL device. "System Default" routes via the
/// `kAudioHardwarePropertyDefaultOutputDevice` device, so changing the
/// system default in System Settings follows automatically.
struct AudioSettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var audio: AudioEngine

    init(controller: AppController) {
        self.controller = controller
        self.audio = controller.audio
    }

    @State private var devices: [AudioOutputDevice] = []
    @State private var selectedID: AudioDeviceID = 0
    @State private var sampleRate: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AUDIO")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            instrumentPanel
            outputDevicePanel
            infoPanel
        }
        .padding(20)
        .onAppear {
            refreshDevices()
            sampleRate = controller.audio.outputSampleRate
        }
    }

    // MARK: - Panels

    private var instrumentPanel: some View {
        Panel(title: "String voice") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The String physics sarangi (bowed_string.json) — the pure-physics bowed gut string with the modal-jawari taraf in-kernel; poly gut strings on one bridge, per-finger MPE bend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Sound: Sarangi tab (physics) · Tarab tab (sympathetic strings) · Controls tab (tilt bindings + composites) · Parameters tab (resting defaults).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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
