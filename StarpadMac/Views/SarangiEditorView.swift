import AppKit
import SarangiKit
import StarpadCore
import SwiftUI

/// The Sarangi tab (⌘3): the played voice's **timbre**. Since the String era
/// the primary surface is the **String instrument's physics parameters**
/// (`StringParamsView` — the `bowed_string.json` scalars, ported from the
/// upstream Sarangi Live editor). The 25 coupled-network params remain below
/// in a collapsed section — they shape the SWAM / sitar base-voice chain
/// only. The sympathetic strings (tarab) + tuning live in the **Tarab** tab
/// (`TarabView`); the FX rack (also SWAM/sitar-path-only) in the FX tab.
/// Backed by `controller.sarangi` (`SarangiStore`) + `controller.stringParams`
/// (`StringParamStore`).
struct SarangiEditorView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: SarangiStore
    @ObservedObject var stringStore: StringParamStore
    @State private var networkExpanded = false

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sarangi
        self.stringStore = controller.stringParams
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SarangiToolbar(controller: controller)
                Divider()
                StringParamsView()
                Divider()
                DisclosureGroup(isExpanded: $networkExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("These parameters drive the coupled bridge–body "
                             + "network that colors the SWAM and sitar base "
                             + "voices. The String instrument (the default "
                             + "voice) does not read them — its sound is the "
                             + "physics panel above + the Tarab tuning.")
                            .font(.caption2).foregroundStyle(.secondary)
                        ParamSlidersSection()
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Coupled network (SWAM / sitar chain)")
                        .font(.subheadline).bold()
                }
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environmentObject(store)
        .environmentObject(stringStore)
    }
}

// MARK: - Toolbar (presets, reset, save/load)

private struct SarangiToolbar: View {
    @ObservedObject var controller: AppController
    @EnvironmentObject var store: SarangiStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sarangi — String instrument").font(.headline)
            HStack(spacing: 8) {
                Menu {
                    ForEach(Preset.allCases, id: \.self) { p in
                        // The Sarangi Live default: the EXACT fitted Pilu tarab
                        // table + tonic (auto-sync turned OFF so the fitted
                        // strings stick — re-enable it in the Tarab tab), the
                        // network params, and the untouched bowed_string.json
                        // physics (every String override cleared).
                        Button(p.displayName) {
                            store.loadSarangiLiveDefault(p)
                            controller.stringParams.resetToDefault()
                        }
                    }
                } label: {
                    Label("Load preset", systemImage: "rectangle.stack")
                }
                .fixedSize()
                Button("Reset network params") { store.resetParams() }
                    .help("Reset the 25 coupled-network parameters (SWAM/sitar chain) to defaults — keeps tuning + strings; does not touch the String physics")
                Spacer()
            }
            HStack(spacing: 8) {
                Button { exportDoc() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                Button { importDoc() } label: { Label("Load…", systemImage: "square.and.arrow.up") }
                Spacer()
            }
            .font(.caption)
        }
    }

    private func exportDoc() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sarangi.sarangi"
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            try? store.save(to: url)
        }
    }

    private func importDoc() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            try? store.load(from: url)
        }
    }
}

// MARK: - Model parameters (22, grouped)

private struct ParamSlidersSection: View {
    @EnvironmentObject var store: SarangiStore
    @State private var expanded: Set<ParamGroup> = Set(ParamGroup.allCases)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model parameters").font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Text("Output").font(.caption).foregroundStyle(.secondary)
                    Slider(value: store.goutBinding, in: 0...2).frame(width: 120)
                }
            }
            // Show every non-empty group. All 22 v57 params are live surface —
            // the room (F_*) and drone ship 0 in the fitted preset but stay
            // playable. (Empty groups hide.)
            ForEach(ParamGroup.allCases.filter { !ParamSpec.grouped($0).isEmpty }, id: \.self) { group in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(group) },
                    set: { if $0 { expanded.insert(group) } else { expanded.remove(group) } })) {
                    VStack(spacing: 2) {
                        ForEach(ParamSpec.grouped(group)) { desc in
                            ParamSlider(desc: desc)
                        }
                    }
                    .padding(.top, 2)
                } label: {
                    Text(group.rawValue).font(.subheadline).bold()
                }
            }
        }
    }
}

private struct ParamSlider: View {
    @EnvironmentObject var store: SarangiStore
    let desc: ParamDescriptor

    var body: some View {
        HStack(spacing: 8) {
            Text(desc.label).frame(width: 130, alignment: .leading).font(.caption)
            Slider(value: store.binding(for: desc), in: desc.lo...desc.hi)
            Text(format(store.state.params[desc.id]))
                .frame(width: 52, alignment: .trailing)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func format(_ v: Double) -> String {
        desc.hi >= 100 ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }
}
