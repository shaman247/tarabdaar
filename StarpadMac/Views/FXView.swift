import SarangiKit
import StarpadCore
import SwiftUI

/// The **FX tab** (⌘4): the sarangi's per-voice FX rack. Three stages — **Violin
/// (main voice)**, **Sympathetic strings**, **Global** — each with the same
/// controls: enable, a reverb (mix + width), a low-pass filter (cutoff +
/// resonance), and a 3-band parametric EQ. Routing: the violin drives the sym
/// bank (in the model), then the violin FX applies, then violin+sym are summed
/// and the global FX applies last. Defaults: Violin ON, Sympathetic OFF, Global
/// OFF. (Replaces the old single block-F reverb / Master-FX section.)
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
                Text("Each stage has its own reverb, low-pass filter, and 3-band EQ. The violin drives the sympathetic bank first, then the violin FX applies; violin + sym are summed and the global FX applies last.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                VoiceFXSection(title: "Violin (main voice)", stage: \.violin,
                               store: store, controller: controller, startExpanded: true)
                Divider()
                VoiceFXSection(title: "Sympathetic strings", stage: \.sym,
                               store: store, controller: controller)
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
    /// Violin section also hosts the SWAM→model Drive.
    private var isViolin: Bool { stage == \FXRack.violin }
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
                if isViolin {
                    row("Drive (SWAM→model)", $controller.sarangiDriveGain, 0...64)
                    Divider().padding(.vertical, 2)
                }
                Text("Reverb").font(.caption).bold().foregroundStyle(.secondary)
                row("Mix", store.fxBinding(stage.appending(path: \.reverbMix), structural: false), 0...1)
                row("Width", store.fxBinding(stage.appending(path: \.reverbWidth), structural: false), 0...1.5)
                Text("Filter (low-pass)").font(.caption).bold().foregroundStyle(.secondary).padding(.top, 4)
                row("Cutoff (Hz)", store.fxBinding(stage.appending(path: \.filterCutoff), structural: true), 200...20000)
                row("Resonance", store.fxBinding(stage.appending(path: \.filterResonance), structural: true), 0...1)
                Text("EQ (3-band parametric)").font(.caption).bold().foregroundStyle(.secondary).padding(.top, 4)
                ForEach(0..<3, id: \.self) { i in eqBand(i) }
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

    private func eqBand(_ i: Int) -> some View {
        HStack(spacing: 6) {
            Text("Band \(i + 1)").frame(width: 54, alignment: .leading).font(.caption2).foregroundStyle(.secondary)
            mini("Hz", store.fxBinding(stage.appending(path: \.eq[i].freq), structural: true), 40...18000)
            mini("dB", store.fxBinding(stage.appending(path: \.eq[i].gainDB), structural: true), -18...18)
            mini("Q", store.fxBinding(stage.appending(path: \.eq[i].q), structural: true), 0.3...8)
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

    private func mini(_ unit: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 3) {
            Slider(value: value, in: range)
            Text(String(format: range.upperBound >= 100 ? "%.0f" : "%.1f", value.wrappedValue) + unit)
                .frame(width: 52, alignment: .trailing).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
