import TarabdaarCore
import SwiftUI

/// Combined configuration surface: Audio, MIDI, and Connection in one
/// scroll-friendly stack. Previously three separate sidebar sections —
/// folded together so they're one click from the top-level Setup tab.
struct SetupView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AudioSettingsView(controller: controller)
                    .padding(.bottom, 8)
                Divider()
                MIDISettingsView(controller: controller)
                    .padding(.bottom, 8)
                Divider()
                ConnectionStatusView(controller: controller)
                Divider()
                JoyConStatusView(controller: controller)
            }
        }
    }
}
