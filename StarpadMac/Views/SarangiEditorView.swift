import AppKit
import SarangiKit
import StarpadCore
import SwiftUI

/// The preset header at the top of the **Parameters** tab.
///
/// 2026-07-24: saves and loads the **instrument** — the sarangi document
/// (tarab table + tonic + model params, which is what the old `.sarangi`
/// file held on its own), the physics overrides, and every parameter's
/// resting value — as a `.starpad` file. The old separate `.sarangi` save
/// is folded in here, and old `.sarangi` files still open.
///
/// The **controls** half (composites + tilt bindings) saves separately
/// from the Controls tab, so loading a new sound never costs you your
/// tilt setup. An older combined `.starpad` can be loaded from either
/// place; each applies only its own half.
struct InstrumentPresetToolbar: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: SarangiStore

    @State private var status: String?

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sarangi
    }

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
                            // Clears the physics overrides AND every
                            // resting parameter value (Parameters tab).
                            controller.resetAllParams()
                            status = "Loaded \(p.displayName)"
                        }
                    }
                } label: {
                    Label("Load preset", systemImage: "rectangle.stack")
                }
                .fixedSize()
                Spacer()
            }
            HStack(spacing: 8) {
                Button { savePreset() } label: {
                    Label("Save instrument…", systemImage: "square.and.arrow.down")
                }
                .help("Save the sarangi instrument, the physics and every parameter value as a .starpad file. Tilt bindings and composites save separately, from the Controls tab.")
                Button { loadPreset() } label: {
                    Label("Load instrument…", systemImage: "square.and.arrow.up")
                }
                .help("Load a .starpad instrument (or an older .sarangi file). Only the instrument half is applied — your composites and tilt bindings are left alone.")
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
        }
    }

    // MARK: - Save / load

    private func savePreset() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Instrument.starpad"
        panel.allowedContentTypes = []
        panel.message = "Saves the instrument: sarangi document, physics and parameter values."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            try controller.savePreset(to: url, name: name, scope: .instrument)
            status = "Saved \(name)"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func loadPreset() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let p = try controller.loadPreset(from: url, scope: .instrument)
            let what = p.sections(in: .instrument)
            status = what.isEmpty
                ? "No instrument in that file\(p.kind == .controls ? " — it is a controls preset" : "")"
                : "Loaded \(what.joined(separator: ", "))"
        } catch {
            status = "Load failed: \(error.localizedDescription)"
        }
    }
}
