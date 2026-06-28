import Foundation
import StarpadCore

/// One parametric peak band of the body/post-reverb formant stages (the
/// `AVAudioUnitEQ`s on the hosted-AU path / master chain). `widthOct` is the
/// bandwidth in octaves — AVAudioUnitEQ's native unit.
struct ViolaBodyBand: Equatable {
    var freq: Double
    var gainDB: Double
    var widthOct: Double
}

/// Mac-only sound preset. The sarangi voice is the ported `SarangiKit` model
/// (owned by `SarangiStore`, edited in the Sarangi tab) — NOT configured here.
/// This preset bundles only the **hosted-AU** setup (SWAM Violin, run DRY, which
/// the model requires as its input) and the shared master-FX (reverb/filter +
/// the body/post-reverb EQs that shape the tanpura/sitar tail). The enum stays so
/// other hosted-AU instruments can be added later without re-plumbing.
enum SoundPreset: String, CaseIterable, Equatable {
    case swamViola

    var label: String {
        switch self {
        // Hosts SWAM **Violin** as the sarangi base — the violin's bright,
        // edgy bowed timbre is what the model transforms into the sarangi. The
        // enum case keeps its `swamViola` rawValue for persistence compatibility.
        case .swamViola: return "SWAM Violin (sarangi)"
        }
    }

    /// Bundle of the Mac-controlled FX + hosted-AU values a preset sets.
    /// `AppController.applyPreset` copies these into its `@Published` state and
    /// pushes the relevant slices into `AudioEngine`.
    struct State {
        // Shared body formants (an `AVAudioUnitEQ`; now on the muted dry SWAM
        // sub-bus, so effectively inert — the model owns its own body. Kept for
        // when a hosted instrument is mixed in dry again).
        var violaBodyEnabled: Bool = false
        var violaBody: [ViolaBodyBand] = [
            ViolaBodyBand(freq: 300, gainDB: 4.0, widthOct: 0.6),
            ViolaBodyBand(freq: 650, gainDB: -3.5, widthOct: 0.8),
            ViolaBodyBand(freq: 1050, gainDB: 5.0, widthOct: 0.5),
            ViolaBodyBand(freq: 3200, gainDB: 3.5, widthOct: 0.7),
        ]

        // Post-reverb spectral shaper (after the master reverb — shapes the
        // tanpura/sitar tail).
        var postReverbEnabled: Bool = false
        var postReverb: [ViolaBodyBand] = [
            ViolaBodyBand(freq: 350, gainDB: 0, widthOct: 1.0),
            ViolaBodyBand(freq: 2500, gainDB: 0, widthOct: 1.0),
            ViolaBodyBand(freq: 7000, gainDB: 0, widthOct: 1.2),
        ]

        // Master FX bus (AVAudioUnitReverb + AVAudioUnitEQ) — tanpura/sitar only.
        var reverbMix: Double = 25
        var filterCutoff: Double = 18000
        var filterResonance: Double = 0

        // Hosted-AU descriptor; SWAM Violin in the shipping preset.
        var hostedAudioUnit: AudioEngine.HostedAUDescriptor? = nil

        // Hosted-AU (SWAM) parameter defaults, by identifier → value, applied to
        // each instance on load (see AudioEngine.setHostedAUParameterDefaults).
        // Drives the violin's OWN timbre (near-bridge bowing + firm pressure) and
        // runs SWAM DRY — the model expects a dry violin input.
        var hostedAUParams: [String: Float] = [:]

        // Hosted-AU full document state (serialized binary plist), restored to
        // every SWAM slot on load (see AudioEngine.setHostedAUFullState). Carries
        // SWAM's opaque encoded state — notably the per-control MIDI CC
        // assignments, which are NOT AU parameters. nil = restore nothing.
        var hostedAUState: Data? = nil
    }

    func state() -> State {
        switch self {
        case .swamViola:
            var s = State()
            // SWAM Violin 3 (Svl3) — the sarangi base. SWAM Solo Strings share
            // the AU parameter layout, so the bow-timbre `hostedAUParams`
            // identifiers below apply unchanged.
            s.hostedAudioUnit = AudioEngine.HostedAUDescriptor(
                type: "aumu", subType: "Svl3", manufacturer: "AuMo")
            s.filterCutoff = 18000; s.filterResonance = 0.0
            s.reverbMix = 30.7427
            // SWAM Violin's own timbre: near-bridge bowing + firm pressure for a
            // bright/edgy bowed tone, auto-vibrato / expressive modes OFF for a
            // steady tone, and — critically — SWAM run DRY (its internal
            // room/reverb/ambience/body all OFF), since the ported model takes a
            // dry violin as input (its `input1.wav` reference was SWAM with all
            // body/reverb off). String Resonance stays ON (the violin's own
            // periodic sympathetic ringing).
            s.hostedAUParams = [
                "1013107514": 0.27419,   // Bow/Pizz Position (toward bridge)
                "1484578252": 0.701393,  // Bow Pressure (firm)
                "574719741":  0.513613,  // Bow Noise
                "1044572362": 0.0,       // Vibrato Depth off
                "796119545":  0.0,       // Vibrato Rate
                "2008574934": 0.0,       // Play Mode (least expressive)
                "1884889441": 0.0,       // Gesture Mode off
                "143125754":  0.0,       // Keep Bow Direction off
                "277296446":  0.0,       // Manual Bowing off
                // --- DRY: kill SWAM's internal room/reverb/ambience/body ---
                "1099171302": 0.0,       // Ambiente Room Simulator OFF
                "389880618":  0.0,       // Reverb Mix → dry
                "1349089215": 0.0,       // Reverb Time → min
                "1088641165": 0.0,       // Early Reflection Gain → off
                "345785969":  0.0,       // Ambience Amount → off
                "1068695671": 0.0,       // Room Sizes → min
                "58272484":   0.0,       // Instrument Body off
                "1958189775": 0.401507,  // String Resonance ON (periodic)
                // Strings Model → 1 (Virtual Adaptive Resizing (Mono)).
                "960866759":  1.0,
            ]
            // SWAM's per-control MIDI CC assignments live in this opaque blob,
            // not in `hostedAUParams`. Captured from a hand-configured SWAM.
            s.hostedAUState = SwamDefaultState.violin
            return s
        }
    }
}
