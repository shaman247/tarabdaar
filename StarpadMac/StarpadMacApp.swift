import StarpadCore
import SwiftUI

@main
struct StarpadMacApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        WindowGroup("Starpad") {
            MacMainWindow(controller: controller)
                .frame(minWidth: 900, idealWidth: 1100,
                       minHeight: 520, idealHeight: 640)
                .onAppear {
                    controller.start()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            // No "New Window" — single-window app.
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Preset") {
                ForEach(Array(SoundPreset.allCases.enumerated()), id: \.element.rawValue) { i, preset in
                    Button(preset.label) {
                        controller.applyPreset(preset)
                    }
                    // ⌘1 .. ⌘8 quick-apply for the first eight presets.
                    .keyboardShortcut(presetShortcut(for: i),
                                      modifiers: i < 9 ? .command : [])
                }
            }
        }
    }

    private func presetShortcut(for index: Int) -> KeyEquivalent {
        guard index < 9 else { return KeyEquivalent("0") }
        return KeyEquivalent(Character("\(index + 1)"))
    }
}
