import TarabdaarCore
import SarangiKit
import SwiftUI

/// The Parameters tab — **the** parameter surface.
/// Every parameter of the String instrument lives here in one list: the
/// bow-stroke axes, the `bowed_string.json` physics scalars, the live
/// taraf/tone axes and the FX rack. Each row shows the parameter's value
/// in native units and a mapping button that binds it to a tilt or drops
/// it into a composite — no parameter is special.
///
/// Apply semantics come from `ParamRegistry`, and each row's description
/// states the SHARED scope/timing vocabulary (`ParamScope`/`ParamTiming`
/// — the same strings paramdoc renders into docs/parameters.md).
///
/// Built for ~200 rows. The list is a `LazyVStack` with pinned group
/// headers, so only the rows on screen exist; each row is an `Equatable`
/// view fed a value snapshot (`ParamRowModel`) instead of the controller,
/// so a slider tick or a binding edit re-renders the one row it touched;
/// and the mapping menu is a popover built on demand rather than a
/// resident `Menu` per row (AppKit menus are the most expensive widget on
/// the tab, and 200 of them made the old tab take seconds to appear).
struct ParametersView: View {
    @ObservedObject var controller: AppController
    /// Observed so `.rebuild` rows (whose values live in the physics
    /// store) redraw when the store changes.
    @ObservedObject var stringStore: StringParamStore

    init(controller: AppController) {
        self.controller = controller
        self.stringStore = controller.stringParams
    }

    @State private var search = ""
    @State private var filter: RowFilter = .all
    /// Groups start OPEN — the tab is a reference surface, and with pinned
    /// headers and lazy rows a long list costs only the scroll.
    @State private var collapsed: Set<String> = []
    /// Insert sections (the FX rack's four points) start CLOSED: the knobs
    /// of an untouched insert are all zeros. The header row carries the
    /// state worth seeing at a glance.
    @State private var openInserts: Set<String> = []
    @State private var confirmResetAll = false
    @FocusState private var searchFocused: Bool

    enum RowFilter: String, CaseIterable, Identifiable {
        case all = "All", changed = "Changed", mapped = "Mapped"
        var id: String { rawValue }
    }

    // MARK: - Sections

    private struct GroupSection: Identifiable {
        let name: String
        let flat: [ParamSpec]
        let inserts: [(point: FXInsertPoint, params: [ParamSpec])]
        let count: Int
        let changed: Int
        var id: String { name }
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }
    private var searching: Bool { !query.isEmpty }

    /// Groups after the search box and the filter chip (empty groups
    /// drop out). Cheap enough to recompute per render: a few dictionary
    /// lookups per parameter.
    private var sections: [GroupSection] {
        let q = query
        return ParamRegistry.groups.compactMap { g in
            let hits = g.params.filter { matches($0, q) }
            guard !hits.isEmpty else { return nil }
            let split = ParamRegistry.insertSections(of: hits)
            return GroupSection(
                name: g.name, flat: split.flat, inserts: split.inserts,
                count: hits.count,
                changed: hits.filter { !controller.paramIsDefault($0.key) }.count)
        }
    }

    private func matches(_ spec: ParamSpec, _ q: String) -> Bool {
        switch filter {
        case .all: break
        case .changed:
            guard !controller.paramIsDefault(spec.key) else { return false }
        case .mapped:
            guard isMapped(spec.key) else { return false }
        }
        guard !q.isEmpty else { return true }
        return spec.label.lowercased().contains(q)
            || spec.key.lowercased().contains(q)
            || spec.help.lowercased().contains(q)
    }

    private func isMapped(_ key: String) -> Bool {
        !controller.tiltDimensions(for: MapTarget(paramKey: key)).isEmpty
            || !controller.compositesContaining(key).isEmpty
    }

    private func isOpen(_ group: String) -> Bool {
        searching || !collapsed.contains(group)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                PresetToolbar(controller: controller)
                Divider()
                filterBar
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            Divider()
            list
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter parameters (⌘F)", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if searching {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12)))
            .frame(maxWidth: 300)
            // ⌘F lands in the filter box from anywhere on the tab.
            .background(
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0))
            Picker("", selection: $filter) {
                ForEach(RowFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("All rows; only rows moved off their default; only rows driven by a tilt or a composite")
            Spacer()
            Button(collapsed.isEmpty ? "Collapse all" : "Expand all") {
                collapsed = collapsed.isEmpty
                    ? Set(ParamRegistry.groups.map(\.name)) : []
            }
            .disabled(searching)
            Button("Reset all…") { confirmResetAll = true }
                .help("Back to the shipped default: the Sarangi Live artifact physics and every resting value")
                .confirmationDialog(
                    "Reset every parameter to the shipped default?",
                    isPresented: $confirmResetAll, titleVisibility: .visible) {
                    Button("Reset all", role: .destructive) {
                        controller.resetAllParams()
                    }
                } message: {
                    Text("Clears every physics override, resting value and FX curve. Composites and tilt bindings are kept.")
                }
        }
        .font(.padCaption)
    }

    private var list: some View {
        ScrollView {
            let sections = self.sections
            LazyVStack(alignment: .leading, spacing: 2,
                       pinnedViews: [.sectionHeaders]) {
                Text("Values are where a parameter rests when nothing drives it; tilts and composites modulate on top. Click a label for its description, scope and timing; double-click it to reset. Click a readout to type a value.")
                    .font(.padCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                ForEach(sections) { section in
                    Section {
                        if isOpen(section.name) {
                            ForEach(section.flat) { spec in
                                row(spec, label: nil)
                            }
                            ForEach(section.inserts, id: \.point.id) { ins in
                                insertHeader(ins.point)
                                if searching
                                    || openInserts.contains(ins.point.keyPrefix) {
                                    ForEach(ins.params) { spec in
                                        // inside the point's own section the
                                        // row drops the point qualifier the
                                        // menus need
                                        row(spec, label: spec.insert?.knobLabel)
                                    }
                                }
                            }
                            Color.clear.frame(height: 10)
                        }
                    } header: {
                        groupHeader(section)
                    }
                }
                if sections.isEmpty {
                    Text("No parameters match.")
                        .foregroundStyle(.secondary)
                        .font(.padCaption)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ spec: ParamSpec, label: String?) -> some View {
        ParamRow(controller: controller, spec: spec, label: label,
                 model: model(spec))
            .equatable()
    }

    /// The row's value snapshot — computed only for rows on screen (the
    /// lazy stack calls this from its cell builder).
    private func model(_ spec: ParamSpec) -> ParamRowModel {
        ParamRowModel(
            value: controller.paramValue(spec.key),
            def: controller.paramDefault(spec.key),
            tilts: controller.tiltDimensions(for: MapTarget(paramKey: spec.key)),
            composites: controller.compositesContaining(spec.key)
                .map { CompositeChip(id: $0.id, name: $0.name) })
    }

    // MARK: - Headers

    /// A group's header: name, row count, how many rows sit off their
    /// default. Click to collapse; it pins to the top while scrolling.
    private func groupHeader(_ s: GroupSection) -> some View {
        let open = isOpen(s.name)
        return Button {
            if collapsed.contains(s.name) { collapsed.remove(s.name) }
            else { collapsed.insert(s.name) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.padCaption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                Text(s.name).font(.padSubheadline).bold()
                Text("\(s.count)")
                    .font(.padCaption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if s.changed > 0 {
                    Text("\(s.changed) changed")
                        .font(.padCaption2.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// One insert point: a header row (name, what it is currently doing,
    /// what it processes) that opens onto the point's own knobs.
    private func insertHeader(_ point: FXInsertPoint) -> some View {
        let open = searching || openInserts.contains(point.keyPrefix)
        return Button {
            if openInserts.contains(point.keyPrefix) {
                openInserts.remove(point.keyPrefix)
            } else {
                openInserts.insert(point.keyPrefix)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.padCaption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                Text(point.name).font(.padCaption).bold()
                Text(insertState(point))
                    .font(.padCaption2.monospacedDigit())
                    .foregroundStyle(insertIsActive(point)
                                     ? Color.accentColor : .secondary)
                Text(point.blurb)
                    .font(.padCaption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
    }

    private func insertIsActive(_ point: FXInsertPoint) -> Bool {
        controller.paramValue(point.key("eq_on")) >= 0.5
            || controller.paramValue(point.key("rev_on")) >= 0.5
    }

    /// The header's one-line state: the two toggles, plus the reverb it
    /// would run (the summary that makes the collapsed rows safe to hide).
    private func insertState(_ point: FXInsertPoint) -> String {
        var parts: [String] = []
        if controller.paramValue(point.key("eq_on")) >= 0.5 {
            let n = controller.eqCurve(point.keyPrefix).count
            parts.append(n == 0 ? "EQ on (flat)" : "EQ \(n) pt\(n == 1 ? "" : "s")")
        }
        if controller.paramValue(point.key("rev_on")) >= 0.5 {
            let room = controller.paramValue(point.key("rev_type")) >= 0.5
            let mix = controller.paramValue(point.key("rev_mix"))
            parts.append(String(format: "%@ %.0f%% wet",
                                room ? "Room" : "Bigverb", 100 * mix))
        }
        return parts.isEmpty ? "off" : parts.joined(separator: " · ")
    }
}


// MARK: - One parameter row

/// What a row shows, as plain values: comparing two of these is what lets
/// an unchanged row skip its body when the controller publishes.
private struct CompositeChip: Equatable, Identifiable {
    let id: CompositeParam.ID
    let name: String
}

private struct ParamRowModel: Equatable {
    let value: Double
    let def: Double
    let tilts: [InputDimension]
    let composites: [CompositeChip]
    var isDefault: Bool { abs(value - def) <= 1e-9 }
    var isMapped: Bool { !tilts.isEmpty || !composites.isEmpty }
}

/// Label · slider (native range) · readout · mapping chips · mapping
/// button · reset. The row holds the controller for its ACTIONS only — it
/// deliberately does not observe it; its inputs are the snapshot.
private struct ParamRow: View, Equatable {
    let controller: AppController
    let spec: ParamSpec
    /// Row label override — an insert section names its own point, so the
    /// rows inside it show the bare knob label (see `ParamInsert`).
    let label: String?
    let model: ParamRowModel

    /// Tooltips are unreliable, so a single click on the label expands the
    /// help text inline under the row instead.
    @State private var showHelp = false
    @State private var showMapping = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    static func == (a: ParamRow, b: ParamRow) -> Bool {
        a.spec.key == b.spec.key && a.label == b.label && a.model == b.model
    }

    /// The authored range is an AUTHORING HINT, the artifact is truth: a
    /// fit round moves values wherever the physics wants them, so a loaded
    /// value outside [lo, hi] widens the slider instead of being
    /// snap-clamped by the first drag.
    private var bounds: ClosedRange<Double> {
        let v = model.value
        guard v < spec.lo || v > spec.hi else { return spec.lo...spec.hi }
        let pad = max((spec.hi - spec.lo) * 0.25, abs(v) * 0.25)
        return min(spec.lo, v - pad)...max(spec.hi, v + pad)
    }

    private func set(_ v: Double) {
        let stepped = spec.step.map { (v / $0).rounded() * $0 } ?? v
        controller.setParamValue(spec.key, stepped)
    }

    private var binding: Binding<Double> {
        Binding(get: { model.value }, set: { set($0) })
    }

    /// Stepped params read as whole numbers, and so do the ranges that run
    /// to 100+ (Hz, cents, ms) whatever the current value.
    private func format(_ v: Double) -> String {
        ParamFormat.value(v, decimals: 3, integer: spec.step != nil,
                          integerAbove: spec.hi >= 100 ? 0 : .infinity)
    }

    /// Scope + timing come from the SHARED vocabulary in `ParamRegistry`
    /// (`ParamScope`/`ParamTiming.summary`) — the same strings paramdoc
    /// renders into docs/parameters.md, so this description can never
    /// tell a different story than the documentation.
    private var helpText: String {
        spec.help
            + "\n\nScope: \(spec.scope.label) — \(spec.scope.summary)."
            + "\nTiming: \(spec.timing.label) — \(spec.timing.summary)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if showHelp {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.key)
                        .font(.padCaption2.monospaced())
                    Text(helpText)
                        .foregroundStyle(.secondary)
                }
                .font(.padCaption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 8)
                .padding(.bottom, 4)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Text(label ?? spec.label)
                .font(.padCaption)
                .foregroundStyle(showHelp ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .frame(width: Typography.scaledWidth(150), alignment: .leading)
                .contentShape(Rectangle())
                .help(spec.help)
                // The single tap must fire immediately — an exclusive
                // double/single composition holds it for the double-click
                // window, which reads as lag. Simultaneous recognition
                // means a double-click's two single taps also fire; the
                // reset handler pins the help open so the net state is
                // deterministic (reset + help shown).
                .onTapGesture { showHelp.toggle() }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    controller.resetParam(spec.key)
                    showHelp = true
                })
            Slider(value: binding, in: bounds)
            readout
            mappingChips
            Button { showMapping = true } label: {
                Image(systemName: model.isMapped
                      ? "slider.horizontal.below.square.filled.and.square"
                      : "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isMapped ? Color.accentColor : .secondary)
            .help("Bind this parameter to a tilt, or add it to a composite")
            .popover(isPresented: $showMapping, arrowEdge: .trailing) {
                MappingPopover(controller: controller, spec: spec)
            }
            Button {
                controller.resetParam(spec.key)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset to \(format(model.def))")
            .opacity(model.isDefault ? 0.25 : 1)
            .disabled(model.isDefault)
        }
    }

    /// The value, or a field to type one — any finite number is accepted,
    /// and the slider widens to reach it.
    @ViewBuilder private var readout: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.padCaption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: Typography.scaledWidth(64))
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.15)))
                .focused($draftFocused)
                .onSubmit { commitDraft() }
                .onExitCommand { editing = false }
                .onChange(of: draftFocused) { focused in
                    if !focused && editing { commitDraft() }
                }
        } else {
            Text(format(model.value))
                .font(.padCaption.monospacedDigit())
                .foregroundStyle(model.isDefault ? .secondary : .primary)
                .frame(width: Typography.scaledWidth(64), alignment: .trailing)
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
                .help("Click to type a value")
                .onTapGesture {
                    draft = "\(model.value)"
                    editing = true
                    DispatchQueue.main.async { draftFocused = true }
                }
        }
    }

    private func commitDraft() {
        editing = false
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard let v = Double(text), v.isFinite else { return }
        set(v)
    }

    /// Compact read-out of what drives this parameter: tilt chips + the
    /// composites it belongs to.
    private var mappingChips: some View {
        HStack(spacing: 3) {
            ForEach(model.tilts, id: \.rawValue) { d in
                Text(d.shortLabel)
                    .font(.padCaption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 3))
            }
            ForEach(model.composites) { c in
                Text(c.name)
                    .font(.padCaption2)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .frame(width: Typography.scaledWidth(130), alignment: .leading)
    }
}


// MARK: - Mapping popover

/// Where a parameter's drive comes from, as checkboxes: every dimension,
/// every composite, and a button to start a composite from this one.
/// Built only while shown; observes the controller so ticks update live.
private struct MappingPopover: View {
    @ObservedObject var controller: AppController
    let spec: ParamSpec

    private var target: MapTarget { MapTarget(paramKey: spec.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(spec.label).font(.headline)
            Text("Drive with a dimension")
                .font(.padCaption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 4) {
                ForEach(ControlAxes.dims, id: \.rawValue) { dim in
                    Toggle(dim.label, isOn: Binding(
                        get: { controller.tiltMapping.isConnected(target, dim) },
                        set: { _ in controller.toggleTiltBinding(target, dim: dim) }))
                }
            }
            Divider()
            Text("Composites")
                .font(.padCaption).foregroundStyle(.secondary)
            if controller.composites.isEmpty {
                Text("No composites yet")
                    .font(.padCaption).foregroundStyle(.tertiary)
            }
            ForEach(controller.composites) { c in
                Toggle(c.name, isOn: Binding(
                    get: { c.members.contains { $0.key == spec.key } },
                    set: { _ in controller.toggleCompositeMember(c.id, key: spec.key) }))
            }
            Button("New composite from this") {
                if let c = controller.addComposite() {
                    controller.renameComposite(c.id, to: spec.label)
                    controller.addCompositeMember(c.id, key: spec.key)
                }
            }
            .disabled(controller.composites.count >= CompositeParam.maxSlots)
            .font(.padCaption)
        }
        .toggleStyle(.checkbox)
        .font(.padCaption)
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}
