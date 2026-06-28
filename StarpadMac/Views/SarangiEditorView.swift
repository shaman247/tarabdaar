import AppKit
import SarangiKit
import StarpadCore
import SwiftUI

/// The Sarangi tab (⌘2): the sarangi model's **timbre** — presets, the 27 model
/// parameters, and a compact master-FX section (which now shapes only the
/// tanpura/sitar, since the sarangi owns its own body + reverb). The sympathetic
/// strings (tarab) + tuning live in their own **Sympathetic Strings** tab
/// (`TarabView`). Backed by `controller.sarangi` (`SarangiStore`); the master-FX
/// knobs bind to the `AppController` directly.
struct SarangiEditorView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: SarangiStore

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sarangi
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SarangiToolbar(controller: controller)
                Divider()
                ParamSlidersSection()
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environmentObject(store)
    }
}

// MARK: - Toolbar (presets, reset, save/load)

private struct SarangiToolbar: View {
    @ObservedObject var controller: AppController
    @EnvironmentObject var store: SarangiStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sarangi model").font(.headline)
            HStack(spacing: 8) {
                Menu {
                    ForEach(Preset.allCases, id: \.self) { p in
                        // Load timbre (params + FIR + strings); re-sync the tarab
                        // to the Pitch Pad scale if auto-sync is on.
                        Button(p.displayName) { store.loadPreset(p); controller.syncTarabFromScale() }
                    }
                } label: {
                    Label("Load preset", systemImage: "rectangle.stack")
                }
                .fixedSize()
                Button("Reset params") { store.resetParams() }
                    .help("Reset the 27 model parameters to defaults (keeps tuning + strings)")
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

// MARK: - Model parameters (27, grouped)

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
            // Show every non-empty group, including Reverb: the sarangi now runs
            // its OWN block-F reverb (matching Sarangi Live) and bypasses Starpad's
            // master FX, so the F_* params are live. (Empty groups e.g. Drone hide.)
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
