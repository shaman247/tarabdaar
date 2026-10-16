import CoreAudioKit
import QuartzCore
import TarabdaarCore
import SwiftUI

/// The iPad's playing surface is the Fret Pad (`FretPadViewIOS`). Touches
/// resolve to pitch via `FretPadGeometry` and ride the outbound TLP state with
/// the RAW tilt axes — the iPad evaluates no bindings. Scale + fret editing
/// live on the Mac and sync here over TLP events.

// MARK: - Shared pad toolbar (iPad)

/// Connection problems overlay the pad without moving its touch geometry.
struct PadToolbarIOS: View {
    @ObservedObject var scaleSync: ScaleSyncReceiver
    @ObservedObject var midi: MIDIEngine

    var body: some View {
        if !scaleSync.connection.isSynced {
            HStack(spacing: 14) {
                ScaleSyncIndicator(scaleSync: scaleSync)
                Spacer(minLength: 12)
                if !scaleSync.connection.isConnected {
                    TransportIndicatorsIOS(midi: midi)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black)
        }
    }
}

// MARK: - Transport indicators + Bluetooth MIDI (BLE-MIDI advertise)

/// Connection controls shown only while the TLP link is unavailable.
/// White icons are available transports; dim gray icons are absent.
/// The antenna presents the system BLE-MIDI peripheral sheet so the iPad
/// can advertise (the Mac connects from Audio MIDI Setup → Bluetooth);
/// advertising is per-session.
private struct TransportIndicatorsIOS: View {
    @ObservedObject var midi: MIDIEngine
    @State private var showBluetoothSheet = false

    var body: some View {
        let usbPresent = midi.wiredDestinationCount > 0
        let btPresent = midi.bluetoothDestinationCount > 0
        HStack(spacing: 10) {
            Image(systemName: "cable.connector")
                .font(.padCaption)
                .foregroundColor(color(present: usbPresent))
            Button {
                showBluetoothSheet = true
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.padCaption)
                    .foregroundColor(color(present: btPresent))
            }
            Text(bearerLabel)
                .font(.padCaption2.weight(.bold))
                .foregroundColor(.orange)
                .fixedSize()
        }
        .sheet(isPresented: $showBluetoothSheet) {
            BluetoothMIDIPeripheralSheet()
        }
    }

    private var bearerLabel: String {
        switch midi.linkTransport {
        case .wired: return "USB · no link"
        case .bluetooth: return "BT · no link"
        case .virtualEndpoint, nil: return "no link"
        }
    }

    private func color(present: Bool) -> Color {
        present ? .white.opacity(0.7) : .gray.opacity(0.35)
    }
}

/// `CABTMIDILocalPeripheralViewController` wrapped for SwiftUI.
private struct BluetoothMIDIPeripheralSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CABTMIDILocalPeripheralViewController())
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

// MARK: - Scale-sync indicator

/// Visible until the current connection has received both scale and arrangement.
struct ScaleSyncIndicator: View {
    @ObservedObject var scaleSync: ScaleSyncReceiver

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
            Text("no sync")
                .font(.padSmall(9))
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Fret Pad (iPad)

/// The iPad Fret Pad — the counterpart of the Mac [Fret Pad](../../docs/fret-pad.md)
/// tab, perform-only; the `FretArrangement` arrives as a TLP event
/// (`ScaleSyncReceiver.fretArrangement`). Same field / onset snap / continuous
/// drag laws as the Mac, fully multitouch.
struct FretPadViewIOS: View {
    @ObservedObject var engine: PitchPadEngine
    @ObservedObject var scaleSync: ScaleSyncReceiver
    @ObservedObject var midi: MIDIEngine
    let recorder: FretGestureCapture
    let arrangement: FretArrangement
    /// The motion source supplies the strike envelope at onset.
    var motion: MotionManager? = nil


    var body: some View {
        ZStack(alignment: .top) {
            FretPadSurfaceIOS(engine: engine, arrangement: arrangement,
                              fieldWarp: scaleSync.joyConTilt.fieldWarp,
                              recorder: recorder,
                              motion: motion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PadToolbarIOS(scaleSync: scaleSync, midi: midi)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

/// The surface's layout — the scale degrees, the fret placements and the
/// chord-bar cells — recomputed only when the arrangement, the scale or the
/// surface size changes; a touch or a redraw tick reuses the last one. A
/// class so the surface's body can refresh it without a state write.
private final class FretLayoutMemo {
    typealias Layout = (degrees: [(ratio: Double, label: String)],
                        placements: [FretPlacement],
                        chordCells: [ChordBarCell])
    private var key: (arrangement: FretArrangement, scale: PitchScale,
                      size: CGSize)?
    private var layout: Layout = ([], [], [])

    func resolve(arrangement: FretArrangement, scale: PitchScale,
                 size: CGSize) -> Layout {
        if let key, key.arrangement == arrangement, key.scale == scale,
           key.size == size {
            return layout
        }
        let band = fretPadBandRect(in: size)
        let degrees = scaleDegrees(from: scale)
        layout = (degrees,
                  fretPlacements(arrangement: arrangement, degrees: degrees,
                                 size: band.size),
                  chordBarCells(arrangement: arrangement, degrees: degrees,
                                chords: scaleChords(degrees: degrees),
                                size: size))
        key = (arrangement, scale, size)
        return layout
    }
}

private struct FretPadSurfaceIOS: View {
    @ObservedObject var engine: PitchPadEngine
    let arrangement: FretArrangement
    /// The Mac's live `ctl_fret_warp` (JOYCON_STATE relay), including held
    /// fingers. 0 (linear) while the link is down.
    let fieldWarp: Double
    /// Stroke recorder for offline assist fitting (no-op unless armed).
    let recorder: FretGestureCapture
    /// Motion source for the strike envelope.
    let motion: MotionManager?
    /// The touch pipeline (onset, drag, settle tick, release).
    @State private var player = FretTouchPlayer()
    /// The fret and chord-bar layout, memoised on what changes it.
    @State private var layout = FretLayoutMemo()

    private let edgePad: CGFloat = 12
    /// Onset-snap half-width in px — the synced `marginPixels`. 0 = fretless.
    private var snapDistance: CGFloat { CGFloat(engine.marginPixels) }

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: max(1, geo.size.width - 2 * edgePad),
                              height: max(1, geo.size.height - 2 * edgePad))
            // The playable band — the frets' coordinate space.
            let band = fretPadBandRect(in: size)
            let (_, placements, chordCells) = layout.resolve(
                arrangement: arrangement, scale: engine.scale, size: size)

            ZStack(alignment: .topLeading) {
                Color.black

                // Always perform mode: colored frets on black, ghosts like base frets.
                Canvas { ctx, _ in
                    ctx.translateBy(x: edgePad, y: edgePad)
                    ctx.translateBy(x: band.minX, y: band.minY)
                    for p in placements {
                        let hue = pitchColor(forRatio: p.ratio, lightness: 0.82, chroma: 0.20)
                        ctx.stroke(p.linePath, with: .color(hue), lineWidth: 1.5)
                    }
                }

                // The chord bar (display only; taps hit-tested in `began`).
                ChordBarVisual(cells: chordCells,
                               active: engine.chordSelection,
                               edgePad: edgePad, cornerRadius: 6,
                               fontSize: 14)

                TouchOverlayView(
                    onTouchBegan: { ev in began(ev, placements: placements,
                                                size: size, band: band,
                                                chordCells: chordCells) },
                    onTouchMoved: { ev in moved(ev, placements: placements,
                                                size: size, band: band) },
                    onTouchEnded: { id in
                        let now = CACurrentMediaTime()
                        player.end(touchId: id, time: now)
                    }
                )
                .padding(edgePad)

            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onChange(of: fieldWarp) { _ in
                player.updateWarp(context: playContext(placements: placements, size: band.size),
                                  time: CACurrentMediaTime())
            }
        }
    }

    /// Onset: snap within the Snap distance of a fret inside its extent, else
    /// play the field pitch. Registers with the drag assist, starts its timer.
    private func began(_ ev: TouchEvent, placements: [FretPlacement],
                       size: CGSize, band: CGRect,
                       chordCells: [ChordBarCell]) {
        let spt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        // Chord bar: a tap toggles the strum chord (selection only, onsets).
        if let cell = chordCells.first(where: { $0.rect.contains(spt) }) {
            engine.toggleChordSelection(
                ChordSelection(degree: cell.degreeIndex,
                               octave: cell.octaveShift))
            return
        }
        // Notes live in the band only — the space above/below is dead.
        guard band.contains(spt) else { return }
        // Band-local coordinates from here on — the frets' space.
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        let now = CACurrentMediaTime()
        engine.setStrike(motion?.strikeLevel ?? 0)
        bindPlayer()
        player.begin(touchId: ev.touchId, at: pt,
                     context: playContext(placements: placements, size: band.size),
                     radiusPt: ev.radius, time: now)
    }

    private func bindPlayer() {
        player.engine = engine
        player.recorder = recorder
    }

    private func playContext(placements: [FretPlacement],
                             size: CGSize) -> FretTouchPlayer.Context {
        FretTouchPlayer.Context(placements: placements, size: size,
                                snapDistance: snapDistance,
                                ghostExtentOctaves: arrangement.ghostExtentOctaves,
                                warp: fieldWarp)
    }

    /// Drag: the player glides (field pitch + onset offset + the assist's
    /// slewed correction; never a re-snap mid-drag).
    private func moved(_ ev: TouchEvent, placements: [FretPlacement],
                       size: CGSize, band: CGRect) {
        let spt = CGPoint(x: ev.xFraction * size.width, y: ev.yFraction * size.height)
        let pt = CGPoint(x: spt.x - band.minX, y: spt.y - band.minY)
        player.move(touchId: ev.touchId, at: pt,
                    context: playContext(placements: placements, size: band.size),
                    radiusPt: ev.radius, time: CACurrentMediaTime())
    }
}
