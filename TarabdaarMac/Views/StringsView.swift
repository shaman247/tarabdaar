import AppKit
import SarangiKit
import TarabdaarCore
import SwiftUI

/// The **Sympathetic Strings (Tarab)** tab: the sarangi's sympathetic-string
/// bank — one flat pool of strings, each a **scale degree + octave** of the
/// centralized Pitch Pad scale (2026-07-25: pitches always follow the scale;
/// there is no per-string ratio or Hz, and no follow toggle — following is
/// unconditional). The string LAYOUT regenerates when the scale's degree
/// count changes or via "Regenerate from scale"; hand edits otherwise
/// stand. Backed by `controller.sarangi`.
struct StringsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: SarangiStore

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sarangi
    }

    /// The scale's OWN labels for its degrees, index-aligned with the
    /// document's `scaleRatios` mirror — pitches are named by the scale
    /// everywhere in the app, this tab included. The push that keeps the
    /// mirror in sync is debounced, so a degree the labels haven't caught up
    /// with falls back to its ratio rather than borrowing a neighbour's name.
    private var degreeLabels: [String] {
        let labels = scaleDegrees(from: controller.pitchPad.scale).map(\.label)
        return store.state.scaleRatios.indices.map { i in
            i < labels.count ? labels[i]
                             : String(format: "%.3f", store.state.scaleRatios[i])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderSection(controller: controller)
                Divider()
                StringsSection(degreeLabels: degreeLabels)
                Divider()
                DroneMappingSection(controller: controller,
                                    degreeLabels: degreeLabels)
            }
            .padding(16)
            .frame(maxWidth: 700, alignment: .leading)
        }
        .environmentObject(store)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Header (scale + tonic)

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
            Text("Every string is a degree of the Pitch Pad scale — pitches always follow the scale and the tonic. Gains, decays and the row set are yours to edit; the layout regenerates itself only when the scale's degree count changes. The table stays sorted by pitch and holds one string per pitch — a pitch edit that would duplicate another row is ignored, and + adds at the first free pitch.")
                .font(.padCaption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Regenerate from scale") { controller.syncTarabFromScale(force: true) }
                    .help("Rebuild the default string layout from the current scale (discards hand edits to the rows)")
                Spacer()
                Text(String(format: "Tonic %.2f Hz · %@", store.state.tonicHz, noteName(store.state.tonicHz)))
                    .font(.padCaption).foregroundStyle(.secondary)
            }
        }
    }

    private func noteName(_ hz: Double) -> String {
        NoteName.name(forMIDI: Int((69.0 + 12.0 * log2(hz / 440.0)).rounded()))
    }
}

// MARK: - The string pool

private struct StringsSection: View {
    @EnvironmentObject var store: SarangiStore
    let degreeLabels: [String]

    private var rows: [StringSpec] { store.state.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Strings").font(.padSubheadline).bold()
                Spacer()
                let allOn = !rows.isEmpty && rows.allSatisfy(\.enabled)
                Button(allOn ? "Disable all" : "Enable all") { store.setAllEnabled(!allOn) }
                    .font(.padCaption).disabled(rows.isEmpty)
                Button { store.addString() } label: { Image(systemName: "plus") }
                    .help("Add a string")
            }
            if rows.isEmpty {
                Text("—").font(.padCaption2).foregroundStyle(.tertiary)
            } else {
                TarabTableHeader()
                FollowerRow()
                LazyVStack(spacing: 2) {
                    ForEach(rows) { s in
                        StringRow(id: s.id, degreeLabels: degreeLabels)
                    }
                }
            }
        }
    }
}

/// The MELODY-FOLLOWER string — one special row pinned above the pool:
/// its pitch is not a scale degree, it live-retunes to the highest note
/// being played (glides included). Same Gain / t60 / On knobs as any
/// string; no octave, no Hz readout (the pitch is the melody's), and it
/// can't be a drone-button target.
private struct FollowerRow: View {
    @EnvironmentObject var store: SarangiStore

    var body: some View {
        HStack(spacing: 6) {
            Text("Follows melody")
                .frame(width: Typography.scaledWidth(76 + 64 + 6), alignment: .leading)
                .font(.padCaption).italic()
                .help("A special sympathetic string that live-retunes to the highest note being played (glides included)")
            Text("—")
                .frame(width: Typography.scaledWidth(64), alignment: .leading)
                .font(.padCaption).foregroundStyle(.tertiary)
            TextField("", value: store.followerBinding(\.gain), format: .number.precision(.fractionLength(0...2)))
                .frame(width: Typography.scaledWidth(52)).textFieldStyle(.roundedBorder).font(.padCaption)
                .help("String loudness (0 silences it while keeping the row)")
            TextField("", value: store.followerBinding(\.t60), format: .number.precision(.fractionLength(0...2)))
                .frame(width: Typography.scaledWidth(48)).textFieldStyle(.roundedBorder).font(.padCaption)
            Toggle("", isOn: store.followerBinding(\.enabled)).labelsHidden().frame(width: 30)
            Spacer(minLength: 0)
        }
    }
}

private struct TarabTableHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Pitch").frame(width: Typography.scaledWidth(76), alignment: .leading)
            Text("Octave").frame(width: Typography.scaledWidth(64), alignment: .leading)
            Text("Hz").frame(width: Typography.scaledWidth(64), alignment: .leading)
            Text("Gain").frame(width: Typography.scaledWidth(52), alignment: .leading)
            Text("t60").frame(width: Typography.scaledWidth(48), alignment: .leading)
            Text("On").frame(width: 30, alignment: .center)
            Spacer(minLength: 0)
        }
        .font(.padCaption).foregroundStyle(.secondary)
    }
}

private struct StringRow: View {
    @EnvironmentObject var store: SarangiStore
    let id: UUID
    /// The centralized scale's degrees under the scale's own labels — the
    /// pitch dropdown's items.
    let degreeLabels: [String]

    var body: some View {
        if let s = store.state.strings.first(where: { $0.id == id }) {
            HStack(spacing: 6) {
                Picker("", selection: store.stringBinding(id, \.degree)) {
                    ForEach(Array(degreeLabels.enumerated()), id: \.offset) { i, name in
                        Text(name).tag(i)
                    }
                }
                .labelsHidden().frame(width: Typography.scaledWidth(76))
                .help("Scale degree — the pitch, straight from the centralized scale")
                Picker("", selection: store.stringBinding(id, \.octave)) {
                    ForEach(-2...2, id: \.self) { o in
                        Text(o > 0 ? "+\(o)" : "\(o)").tag(o)
                    }
                }
                .labelsHidden().frame(width: Typography.scaledWidth(64))
                .help("Octave shift vs the scale's base octave")
                Text(String(format: "%.1f",
                            s.resolved(tonic: store.state.tonicHz,
                                       scaleRatios: store.state.scaleRatios).freq))
                    .frame(width: Typography.scaledWidth(64), alignment: .leading)
                    .font(.padCaption).foregroundStyle(.secondary)
                TextField("", value: store.stringBinding(id, \.gain), format: .number.precision(.fractionLength(0...2)))
                    .frame(width: Typography.scaledWidth(52)).textFieldStyle(.roundedBorder).font(.padCaption)
                    .help("String loudness (0 silences the string while keeping its row)")
                TextField("", value: store.stringBinding(id, \.t60), format: .number.precision(.fractionLength(0...2)))
                    .frame(width: Typography.scaledWidth(48)).textFieldStyle(.roundedBorder).font(.padCaption)
                Toggle("", isOn: store.stringBinding(id, \.enabled)).labelsHidden().frame(width: 30)
                Button { store.removeStrings([id]) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Drone buttons (map sympathetic strings to the Fret Pad buttons)

private struct DroneMappingSection: View {
    @ObservedObject var controller: AppController
    @EnvironmentObject var store: SarangiStore
    let degreeLabels: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drone buttons").font(.padSubheadline).bold()
            Text("Each Fret Pad drone button plucks ONE of the sympathetic strings above — map up to 3. The MAPPING sets the button's pitch; the VOICE below sets what sounds: the tanpura (default — press plucks, hold re-plucks like a strumming hand, release rings out) or the legacy sympathetic-string swell (press-and-hold; needs the row enabled and picked up by the jawari selection). Regenerating the bank re-runs the automatic mapping (low Sa · low Pa · Sa).")
                .font(.padCaption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Voice")
                    .frame(width: Typography.scaledWidth(60), alignment: .leading)
                    .font(.padCaption)
                Picker("", selection: $controller.droneVoice) {
                    Text("Tanpura").tag(AudioEngine.DroneVoiceMode.tanpura)
                    Text("Sympathetic strings").tag(AudioEngine.DroneVoiceMode.sympathetic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300, alignment: .leading)
            }
            ForEach(0..<InstrumentState.droneSlotCount, id: \.self) { slot in
                HStack(spacing: 6) {
                    Text("Drone \(slot + 1)")
                        .frame(width: Typography.scaledWidth(60), alignment: .leading).font(.padCaption)
                    Picker("", selection: Binding(
                        get: { store.state.droneStringIds.indices.contains(slot)
                                ? store.state.droneStringIds[slot] : nil },
                        set: { store.setDroneMapping(slot: slot, stringId: $0) }
                    )) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.state.strings) { s in
                            Text(stringLabel(s)).tag(UUID?.some(s.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
    }

    private func stringLabel(_ s: StringSpec) -> String {
        let hz = s.resolved(tonic: store.state.tonicHz,
                            scaleRatios: store.state.scaleRatios).freq
        let name = degreeLabels.indices.contains(s.degree) ? degreeLabels[s.degree] : "—"
        let oct = s.octave == 0 ? "" : (s.octave > 0 ? " +\(s.octave)" : " \(s.octave)")
        let dim = s.enabled ? "" : " (off)"
        return String(format: "%@%@ · %.1f Hz%@", name, oct, hz, dim)
    }
}

// (The "Manual tuning" section — raga picker + tonic Set/Transpose/
// Regenerate — was removed 2026-07-25: the bank tunes via scale auto-sync,
// hand edits, or preset loads.)
