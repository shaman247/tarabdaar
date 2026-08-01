import StarpadCore
import SwiftUI

/// USB MIDI status panel. Shows whether the MIDI engine is running and
/// lists the visible MIDI sources (the iPad shows up as one of these
/// when plugged in over USB).
struct ConnectionStatusView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var midi: MIDIEngine

    init(controller: AppController) {
        self.controller = controller
        self.midi = controller.midi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MIDI INPUT")
                .font(.padCaption.weight(.bold))
                .foregroundStyle(.secondary)
            statusPanel
            sourcesPanel
        }
        .padding(20)
    }

    private var statusPanel: some View {
        Panel(title: "Status") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(midi.isActive ? "Active" : "Not started")
                        .font(.system(.body))
                }
                LabeledContent("Sources",      value: "\(midi.sourceCount)")
                LabeledContent("Destinations", value: "\(midi.destinationCount)")
                LabeledContent("Status", value: midi.statusMessage)
            }
            .font(.system(.body))
        }
    }

    private var sourcesPanel: some View {
        Panel(title: "Visible MIDI sources") {
            if midi.sourceCount == 0 {
                Text("Plug in the iPad over USB to play.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(MIDIEngine.sourceNames().enumerated()), id: \.offset) { _, name in
                        HStack {
                            Image(systemName: "pianokeys")
                            Text(name)
                                .font(.system(.body))
                        }
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        if !midi.isActive { return .gray }
        return midi.sourceCount > 0 ? .green : .yellow
    }
}
