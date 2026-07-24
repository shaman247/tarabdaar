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
        }
    }
}
