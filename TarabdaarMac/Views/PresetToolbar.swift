import SarangiKit
import TarabdaarCore
import SwiftUI

/// The preset header at the top of the **Parameters** tab.
///
/// ONE preset, one list, no file panels. A preset is the whole
/// rig — the sarangi document (tarab table + tonic + model params), the
/// physics overrides, every parameter's resting value, the composites and
/// the tilt bindings. **Save preset…** asks only for a name; the preset
/// lands in the app-managed library (`PresetLibrary`,
/// `Application Support/Tarabdaar/Presets/`) and appears in the **Load
/// preset** menu automatically, right under the factory default(s).
struct PresetToolbar: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: SarangiStore

    @State private var status: String?
    @State private var savePopoverShown = false
    @State private var saveName = ""

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sarangi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sarangi — String instrument").font(.headline)
            HStack(spacing: 8) {
                Menu {
                    // The factory default, as a FULL rig: the generated
                    // bank + untouched bowed_string.json physics (every
                    // override and resting value cleared) + the default
                    // composites and tilt bindings.
                    let factory = Preset.sarangiPilu
                    Button(factory.displayName) {
                        controller.loadFactoryPreset(factory)
                        status = "Loaded \(factory.displayName)"
                    }
                    if !controller.savedPresetNames.isEmpty {
                        Divider()
                        ForEach(controller.savedPresetNames, id: \.self) { name in
                            Button(name) { load(name) }
                        }
                        Divider()
                        Menu("Delete preset") {
                            ForEach(controller.savedPresetNames, id: \.self) { name in
                                Button(name, role: .destructive) { delete(name) }
                            }
                        }
                    }
                } label: {
                    Label("Load preset", systemImage: "rectangle.stack")
                }
                .fixedSize()
                .help("Load a preset — the factory default or any saved preset. A preset is the whole rig: instrument, parameter values, composites and tilt bindings.")
                Button { savePopoverShown = true } label: {
                    Label("Save preset…", systemImage: "square.and.arrow.down")
                }
                .help("Save the whole rig — sarangi document, physics, parameter values, composites and tilt bindings — as a named preset in the list.")
                .popover(isPresented: $savePopoverShown, arrowEdge: .bottom) {
                    savePopover
                }
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .font(.padCaption)
        }
        .onAppear { controller.refreshPresetLibrary() }
    }

    /// Name-only save: no file panel, the library owns the location.
    /// Saving under an existing name overwrites that preset.
    private var savePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save preset").font(.headline)
            TextField("Preset name", text: $saveName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { save() }
            HStack {
                if controller.savedPresetNames.contains(
                    where: { $0.caseInsensitiveCompare(saveName.trimmingCharacters(in: .whitespaces)) == .orderedSame }) {
                    Text("Replaces the existing preset")
                        .font(.padCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    // MARK: - Save / load / delete

    private func save() {
        do {
            let name = try controller.savePresetToLibrary(name: saveName)
            status = "Saved \(name)"
            savePopoverShown = false
            saveName = ""
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func load(_ name: String) {
        do {
            let p = try controller.loadPresetFromLibrary(name: name)
            let what = p.sections()
            status = what.isEmpty
                ? "Nothing to load in \(name)"
                : "Loaded \(name) — \(what.joined(separator: ", "))"
        } catch {
            status = "Load failed: \(error.localizedDescription)"
        }
    }

    private func delete(_ name: String) {
        do {
            try controller.deletePresetFromLibrary(name: name)
            status = "Deleted \(name)"
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }
}
