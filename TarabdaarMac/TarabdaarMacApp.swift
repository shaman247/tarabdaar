import TarabdaarCore
import SwiftUI

@main
struct TarabdaarMacApp: App {
    @StateObject private var controller = AppController()

    init() {
        // Starpad/TarabPad → Tarabdaar identity migration . Must run
        // before AppController exists — its stores read UserDefaults and
        // the preset library at init.
        LegacyMigration.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup("Tarabdaar") {
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
        }
    }
}
