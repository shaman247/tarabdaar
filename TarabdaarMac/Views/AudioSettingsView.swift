import CoreAudio
import SarangiKit
import TarabdaarCore
import SwiftUI

/// Output device routing + the String voice's control axes. The device
/// picker follows the recovery controller's selected route, including device loss and return.
/// "System Default" retains that intent across changes in System Settings.
struct AudioSettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var audio: AudioEngine

    init(controller: AppController) {
        self.controller = controller
        self.audio = controller.audio
    }

    @State private var devices: [AudioOutputDevice] = []
    @State private var switchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AUDIO")
                .font(.padCaption.weight(.bold))
                .foregroundStyle(.secondary)
            instrumentPanel
            outputDevicePanel
            infoPanel
        }
        .padding(20)
        .onAppear {
            refreshDevices()
        }
        .onChange(of: audio.outputDeviceRevision) { _ in refreshDevices() }
        .alert("Audio output", isPresented: Binding(get: { switchError != nil },
            set: { if !$0 { switchError = nil } })) {
            Button("OK") { switchError = nil }
        } message: { Text(switchError ?? "") }
    }

    // MARK: - Panels

    private var instrumentPanel: some View {
        Panel(title: "String voice") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The String physics sarangi (bowed_string.json) — the pure-physics bowed gut string with the modal-jawari taraf in-kernel; poly gut strings on one bridge, per-finger MPE bend.")
                    .font(.padCaption)
                    .foregroundStyle(.secondary)
                Text("Sound: Sarangi tab (physics) · Strings tab (sympathetic strings) · Controls tab (tilt bindings + composites) · Parameters tab (resting defaults).")
                    .font(.padCaption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var outputDevicePanel: some View {
        Panel(title: "Output device") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Device", selection: Binding(get: { audio.outputDeviceSelection }, set: { id in
                    if !audio.setOutputDevice(id) { switchError = audio.outputDeviceError }
                })) {
                    Text("System Default").tag(AudioDeviceID(0))
                    if audio.outputDeviceSelection != 0 && !devices.contains(where: { $0.id == audio.outputDeviceSelection }) {
                        Text("Unavailable").tag(audio.outputDeviceSelection)
                    }
                    Divider()
                    ForEach(devices) { d in
                        Text(d.isDefault ? "\(d.name) (system default)" : d.name)
                            .tag(d.id)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Button {
                        refreshDevices()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    if let dev = devices.first(where: { $0.id == audio.outputDeviceSelection }),
                       let mfg = dev.manufacturer {
                        Text(mfg)
                            .font(.padCaption)
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
                LabeledContent("Sample rate", value: audio.outputSampleRate > 0
                               ? String(format: "%.0f Hz", audio.outputSampleRate)
                               : "—")
                LabeledContent("DSP sample rate", value: String(format: "%.0f Hz", Config.sampleRate))
                if let error = audio.outputDeviceError { LabeledContent("Status", value: error) }
            }
            .font(.system(.body))
        }
    }

    // MARK: - Helpers

    private func refreshDevices() {
        devices = CoreAudioDevices.listOutputDevices()
    }
}
