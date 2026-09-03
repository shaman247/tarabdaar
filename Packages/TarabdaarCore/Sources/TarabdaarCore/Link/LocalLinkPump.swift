import Foundation

/// The Mac's in-process lane: OutboundPlayState → LinkIngest with no wire,
/// no pacing, no queue — every mutation pumps a frame synchronously on the
/// caller's thread, exactly as the old `MIDIEngine(publishToCoreMIDI:
/// false)` → `onLocalEvent` path delivered bytes. This makes the Mac
/// preview pads (and the computer keyboard driving them) a permanent live
/// test rig for the ingest path the iPad wire uses.
public final class LocalLinkPump {
    private let state: OutboundPlayState
    /// Exposed so the Mac can hang its control-layer taps (the
    /// `.fingerAccel` dimension's onTouchGate/onTouchPitch) on the local
    /// pads' frame diffs the same way it does on the wire ingest.
    public let ingest: LinkIngest

    public init(state: OutboundPlayState, ingest: LinkIngest) {
        self.state = state
        self.ingest = ingest
        state.onDirty = { [weak self] in self?.pump() }
    }

    private func pump() {
        if let frame = state.snapshotFrame(timestampUs: LinkClock.nowUs()) {
            ingest.apply(frame)
        }
    }
}
