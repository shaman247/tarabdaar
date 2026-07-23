import SarangiKit
import StarpadCore
import SwiftUI

/// The **FX tab** (⌘5): the sarangi's FX rack. TWO stages since the v57
/// re-vendor (the passive coupled network has one output stream) — **Pre-drive**
/// (shapes the played voice BEFORE it excites the bridge/taraf web) and
/// **Global** (mid/side on the network's output) — each with the same controls:
/// enable, a reverb (mix + width), and an interactive **graphical EQ**
/// (`GraphicalEQView`) — draggable nodes + a live pre/post spectrum, with the
/// stage low-pass folded in as the right-edge node. Both default OFF (the v57
/// ear-law: the ringing taraf IS the room).
struct FXView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: SarangiStore

    init(controller: AppController) {
        self.controller = controller
        self.store = controller.sarangi
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("FX rack").font(.title3).bold()
                Text("Each stage has its own reverb and graphical EQ (drag to add/move nodes; the live spectrum is shown behind the curve). The pre-drive stage shapes the played voice BEFORE it excites the bridge and taraf web; the Global stage applies to the network's stereo output (mid/side). Both default off — the fitted v57 chain is the sound.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                VoiceFXSection(title: "Pre-drive (voice → network)", stage: \.violinPre,
                               store: store, controller: controller, startExpanded: true)
                Divider()
                VoiceFXSection(title: "Global", stage: \.global,
                               store: store, controller: controller)
            }
            .padding(16)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct VoiceFXSection: View {
    let title: String
    let stage: WritableKeyPath<FXRack, VoiceFXParams>
    @ObservedObject var store: SarangiStore
    @ObservedObject var controller: AppController
    var startExpanded: Bool = false
    /// The pre-drive section also hosts the source→model Drive trim.
    private var isPreDrive: Bool { stage == \FXRack.violinPre }
    @State private var expanded: Bool

    init(title: String, stage: WritableKeyPath<FXRack, VoiceFXParams>,
         store: SarangiStore, controller: AppController, startExpanded: Bool = false) {
        self.title = title; self.stage = stage; self.store = store
        self.controller = controller; self.startExpanded = startExpanded
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if isPreDrive {
                    row("Drive (source→model)", $controller.sarangiDriveGain, 0...64)
                    Divider().padding(.vertical, 2)
                }
                Text("Reverb").font(.caption).bold().foregroundStyle(.secondary)
                row("Mix", store.fxBinding(stage.appending(path: \.reverbMix), structural: false), 0...1)
                row("Width", store.fxBinding(stage.appending(path: \.reverbWidth), structural: false), 0...1.5)
                Text("EQ").font(.caption).bold().foregroundStyle(.secondary).padding(.top, 4)
                GraphicalEQView(stage: stage, store: store, spectrum: controller.spectrum)
                    .frame(maxWidth: .infinity)
            }
            .padding(.leading, 8).padding(.top, 4)
        } label: {
            HStack {
                Toggle(isOn: store.fxToggleBinding(stage.appending(path: \.enabled))) {
                    Text(title).font(.subheadline).bold()
                }
                .toggleStyle(.switch)
                Spacer()
            }
        }
    }

    private func row(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 130, alignment: .leading).font(.caption)
            Slider(value: value, in: range)
            Text(String(format: range.upperBound >= 100 ? "%.0f" : "%.2f", value.wrappedValue))
                .frame(width: 56, alignment: .trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
