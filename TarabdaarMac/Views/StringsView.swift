import AppKit
import SarangiKit
import TarabdaarCore
import SwiftUI

/// Two taraf banks, edited through matching tables and bank-local actions.
/// Raga uses physical contact rows; chromatic includes the melody follower.
struct StringsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: SarangiStore

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sarangi
    }

    /// The scale's own labels, index-aligned with the document's `scaleRatios`
    /// mirror. The push is debounced, so a degree the labels haven't caught
    /// up with shows its ratio rather than a neighbour's name.
    private var degreeLabels: [String] {
        let labels = scaleDegrees(from: controller.pitchPad.scale).map(\.label)
        return store.state.scaleRatios.indices.map { i in
            i < labels.count ? labels[i]
                             : String(format: "%.3f", store.state.scaleRatios[i])
        }
    }

    /// The chromatic bridge's 12 semitone labels: the scale's own label where
    /// it has a degree at that JI pitch, else the grid fraction. Prefixed
    /// with the semitone number.
    private var chromaticLabels: [String] {
        let degrees = scaleDegrees(from: controller.pitchPad.scale)
        return (0..<12).map { k in
            let r = RagaTuning.chromaticRatio(semitone: k)
            let name = degrees.first { abs(1200.0 * log2($0.ratio / r)) < 1.0 }?.label
            let label = (name?.isEmpty == false) ? name! : RagaTuning.chromaticFractions[k]
            return "+\(k) \(label)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PerformanceProfileView(controller: controller)
                Divider()
                HeaderSection(controller: controller)
                Divider()
                StringsSection(bridge: .raga, degreeLabels: degreeLabels,
                               regenerate: { controller.syncTarabFromScale(force: true) })
                Divider()
                StringsSection(bridge: .chromatic,
                               degreeLabels: chromaticLabels,
                               regenerate: { store.regenerateChromatic() },
                               scaleLabels: degreeLabels)
                Divider()
                DroneMappingSection(controller: controller,
                                    degreeLabels: degreeLabels)
                Divider()
                StrumMappingSection(degreeLabels: degreeLabels)
            }
            .padding(16)
            .frame(maxWidth: 1000, alignment: .leading)
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
            HStack(spacing: 8) {
                Text(String(format: "Tonic %.2f Hz · %@", store.state.tonicHz, noteName(store.state.tonicHz)))
                    .font(.padCaption).foregroundStyle(.secondary)
            }
        }
    }

    private func noteName(_ hz: Double) -> String {
        NoteName.name(forMIDI: Pitch.nearestMidi(hz: hz))
    }
}

// MARK: - The string pool

/// One bridge's table; the legacy melody follower lives with the chromatic bank.
private struct StringsSection: View {
    @EnvironmentObject var store: SarangiStore
    let bridge: TarabSet
    let degreeLabels: [String]
    let regenerate: () -> Void

    var scaleLabels: [String] = []
    private var rows: [StringSpec] { store.state.strings(in: bridge) }
    private var title: String {
        bridge == .raga ? "Raga taraf" : "Chromatic taraf"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.padSubheadline).bold()
                Text("(\(rows.count))").font(.padCaption).foregroundStyle(.secondary)
                Spacer()
                Button(bridge == .raga ? "Regenerate from scale" : "Reset chromatic set",
                       action: regenerate)
                    .font(.padCaption)
                let allOn = !rows.isEmpty && rows.allSatisfy(\.enabled)
                Button(allOn ? "Disable all" : "Enable all") {
                    store.setAllEnabled(!allOn, in: bridge)
                }
                    .font(.padCaption).disabled(rows.isEmpty)
                Button { store.addString(to: bridge) } label: { Image(systemName: "plus") }
                    .help(bridge == .raga ? "Add a raga string" : "Add a chromatic string")
            }
            if bridge == .chromatic { FollowerRow() }
            if rows.isEmpty && bridge == .chromatic {
                Text("—")
                    .font(.padCaption2).foregroundStyle(.tertiary)
            } else if rows.isEmpty {
                Text("—").font(.padCaption2).foregroundStyle(.tertiary)
            } else {
                TarabTableHeader(bridge: bridge)
                LazyVStack(spacing: 2) {
                    ForEach(rows) { s in
                        StringRow(id: s.id, degreeLabels: s.followsScale && bridge == .chromatic ? scaleLabels : degreeLabels)
                    }
                }
            }
        }
    }
}

/// The melody-follower row, pinned above the chromatic pool: its pitch
/// live-retunes to the highest note being played. Same Gain / t60 / On
/// knobs; no octave or Hz readout; not a drone-button target.
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
    var bridge: TarabSet = .raga
    var body: some View {
        HStack(spacing: 6) {
            Text("Pitch")
                .frame(width: Typography.scaledWidth(76), alignment: .leading)
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
                .help(s.followsScale
                      ? "Scale degree — the pitch, straight from the centralized scale"
                      : "Semitone above the tonic on the fixed JI chromatic grid (named by the scale where it has that pitch)")
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
            Text("Each Fret Pad drone button plucks ONE of the sympathetic strings above — map up to 3. The MAPPING sets the button's pitch; the VOICE below sets what sounds: the tanpura (default — press plucks, hold re-plucks like a strumming hand, release rings out) or the sympathetic-string swell (press-and-hold; needs the row enabled and picked up by the jawari selection). Regenerating the bank re-runs the automatic mapping (low Sa · low Pa · Sa).")
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
            Text("Drone sequence (Down / GL)").font(.padSubheadline).bold()
            HStack {
                Text("Tanpura octave")
                Text(controller.tanpuraDroneOctaveRaised ? "0" : "−1")
                    .monospacedDigit()
            }
            .font(.padCaption)
            ForEach(controller.droneSequenceSteps.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Text("Step \(index + 1)")
                        .frame(width: Typography.scaledWidth(60), alignment: .leading)
                        .font(.padCaption)
                    Picker("Step \(index + 1)", selection: Binding(
                        get: { controller.droneSequenceSteps[index] },
                        set: { controller.droneSequenceSteps[index] = $0 }
                    )) {
                        ForEach(0..<InstrumentState.droneSlotCount, id: \.self) { slot in
                            Text(droneLabel(slot)).tag(slot)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    Button {
                        controller.droneSequenceSteps.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(controller.droneSequenceSteps.count == 1)
                    .accessibilityLabel("Remove step \(index + 1)")
                }
            }
            HStack {
                Button("Add step") { controller.droneSequenceSteps.append(2) }
                Button("Reset sequence") {
                    controller.droneSequenceSteps = DroneSequence.defaultSteps
                }
            }
        }
    }

    private func droneLabel(_ slot: Int) -> String {
        let id = store.state.droneStringIds.indices.contains(slot)
            ? store.state.droneStringIds[slot] : nil
        let label = store.state.strings.first { $0.id == id }.map(stringLabel) ?? "None"
        return "Drone \(slot + 1) · \(label)"
    }

    private func stringLabel(_ s: StringSpec) -> String {
        tarabStringLabel(s, state: store.state, degreeLabels: degreeLabels)
    }
}

// MARK: - Controller strum (the Joy-Con L button's string set)

private struct StrumMappingSection: View {
    @EnvironmentObject var store: SarangiStore
    let degreeLabels: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Controller strum").font(.padSubheadline).bold()
            Text("Holding the Joy-Con L button sounds these strings all at once as a HELD CHORD in the main voice (the Live tab's instrument — bowed String by default), like fingers planted on the playing surface: fresh strings, full articulation, taraf charge and all. The chord sustains while L is held and releases with the button. \"Strum expression\" (Parameters tab, Controller group — bound to the stick Y by default) is the chord's own loudness, live-swellable while it rings; \"strum accel trigger\" lets a hard shake of the iPad strike the chord without the button (127 = off). Members reference the bank above as scale degrees, so a configured chord follows the raga/scale. Defaults to low Sa · low Pa; regenerating the bank restores the default.")
                .font(.padCaption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(store.state.strumStringIds.enumerated()),
                    id: \.element) { index, id in
                HStack(spacing: 6) {
                    Text("String \(index + 1)")
                        .frame(width: Typography.scaledWidth(60), alignment: .leading)
                        .font(.padCaption)
                    Picker("", selection: Binding(
                        get: { id },
                        set: { store.setStrumMapping(index: index, stringId: $0) }
                    )) {
                        ForEach(store.state.strings) { s in
                            Text(stringLabel(s)).tag(s.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    Button {
                        store.removeStrumString(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this string from the strum")
                }
            }
            if let candidate = store.state.strings.first(where: {
                !store.state.strumStringIds.contains($0.id)
            }) {
                Button {
                    store.addStrumString(candidate.id)
                } label: {
                    Label("Add string", systemImage: "plus.circle")
                        .font(.padCaption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func stringLabel(_ s: StringSpec) -> String {
        tarabStringLabel(s, state: store.state, degreeLabels: degreeLabels)
    }
}

/// A string as the mapping dropdowns name it: the scale's label (raga) or
/// the semitone + grid fraction (chromatic, marked), octave, Hz, on/off.
private func tarabStringLabel(_ s: StringSpec, state: InstrumentState,
                              degreeLabels: [String]) -> String {
    let hz = s.resolved(tonic: state.tonicHz, scaleRatios: state.scaleRatios).freq
    let name: String
    if !s.followsScale {
        let k = ((s.degree % 12) + 12) % 12
        name = "chromatic +\(k) (\(RagaTuning.chromaticFractions[k]))"
    } else {
        let label = degreeLabels.indices.contains(s.degree) ? degreeLabels[s.degree] : "—"
        name = s.set == .chromatic ? "chromatic \(label)" : label
    }
    let oct = s.octave == 0 ? "" : (s.octave > 0 ? " +\(s.octave)" : " \(s.octave)")
    let dim = s.enabled ? "" : " (off)"
    return String(format: "%@%@ · %.1f Hz%@", name, oct, hz, dim)
}
