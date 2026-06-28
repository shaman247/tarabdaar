import AppKit
import SarangiKit
import StarpadCore
import SwiftUI

/// The **Sympathetic Strings (Tarab)** tab: the sarangi's sympathetic-string
/// bank, split into its four physical choirs (Chromatic / Scale-tuned / Low
/// octave / Upper octave). By default the bank **auto-tunes to the Pitch Pad
/// scale** (tonic + degrees you play); editing a string, toggling a choir, or
/// picking a raga detaches it for hand tuning. Backed by `controller.sarangi`.
struct TarabView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: SarangiStore

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sarangi
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderSection(controller: controller)
                Divider()
                ForEach(StringGroup.allCases, id: \.self) { group in
                    GroupSection(group: group)
                }
                Divider()
                ManualTuningSection()
            }
            .padding(16)
            .frame(maxWidth: 580, alignment: .leading)
        }
        .environmentObject(store)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Header (auto-sync + tonic)

private struct HeaderSection: View {
    @ObservedObject var controller: AppController
    @EnvironmentObject var store: SarangiStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Sympathetic strings").font(.title3).bold()
                Text("(\(store.state.strings.count))").foregroundStyle(.secondary)
                Spacer()
            }
            Toggle("Follow the Pitch Pad scale", isOn: Binding(
                get: { store.state.autoSyncToScale },
                set: { controller.setTarabAutoSync($0) }))
                .toggleStyle(.switch)
            Text(store.state.autoSyncToScale
                 ? "On — the tarab auto-tunes to the tonic + notes of the scale you play. Editing a string, toggling a choir, or picking a raga detaches it."
                 : "Detached — the strings are fixed for hand tuning. Turn this on (or “Re-sync”) to follow the scale again.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Re-sync to scale") { controller.syncTarabFromScale(force: true) }
                    .help("Rebuild the bank from the current Pitch Pad scale + tonic (turns auto-sync back on)")
                Spacer()
                Text(String(format: "Tonic %.2f Hz · %@", store.state.tonicHz, noteName(store.state.tonicHz)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func noteName(_ hz: Double) -> String {
        NoteName.name(forMIDI: Int((69.0 + 12.0 * log2(hz / 440.0)).rounded()))
    }
}

// MARK: - One choir

private struct GroupSection: View {
    let group: StringGroup
    @EnvironmentObject var store: SarangiStore

    private var rows: [StringSpec] { store.state.strings.filter { $0.group == group } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(group.label).font(.subheadline).bold()
                Text("(\(rows.count))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                let allOn = !rows.isEmpty && rows.allSatisfy(\.enabled)
                Button(allOn ? "Disable all" : "Enable all") { store.setGroupEnabled(group, !allOn) }
                    .font(.caption).disabled(rows.isEmpty)
                Button { store.addString(group: group) } label: { Image(systemName: "plus") }
                    .help("Add a string to \(group.label)")
            }
            Text(group.detail).font(.caption2).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            } else {
                TarabTableHeader()
                LazyVStack(spacing: 2) {
                    ForEach(rows) { s in StringRow(id: s.id) }
                }
            }
        }
    }
}

private struct TarabTableHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Note").frame(width: 42, alignment: .leading)
            Text("Freq (Hz)").frame(width: 74, alignment: .leading)
            Text("Gain").frame(width: 52, alignment: .leading)
            Text("t60").frame(width: 48, alignment: .leading)
            Text("Brt").frame(width: 36, alignment: .center)
            Text("On").frame(width: 30, alignment: .center)
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

private struct StringRow: View {
    @EnvironmentObject var store: SarangiStore
    let id: UUID

    var body: some View {
        if let s = store.state.strings.first(where: { $0.id == id }) {
            HStack(spacing: 6) {
                Text(s.noteName).frame(width: 42, alignment: .leading)
                    .font(.caption).foregroundStyle(s.enabled ? .primary : .secondary)
                TextField("", value: store.stringBinding(id, \.freq), format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 74).textFieldStyle(.roundedBorder).font(.caption)
                TextField("", value: store.stringBinding(id, \.gain), format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 52).textFieldStyle(.roundedBorder).font(.caption)
                TextField("", value: store.stringBinding(id, \.t60), format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 48).textFieldStyle(.roundedBorder).font(.caption)
                Toggle("", isOn: store.stringBinding(id, \.bright)).labelsHidden().frame(width: 36)
                Toggle("", isOn: store.stringBinding(id, \.enabled)).labelsHidden().frame(width: 30)
                Button { store.removeStrings([id]) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Manual tuning (raga fallback)

private struct ManualTuningSection: View {
    @EnvironmentObject var store: SarangiStore
    @State private var tonicText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual tuning").font(.subheadline).bold()
            Text("Fill the bank from a built-in raga instead of the Pitch Pad scale. Picking a raga, setting the tonic here, or regenerating detaches auto-sync.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Raga", selection: Binding(
                get: { store.state.ragaId },
                set: { store.setRaga(id: $0) })) {
                ForEach(RagaTuning.ragas) { raga in Text(raga.name).tag(raga.id) }
            }
            .frame(maxWidth: 260)
            HStack(spacing: 6) {
                Text("Tonic").frame(width: 42, alignment: .leading)
                TextField("Hz or note (e.g. Eb4)", text: $tonicText)
                    .frame(width: 130)
                    .onSubmit { applyTonic(transpose: false) }
                Button("Set") { applyTonic(transpose: false) }
                Button("Transpose") { applyTonic(transpose: true) }
                    .help("Shift to a new tonic, keeping string edits")
                Button("Regenerate") { store.regenerate() }
                    .help("Rebuild the bank from the raga + tonic above")
            }
            .font(.caption)
        }
        .onAppear { tonicText = String(format: "%.2f", store.state.tonicHz) }
    }

    private func applyTonic(transpose: Bool) {
        guard let hz = Double(tonicText) ?? NoteName.parse(tonicText) else { return }
        store.setTonic(hz, transpose: transpose)
        tonicText = String(format: "%.2f", store.state.tonicHz)
    }
}
