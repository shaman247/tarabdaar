import TarabdaarCore
import SwiftUI

/// CoreMIDI status panel. CoreMIDI is the TLP tunnel's TRANSPORT and
/// nothing else — the only bytes that cross it are SysEx-framed TLP
/// frames. There is no MIDI note vocabulary to report on.
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
                .font(.padCaption.weight(.bold))
                .foregroundStyle(.secondary)
            statusPanel
        }
        .padding(20)
    }

    private var statusPanel: some View {
        Panel(title: "TLP transport") {
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

                HStack {
                    if midi.isActive {
                        HStack(spacing: 4) {
                            Text("Client:")
                                .foregroundColor(.secondary)
                            Text("Tarabdaar").bold()
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

}
