import AppKit
import TarabdaarCore

/// Lets the computer keyboard play notes in TarabdaarMac. Letter keys map
/// to ascending degrees of the active Pitch Pad scale (any size, any JI
/// tuning) and play through the shared `pitchPad` engine — the same
/// touch path the on-screen pad uses, so keyboard notes sound identical
/// to clicked ones and share the scale, tonic, and velocity.
///
/// App-wide while `enabled`: one local `NSEvent` monitor catches key
/// down/up on any tab. It steps aside automatically while a text field is
/// being edited, and ignores any key pressed with ⌘/⌃/⌥ held (so the
/// ⌘1–9 tab shortcuts and menu commands still work).
///
/// The key→degree map is by **physical key code** (not character), so a
/// row of keys keeps its shape regardless of the host keyboard layout.
/// Three letter rows form one ascending ribbon low→high; `[` / `]` shift
/// the whole ribbon down / up an octave.
final class KeyboardNotePlayer: ObservableObject {
    /// Master on/off. Persisted. Installs/removes the event monitor.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled {
                installMonitor()
            } else {
                removeMonitor()
                releaseAll()
            }
        }
    }

    /// Whole-keyboard octave shift, applied on top of the ribbon (`[`/`]`
    /// nudge it). Clamped to a sane range; changing it releases any held
    /// notes so nothing sticks at the old pitch.
    @Published var octaveOffset: Int = 0 {
        didSet {
            octaveOffset = min(3, max(-3, octaveOffset))
            if octaveOffset != oldValue { releaseAll() }
        }
    }

    private static let enabledKey = "tarabdaar.keyboardPlay.enabled"

    /// The engine we play through (the Pitch Pad engine). It owns the
    /// scale, tonic, and velocity the keyboard inherits.
    private let engine: PitchPadEngine
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// keyCode → active touchId, for keys currently held down.
    private var activeKeys: [UInt16: Int] = [:]
    /// Distinct touchId namespace, far from the pad's mouse counter, so a
    /// keyboard note and a clicked note never collide on the same engine.
    private static let touchBase = 1_000_000

    init(engine: PitchPadEngine) {
        self.engine = engine
        self.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if enabled { installMonitor() }
        // Release held notes when the app loses focus: a key held while
        // ⌘-tabbing away never delivers its keyUp, which would otherwise
        // strand the note.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.releaseAll() }
    }

    deinit {
        removeMonitor()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Event monitor

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            guard let self else { return event }
            // Returning nil consumes the event (a note/octave key we own),
            // which also suppresses AppKit's unhandled-key "funk" beep.
            return self.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    /// Process a key event. Returns true if it was consumed (a note or
    /// octave-shift key this player owns).
    private func handle(_ event: NSEvent) -> Bool {
        guard enabled else { return false }
        let code = event.keyCode

        // Always release a key we're holding, even if focus or modifiers
        // changed mid-hold, so a note can never get stuck.
        if event.type == .keyUp {
            guard let touch = activeKeys.removeValue(forKey: code) else { return false }
            engine.noteOff(touchId: touch)
            return true
        }

        // keyDown — only act when not typing in a field and no ⌘/⌃/⌥ combo
        // (those belong to text editing, tab shortcuts, and menu items).
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return false
        }

        if code == Self.leftBracket  { octaveOffset -= 1; return true }
        if code == Self.rightBracket { octaveOffset += 1; return true }

        guard let index = Self.ribbon.firstIndex(of: code) else { return false }
        // Swallow auto-repeat and a second keyDown without an intervening
        // keyUp (e.g. focus glitches) so the note doesn't retrigger.
        if event.isARepeat || activeKeys[code] != nil { return true }
        guard let ratio = ratio(forRibbonIndex: index) else { return true }
        let touch = Self.touchBase + index
        activeKeys[code] = touch
        engine.noteOn(touchId: touch, ratio: ratio)
        return true
    }

    /// Stop every held keyboard note (on disable, octave shift, focus loss).
    private func releaseAll() {
        for touch in activeKeys.values { engine.noteOff(touchId: touch) }
        activeKeys.removeAll()
    }

    // MARK: - Mapping

    /// Ratio for ribbon position `index`: the `(index mod N)`-th scale
    /// degree raised by `floor(index / N)` octaves plus the global
    /// `octaveOffset`. `nil` if the scale has no enabled degrees.
    private func ratio(forRibbonIndex index: Int) -> Double? {
        let degrees = scaleDegrees(from: engine.scale)
        guard !degrees.isEmpty else { return nil }
        let n = degrees.count
        let octave = index / n + octaveOffset
        return degrees[index % n].ratio * pow(2.0, Double(octave))
    }

    // MARK: - Key codes (ANSI virtual key codes, layout-independent)

    /// Low→high ribbon: bottom letter row, then home row, then top row.
    /// Each entry is a physical key position (`kVK_ANSI_*`).
    private static let ribbon: [UInt16] = [
        // z x c v b n m , . /
        6, 7, 8, 9, 11, 45, 46, 43, 47, 44,
        // a s d f g h j k l ;
        0, 1, 2, 3, 5, 4, 38, 40, 37, 41,
        // q w e r t y u i o p
        12, 13, 14, 15, 17, 16, 32, 34, 31, 35,
    ]
    private static let leftBracket: UInt16 = 33   // [
    private static let rightBracket: UInt16 = 30  // ]
}
