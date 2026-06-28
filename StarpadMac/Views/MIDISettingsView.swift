import StarpadCore
import SwiftUI

/// MIDI output panel. The Mac publishes a virtual MIDI source named
/// "Starpad" via CoreMIDI; DAWs and external synths can subscribe to
/// it. NoteManager's 60 Hz glide loop sends per-voice pitch bend,
/// channel pressure, and CC values to this source — same code path the
/// iPad uses.
struct MIDISettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var midi: MIDIEngine

    init(controller: AppController) {
        self.controller = controller
        self.midi = controller.midi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MIDI")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            statusPanel
            configPanel
        }
        .padding(20)
    }

    private var statusPanel: some View {
        Panel(title: "Virtual MIDI source") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(midi.isActive ? .green : .gray)
                        .frame(width: 10, height: 10)
                    Text(midi.isActive ? "Active" : "Inactive")
                        .font(.system(.body))
                }
                LabeledContent("Status", value: midi.statusMessage)
                LabeledContent("External destinations", value: "\(midi.destinationCount)")
                LabeledContent("Pitch bend range", value: "± \(Int(Config.midiPitchBendRange)) semitones")

                HStack {
                    if midi.isActive {
                        HStack(spacing: 4) {
                            Text("Source name:")
                                .foregroundColor(.secondary)
                            Text("Starpad").bold()
                        }
                    } else {
                        Button("Start MIDI") {
                            midi.start()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .font(.system(.body))
        }
    }

    private var configPanel: some View {
        Panel(title: "MPE") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Per-note channel allocation rotates across MIDI channels 1–15 (channel 0 is the MPE master). Each new note activation gets a fresh channel so its pitch bend doesn't bleed into other voices' reverb tails.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Max poly voices", value: "\(Config.maxPolyVoices)")
                    .font(.system(.body))
            }
        }
    }
}
