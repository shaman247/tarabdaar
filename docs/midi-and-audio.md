# MIDI & Audio

The iPad↔Mac wire is **TLP** (the TarabLink Protocol). The iPad streams one compact binary **state frame** (all touches at full-resolution pitch + tilt + strike + drones + chord selection, atomic, latest-wins) plus a small set of reliable **events**; the Mac streams sync events and a display/control frame back. Both directions tunnel inside one SysEx envelope over the CoreMIDI transports — the USB session when wired, the BLE-MIDI session otherwise. Code: `Packages/TarabdaarCore/Sources/TarabdaarCore/Link/`.

**There is no MIDI note vocabulary.** No notes, bends, control changes, aftertouch or MPE exist anywhere in the app — not on the wire and not in-process. CoreMIDI is the tunnel's BEARER and nothing else: the only bytes either side sends or reads are SysEx-framed TLP frames. Pitch is an f32 fractional-MIDI number inside a state frame; expression, press, position, tilt and vibrato are 0…1 axes set directly on `BowControlMapper`; drone presses are `droneMask` bits. (MPE note+bend, tilt CC pairs, per-message SysEx blobs and the in-process note path are all gone — see docs/history/.)

## The SysEx envelope (`TLPPack.swift`)

```
F0 7D 10 <role> <7-in-8 packed frame> F7
```

| Part | Meaning |
|---|---|
| `7D` | MIDI non-commercial manufacturer ID; subtype `10` = the TLP tunnel — the ONLY SysEx either side sends |
| `<role>` | one septet, 0 = pad, 1 = host: the sender. Each side DROPS frames stamped with its own role, so traffic echoed through a MIDI loop (IAC bus, patchbay, USB+BLE double delivery) can neither mark the link up nor pollute sequence gating |
| 7-in-8 packing | each group of ≤ 7 payload bytes → 1 MSB septet (bit i = byte i's high bit) + the 7 bytes with bit 7 cleared; a final partial group of n bytes is 1 + n wire bytes. Overhead 8/7 vs base64's 4/3 |

Reassembly on both ends is **per source** (keyed by the CoreMIDI connection refCon); a shared buffer corrupts the moment two sources carry SysEx concurrently.

## Frames (`TLPFrame.swift`)

Little-endian, explicitly encoded byte tables, one frame per envelope. `TLP.versionMin/Max` are 19/19 (the scale and arrangement blobs carry no version of their own — this one is theirs); HELLO intersects version ranges, so a mismatched peer stays down cleanly instead of half-decoding (the symptom of a skipped iPad install is "drones and tilt work, touches are silent" — header-only frames decode while resized touch records don't; install both apps together).

| Type | Name | Class | Direction |
|---|---|---|---|
| `0x01` | HELLO | event | both — version handshake and sequence **epoch**: receiving one re-anchors all dedupe, so a restarted peer is never mistaken for stale traffic |
| `0x03` / `0x04` | PING / PONG | event | the Mac measures RTT + clock offset (`TarabLink:` lines in Console) |
| `0x08` | PANIC | event | both; routed through the surgical drop path below |
| `0x10` | SCALE_STATE | event | Mac → iPad, the scale blob (v4) |
| `0x11` | FRET_ARRANGEMENT | event | Mac → iPad, the arrangement blob (v6) |
| `0x12` | TARAF_BANK | event | Mac → iPad, running row identities and display pitches (v19) |
| `0x13` | TARAF_PLUCK | event | iPad → Mac, one discrete pluck in that bank (v19) |
| `0x1F` | RESYNC_REQUEST | event | iPad → Mac; the host replies with all sync payloads |
| `0x40` | PERF_STATE | state | iPad → Mac |
| `0x41` | JOYCON_STATE | state | Mac → iPad |

Events (`0x01–0x3F`) are `[type][eventSeq u16]` + payload, reliable, never dropped or reordered. State frames (`0x40–0x5F`) are latest-wins, coalescable per type; unknown state types are ignored. `0x42` is retired (not present — see docs/history/).

### `0x40 PERF_STATE` (iPad → Mac)

| Field | Type | Meaning |
|---|---|---|
| `type`, `flags` | u8, u8 | reserved (bit 0 was `backgrounded`; always 0) |
| `stateSeq` | u16 | wrap-aware sequence |
| `timestampUs` | u32 | sender monotonic µs (wraps ~71.6 min) |
| `tiltX/Y/Z` | s16 ×3 | the raw tilt report, ±32767 ↔ −1…+1 (~0.005° steps), atomic with pitch |
| `accelX/Y/Z` | s16 ×3 | raw `userAcceleration`, ±4 g full scale — display only (`LinkIngest.onAccel` → the Setup tab's received-acceleration view); no binding or physics reads them |
| `droneMask` | u8 | bits 0–2 = drone buttons held (held state; the Mac acts on edges) |
| `strike` | u8 | the accelerometer strike envelope, 0–255 ↔ 0…1 (`LinkIngest.onStrike` → the `.strike`/`.acceleration` pair — see [Sensors](sensors.md)); 0 from producers without an accelerometer |
| `chordDegree`, `chordOctave` | u8, i8 | the chord bar selection as held state: degree index (0xFF = none) + octave (always 0 on the wire — reserved, still decoded); the Mac acts on change edges (`LinkIngest.onChordSelect` → `AppController.strumChord`) — see [Fret Pad](fret-pad.md) |
| `touchCount` | u8 | then per touch: |
| `id` | u16 | namespaced wire id — one touch = one identity |
| `onsetSeq` | u8 | bumps on retrigger |
| `radius` | u8 | FINGERTIP SIZE — `UITouch.majorRadius` in points × 4 (quarter-point steps, clamped at 255 ≈ 63.75 pt); 0 = unknown (producers without a touchscreen). `LinkIngest.onTouchRadius` → `TouchSizeTracker` → the `.touchSize` control dimension — see [Sensors](sensors.md). Filled at onset and on every move. **v13** — it replaced the never-read `pressure` byte in place, so the record size is unchanged |
| `pitch` | f32 | fractional MIDI (~0.0008 ¢ steps) |
| `fretPosition` | u16 | position along the fret, 0…65535 ↔ 0…1: inner end 0, outer end 1; 0 for producers without fret geometry. Filled at onset and on movement, including changes with unchanged pitch. **v18** |

The touch record is 10 bytes. The `TLPTouch` STRUCT also carries `exprScale` and `glideExempt` — in-process-only fields alive on the Mac's `LocalLinkPump` lane (the strum chord's per-note expression, the glide-queue exemption); the encoder skips them and decoded wire frames read the defaults.

**Touch lifecycle lives IN the frame.** Each frame is the complete touch set: an id absent from the newer frame is a note-off, a new id is a note-on, a changed `onsetSeq` on a present id is a retrigger that survived coalescing. The newest frame is the truth, so a coalesced queue can never lose a release, and onset + pitch arrive atomically (the tanpura/sitar main-instrument pluck fires at the exact bent pitch on this path).

### `0x41 JOYCON_STATE` (Mac → iPad)

`[type][flags][stateSeq u16][timestampUs u32]` then the u8 fields below in this order.

| Field | Encoding | Acted on by the pad? |
|---|---|---|
| `stickX`, `stickY` | 0–255 ↔ −1…+1, centre 128 | display (`JoyConTiltPane`) |
| `wrist1–3` | same; the Joy-Con's fused/solved wrist attitude | display (`WristMotionPane`, the wrist tilt bars) |
| `arm1–3` | same; the Mac-evaluated ARM axes — the iPad tilts after the arm solve, round-tripped so the arm square shows what actually drives the bindings | display (`ArmTiltPane`; raw attitude when `armLive` is clear) |
| `strikeWin` | `ctl_strike_window` in 50 ms units (0 = unset → 2 s) | display: the strike scope's onset fade |
| `volVoice`, `volTaraf` | the volume readout, `TLPVolume` log scale (0 = at/below −60 dBFS, 1–255 span −60…0 dBFS) | display (`VolumeScopePane`) |
| `fieldWarp` | `ctl_fret_warp`, 0–255 ↔ 0…1 | **YES** — every touch onset/move resolves its pitch through the latest warp (`FretPadSurfaceIOS` via `scaleSync.joyConTilt.fieldWarp`; link-down fallback 0 = linear) |
| `octave` | i8 bit pattern, −3…+3 | **YES** — mirrored into `PitchPadEngine.octaveShift`, the ONE outbound-pitch point; ONSET-CAPTURED per touch (a sounding note keeps its birth octave through every glide); toolbar shows "Oct +1", dim at 0; fallback 0 |
| `wristRate1–3` | 0–255 ↔ −1…+1; d/dt of the displayed wrist tilt over `JoyConWristMotion.rateFullScale` (4 tilt full-scales/s, so ±1 = ±360°/s), one finite difference per IMU packet smoothed with a 50 ms one-pole; the raw yaw's ±180° wrap is unwrapped, and a calibration landing or lifting resets the tracker rather than reading as a flick | display (`WristMotionPane`, the d/dt bars) |
| `accel1–3` | same; the fusion's gravity-removed acceleration per body axis over `JoyConWristMotion.accelFullScaleG` (±1 g) | display (`WristMotionPane`, the accel bars) |
| `accelLevel` | 0–255 ↔ 0…1; the magnitude of `accel1–3` over the same 1 g full scale (deliberately NOT the Joy-Con Accel control axis: its `StrikeLaw` 0.01–0.5 g log scale reads 0.1 on rest noise and rails on a gentle move) | display (`WristMotionPane`, the combined accel bar) |

Flags: bit 0 stick live (while connected, including at centre), bit 1 wrist/body live, bit 2 **`connected`** (a Joy-Con is attached — the pad hides its drone buttons), bit 3 arm live (a calibration is driving). `connected`, `fieldWarp` and `octave` are the three fields the pad ACTS on; everything else is display. Nothing persists; a link drop or staleness resets the display to idle (`JoyConTiltDisplay.idle`), which also un-hides the drone buttons. Sent via `JoyConDisplayRelay` → `link.setJoyConState` on each change-gated stick/arm/wrist/volume update: axis motion is link-paced, an edge on an acted-on field goes out immediately (the relay compares against the last frame it sent), and a resync re-sends the frame outright.

**Volume readout sources**: the String kernel's split voice/jt buses (`BowEngine.setBusMeter` forces the `bow_poly_process3` split-bus render, **bit-exact** against the fused path — `BusMeterTests` — so the always-armed meter moves no parity bytes; taps sit POST the bus FX inserts and `bow_bal`), plus the tanpura/sitar node's `outputLevel` only while it IS the main instrument (the drone must not swamp the played voice's meter; the taraf side always meters the jt bus). Levels are **unsmoothed interval RMS** (integrate-and-dump), so decay rates on the scope are the buses' true rates. Relay: a 60 Hz `AppController` timer polls `AudioEngine.volumeLevels()` (the ONE poller — it owns the dump) → `TarabLink.setVolumeLevels`, change-gated on the encoded bytes at both ends. On the iPad the bytes land in `ScaleSyncReceiver.volumeHistory` (not the published tilt display), polled by the scope's `TimelineView` at UI rate.

The iPad's Expression / Pressure / Position readout receives four additional bytes after `accelLevel`: `noteActive` (0 or 1), then `expression`, `pressure`, and `position` (each 0–255 ↔ 0…1). These are display-only. The Mac polls the String voice mapper at 15 Hz using the volume relay's timer, selects the highest-pitched gated slot, and includes that slot's expression scale (strum and pitch accent). Selection follows glides and falls back when the top note releases. Released tails and plucked voices have no active bow-control readout. Changed bytes ride the paced `JOYCON_STATE`; unchanged values remain on its heartbeat. The iPad polls a separate locked snapshot at 15 Hz, showing dashes when inactive, disconnected, or stale; these updates do not publish the whole toolbar.

### Taraf strip events

`TARAF_BANK` carries `[type][eventSeq u16][revision u32][tonic f32][count u8]`,
then `count` records `[row u8][frequency f32][flags u8]`. Flags are bit 0 for
a two-direction raga row and bit 1 for the follower. The count is at most 128;
identities are unique and below 128, frequencies and tonic positive and finite.
It describes the **published engine**, not a pending tuning edit. The revision
is a new nonzero random token at publication. The Mac pushes it on publication
and ordinary resync; the iPad clears it when disconnected/stale, without
persisting it or treating it as an editable parameter.

`TARAF_PLUCK` carries `[type][eventSeq u16][revision u32][row u8]`.
It uses the event queue, so crossed strings are never latest-wins coalesced.
The existing event sequence gate rejects duplicates; main-thread routing then
checks bank revision and row membership before calling `BowEngine.pluckTaraf`.
A rebuild therefore cannot reinterpret a delayed gesture as another string.
Local Mac strip gestures use the same revision-checked entry point.

### Sync events

`SCALE_STATE` and `FRET_ARRANGEMENT` carry the binary blobs raw (`[len u16][blob]`): `PitchScaleSysEx.encodeBlob` (`[tonic][tonicCents14][margin][layout][count]`, then per point `num/den` 14-bit pairs, `y`, `enabled`, length-prefixed UTF-8 label) and `FretArrangementSysEx.encodeBlob`; neither carries a version byte — TLP's version is theirs. The synced state is a `SyncedScaleState` = scale + `tonicMidi` + `tonicCents` (±50 ¢ at 0.01 ¢ — the tonic is set in Hz on the Mac) + `marginPixels` + `layout` (`PadLayout`, always `.fretPad`; the enum keeps its other cases because the blob encodes the raw value). Older blob versions are rejected; both apps ship the format together. The fret pitch warp is deliberately NOT in the arrangement blob — it is a live param relayed via `fieldWarp`.

The iPad requests a fresh snapshot after every compatible host `HELLO`, including a host restart while the pad still considers the link up. This recovers an initial snapshot sent before the MIDI port was ready or before `HELLO` reset the receiver's event sequence epoch. Incompatible hosts do not trigger a sync request.

## Sender discipline (`LinkOutbox`, `TarabLink`)

| Rule | Value |
|---|---|
| Producers | O(1) locked writes into `OutboundPlayState` (main thread) |
| Pacing | a `DispatchSourceTimer` at 120 Hz on the link's own `userInteractive` serial queue — off main, so UI stalls cannot delay frames; ≤ 1 fresh state frame per tick (≤ 8.3 ms sampling age); events immediately |
| Coalescing | a state enqueue replaces any unsent frame of the same type; events never drop or reorder |
| Heartbeat | 250 ms when idle — a still iPad stays distinguishable from a dead one; held state (`droneMask`, chord selection, `connected`) re-delivers on it |
| Staleness | 1.5 s of silence → the link is stale → `LinkIngest.linkDidDrop` |
| Drop path | **surgical**: releases only the touches and drones the peer's OWN frames introduced, never the Mac's local-pad notes; a PANIC event routes through the same path — a wire event never has global blast radius |
| Dedupe | wrap-aware u16 sequence gating per class; HELLO re-anchors |
| Throttles | `kick()` (re-HELLO + resync on a CoreMIDI setup change) at most 1/s; hello replies 1/s; the Mac's state pushes coalesce to ≥ 300 ms apart |

`LinkIngest` first applies change-gated tilt/strike/accel, then diffs consecutive PERF_STATE frames — removals → onsets/retriggers → glides, drone-mask and chord edges — into `AudioEngine.touchOn/touchGlide/touchOff` and `setDronePressed`, all on the link queue. Each onset anchors and evaluates its Strike blend before mounting the string, so onset-captured parameters see the current frame. The Mac's `PitchPadEngine(audio:)` runs the same path in-process (`OutboundPlayState` → `LocalLinkPump` → `LinkIngest`).

**Lane selection** is `MIDIEngine`'s wired-first rule (below); the link has no lane state machine. The iPad sends via `sendSysExToLink` (real links only, never its own virtual loopback). The Mac sends via `sendSysExToLinkPeer`: to the **learned peer** — the destination on the same CoreMIDI entity as the source the pad's frames arrive on — so its replies ride whichever bearer the iPad chose; until the first pad frame (or after the peer's endpoint vanishes) the wired-first `sendSysEx(toDestinationsMatching: "iPad")` stands in, `fallbackToAll` for events only.

## Mac MIDI input (`MIDIInput.swift`)

`MIDIInput` opens a CoreMIDI input port, `MIDIPortConnectSource`s every visible source, and re-runs the connect pass on every setup-changed notification (plugging the iPad in mid-session brings it online). Inbound SysEx is reassembled per source (realtime bytes skipped); complete runs fire `onSysEx(bytes, source)` → `TarabLink.receivedSysEx`, and a pad-role `F0 7D 10` run also tells `MIDIEngine.noteLinkFrame(from:)` which source carries the link. Each source's TLP frame count and last-frame time (`sourceActivity()`) feed the Setup tab's source list, where the one-bearer rule can be read off the counters.

That is the whole class. Channel-voice bytes arriving on the port are stepped over at their message length so a following SysEx run is still found — nothing decodes them, and an external MIDI controller plays nothing. The Live tab's `performanceReadout()` reads the touch-keyed pitch (exact semitones).

## Joy-Con input (Mac, `TarabdaarMac/JoyConInput.swift`)

A left Nintendo Switch Joy-Con (classic or Joy-Con 2), a GameController-framework device, or a Switch-2 clone is the primary Mac-side motion input wired in `AppController.start()`. It feeds the same funnels the iPad stream feeds; no MIDI is involved. One controller attaches at a time (first to appear, fail-over on disconnect); `GCController.shouldMonitorBackgroundEvents` keeps it working while another app has focus. Handlers fire on the main queue.

### Controls

| Input | Action |
|---|---|
| Stick | drives independent **Stick Left / Right / Up / Down** dimensions through `ControlAxisEvaluator.applyStick`, each 0…1 from centre to edge. All four update together; diagonals activate two directions. The stick stays active across its full range, including centre, with no deadzone or deflection rescale. Sends are change-gated with ~9-bit quantization; display and wire values remain X/Y |
| dpad ← / → | step the playing-range **octave shift** ∓1 (clamped ±3, `AppController.shiftOctave` → `PitchPadEngine.octaveShift`, relayed as JOYCON_STATE `octave`) |
| dpad ↓ | toggle the continuous drone sequence (`DroneSequence` → `setDronePressed`) on/off, default slots 1 → 2 → 3 → 3 (Sa → Pa → high Sa → high Sa); switching on plays immediately and advances every 2 seconds after release. During a running calibration, step back one phase without toggling or advancing the sequence |
| GL (rear paddle, reported as Z (rear)) | shares the ↓ drone toggle: a fresh press starts or stops the continuous sequence; releases leave it running. Disconnecting stops the sequence |
| dpad ↑ | toggle the Tanpura drone register between one octave below the mapped pitch (launch default) and the original mapped octave; applies on the next pluck. During calibration, advance the capture instead |
| L | **strum**: the configured Strings-tab strum set (or the chord bar selection) as a HELD main-voice chord, released with the button (`AppController.strum(pressed:)`) |
| ZL | re-zero the arm AND wrist rest poses (`recenterBody`) |
| Minus | start a fresh performance pitch-profile seed, or finish the running seed |
| Capture | reset the performance pitch profile and its adaptive gain targets |
| SL, SR, stick click | unassigned; visible as panel chips |

Drones, the tarab and the strum do NOT follow the octave shift.

### Transports

| Path | What it provides |
|---|---|
| **GameController** (`attach`) | buttons and the stick as macOS presents them. A lone Joy-Con arrives SIDEWAYS: the stick is rotated back `(x, y) = (y_os, −x_os)` and A/B/X/Y map to ↓/←/→/↑; a paired L+R duo presents as a real gamepad and is not rotated. **Alias trap**: a `GCPhysicalInputProfile` names one element under several keys (the stick is BOTH `Left Thumbstick` and `Direction Pad`), so Direction Pad buttons bind only when `dpad !== stick` — otherwise stick deflection plucks drones |
| **IOHID full mode** (`startHID`, classic Joy-Con VID Nintendo, PIDs 0x2006/0x2007) | the GC profile omits L/ZL and delivers the stick as a digital 8-way hat. In simple mode 0x3F only the button bytes are real; `requestFullMode` sends subcommand `0x03 0x30` (retried until the first 0x30 report). Full mode (0x30, 60 Hz) carries the upright-frame button byte (arrows, SL/SR, L/ZL — four DISTINCT shoulder controls) and the 12-bit analog stick (bytes 6–8), which then drives the tilts; the GC hat AND the GC button bindings stand down entirely (clones alias GC face buttons unpredictably). IMU: subcommand `0x40 0x01` enables three 5 ms-spaced frames at byte 12 (accel 4096 LSB/g, gyro 16.4 LSB/°/s) |
| **Joy-Con 2 over BLE** (`JoyCon2BLE`) | BLE-only vendor GATT — macOS cannot pair them and neither GC nor IOHID sees them, so Tarabdaar's own CoreBluetooth client scans broadly, filters on manufacturer company ID **`0x0553`** (NOT the 0x057E USB VID, which appears later in the payload with the PID; the advertisement has an EMPTY name), connects and subscribes to `AB7DE9BE-…7FD2` on service `…7FD0`. Report 0x05: buttons as a u32 LE at bytes 4–7 (left: dpad Down/Up/Right/Left bits 16–19, SR 20, SL 21, L 22, ZL 23), the 12-bit packed stick at bytes 10–12, accel i16 ×3 at 0x30, gyro at 0x36 (classic scales), magnetometer at 0x19. Commands use `0x91` framing on `649D4AC9-…` (acks on `C765A961-…`, subscribed first): console-style init (command-response subscribe → controller-info read → LED → vibration preset → feature enable → input subscribe LAST), player-1 LED `09 91 01 07 00 04 00 00 01 00 00 00`, IMU + magnetometer feature enables (flags `0x03 | 0x04 | 0x80`) spaced 150 ms apart (back-to-back, the ack returns zeros and motion stays off). First connect: hold the sync button while the panel reads "scanning"; reconnects rescan. Needs `NSBluetoothAlwaysUsageDescription` |
| **Clone fallback** (`altFallbackDelay` 2 s) | third-party Switch-2 controllers impersonate a Joy-Con 2 at the link layer but ignore `0x91` commands, stream nothing on `…7FD2`, and disconnect after 60 s idle; their input streams continuously on `CC1BBBB5-…` (63-byte report: counter at byte 0, buttons at bytes 2–3 — byte 2: Down 0x01, Right 0x02, Left 0x04, Up 0x08, L 0x10, ZL 0x20, Minus 0x40, stick click 0x80; byte 3: Capture 0x01, SR 0x40, SL 0x80 — stick 12-bit packed at bytes 5–7, IMU zeros). That characteristic is ALSO the real Joy-Con 2 (L)'s report 0x07 (motion as a length byte at 0x0E + a packed blob at 0x0F in an undocumented encoding), and a real unit switches to 0x07 the moment it is subscribed — so `JoyCon2BLE` subscribes ONLY `…7FD2` at init, enables the rest after 2 s of silence, forwards them only while `…7FD2` stays silent, and the alternate parser reads no IMU |

**Recalibrate the stick after switching controllers** — one stored calibration, different electrical ranges.

### Stick calibration (`StickCal`, `tarabdaar.joyconStickCal.v2`)

The in-hand neutral is off-centre and the gate is roughly a circle, so per-axis min/max can never send a diagonal to (±1, ±1). The rim is calibrated as a radius per angle bin (16 bins) and mapped circle → square at runtime: radius normalized by the interpolated rim radius at that angle, direction scaled so the larger component reaches 1. "Recalibrate stick" runs two phases: ~½ s at rest in the playing grip, then a full circle along the rim, then Done (an unswept segment or radius < 150 raw units discards; the panel counts segments live). The stick does not drive the tilts during a capture. Uncalibrated fallback: rest from the first 24 samples after attach + a fixed 1400-unit span.

### IMU, fusion and the wrist

While a controller streams motion, a complementary filter propagates body-frame gravity `gHat` (ġ = g × ω with a slow accel pull) and, with a magnetometer (Joy-Con 2 only), pins yaw to a body-frame north `nHat` — hard-iron offset learned as the running min/max midpoint, trusted once the seen extremes span most of the field sphere (figure-eight the controller; until then yaw is gyro-integrated). The fused attitude feeds the iPad's wrist bars (`onWristAttitude` → JOYCON_STATE at ~30 Hz, as a `JoyConWristMotion`: the displayed tilt, its rate, the linear acceleration and its magnitude), the **wrist calibration** (control axes 8–10) and, gravity-removed through `StrikeLaw`, the **Joy-Con Accel** axis — see [Sensors](sensors.md). `jcIMUActive`/`jcMagActive`/`jcFusedActive` flip on the first sample to gate the panels.

### Setup tab panel (`JoyConStatusView`, ⌘7)

Connection status, the profile's element inventory with aliases grouped on one line, the raw stick X/Y values, the `Control` chips lighting while held, the last raw element event as the OS names it, the "Raw HID" report hex, and the IMU line (~10 Hz). Below it: **Received motion (3D)** and **Received acceleration (3D)** (the iPad-overlay twins, 60 Hz `TimelineView` off the live trails `liveTrace`/`liveAccelTrace`), the Joy-Con's own gyroscope (±360 °/s) and accelerometer (raw, includes gravity, ±2 g) trails, a magnetometer panel that appears only with non-zero data, and the fused **Joy-Con motion (3D)** / **Joy-Con acceleration (3D)** views (yaw as the continuous integrator, so the trail never jumps at ±180°; acceleration = `accel − gHat`, ±0.5 g). Publishes throttle to ~15 Hz; the trails are unpublished buffers read at 60 Hz.

## Audio graph (Mac, `AudioEngine.swift`)

```
touch ► StringVoiceSource         ─┐
               TanpuraVoiceSource ─┼► symGain ► mainMixerNode ► output
               (sitar) TanpuraVoiceSource ─┘
```

- Three `AVAudioSourceNode`s connect DIRECTLY to `symGain` (`outputVolume` 1), which feeds the main mixer: the String voice (`SarangiKit.BowEngine` + the C kernel — the complete instrument: played strings + modal-jawari taraf + body + radiation + room + the FX rack), the tanpura node (default drone voice / optional main instrument) and the sitar node (main instrument; its output charges the String kernel's inject ring, `st_taraf`). The tanpura's output also feeds the inject ring (`tp_taraf`). No hosted AU, no master filter/reverb bus.
- The String kernel runs 96 kHz internally and half-band-decimates to 48 kHz; the tanpura nodes run at their artifact's 48 kHz; the mixer input converts to the engine rate, `Config.sampleRate` (44 100).
- The String node's async jawari worker pool renders one block late so the callback never waits. The audio thread never does link or state logic.

### Output device

| Setting | Rule |
|---|---|
| IO buffer | requested at engine start and on `setOutputDevice` via `preferredBufferFrames(for:)` → `setOutputBufferFrames` (the device's CoreAudio HAL buffer, clamped to its range; `outputBufferFrames` reads it back, `logAudioLatencyReport` is a diagnostic). `Config.preferredOutputBufferFrames` 128 (≈ 2.7 ms) for direct transports |
| Jitter-prone transports | DisplayPort/HDMI monitor audio, Bluetooth, AirPlay (by `kAudioDevicePropertyTransportType`) cannot hold the ~3 ms cadence and crackle on EVERY voice; they get `Config.jitterProneOutputBufferFrames` 512 (≈ 11.6 ms). Check `system_profiler SPAudioDataType` before suspecting DSP |
| Sample rate | `matchOutputDeviceToEngineRate` sets the device to 48 kHz when supported (no output resampler — the whole graph runs at the artifacts' native 48 kHz) and `restoreOutputDeviceRate` restores it on quit (`willTerminate` + `deinit`); a device without 48 kHz keeps AVAudioEngine's converter |

See [Sound Design](sound-design.md) for the voice DSP.


## Parameter update cadence

`AppController`'s `@Published` setters push to `AudioEngine` via `didSet` — slider drags fire immediately, no timer. The String voice routes through `StringParamStore` / `SarangiStore`: live keys and composite members push instantly (chunk-rate smoothed in `BowEngine`); a structural edit (tarab tuning, a `bow_*` build scalar) schedules a debounced off-thread `BowEngine` rebuild, swapped in lock-free, so rapid drags coalesce into one rebuild. See [Parameters](parameters.md).

## MIDIEngine (the tunnel's byte pump)

`MIDIEngine` owns the CoreMIDI client, the output port, destination classification and the wired-first rule, and has two send paths:

- **`sendSysExToLink`** — the TLP tunnel: real links only (wired first, BLE otherwise), never virtual endpoints (the device's own "Tarabdaar Scale" receiver would loop it back).
- **`sendSysExToLinkPeer`** — the Mac's side of the same tunnel: the learned peer alone, else the name-filtered wired-first `sendSysEx` (events fall back to every destination, state frames drop).
- **`sendSysEx`** — the general send with an optional destination-name filter; the stand-in above.

There are no other senders: SysEx is the only thing that leaves the port. Setup is deferred to `onAppear` (the iOS MIDI server may not be ready at launch; 3 retries). Playing emits nothing on CoreMIDI beyond the tunnel: `PitchPadEngine` writes touches into `OutboundPlayState`, `NoteManager`'s 60 Hz tick writes tilt/accel/strike into the same snapshot, and `TarabLink` paces it onto the wire.

Every outbound envelope has an explicit CoreMIDI host-clock timestamp, at least 2 ms after the preceding envelope. A send lock keeps timestamp reservation and submission in the same order. This preserves the scale / fret arrangement / taraf-bank burst on USB/IDAM, which drops messages when several SysEx sends use timestamp 0. CoreMIDI schedules the brief burst spacing; the link queue never sleeps, and ordinary 120 Hz performance frames send immediately once the burst has cleared. `MIDISysExScheduleTests` guards ordering and the return to immediate delivery.

## Connecting

### USB

1. Connect the iPad by cable.
2. Mac: **Audio MIDI Setup → Window → Show MIDI Studio**, double-click the iPad icon, enable it.
3. Launch both apps. The Mac's top-bar pill turns green with the cable icon and `USB 1.2 ms` (the bearer and the round trip); the iPad's toolbar reads `USB` beside a green cable icon. The first touch plays.

No Bonjour, no IP addresses. Each side keeps its own settings.

### Bluetooth (BLE-MIDI)

The same tunnel runs over a standard BLE-MIDI session — an ordinary CoreMIDI endpoint pair that `MIDIInput` picks up on the next setup-change notification. BLE-MIDI is the bearer DELIBERATELY: Apple grants its own MIDI service a privileged ~11.25 ms connection interval, while a custom GATT link floors at 15 ms — replacing the session would regress wireless latency. The tunnel's coalescing removes BLE-MIDI's real weakness, per-message queue buildup.

1. iPad: tap the **antenna button** at the right of the pad toolbar and enable **Advertise** (`CABTMIDILocalPeripheralViewController`; `NSBluetoothAlwaysUsageDescription` required).
2. Mac: **Audio MIDI Setup → MIDI Studio → Bluetooth**, find the iPad, **Connect**.
3. The pill turns green with the antenna icon and `Bluetooth N ms`; the iPad's toolbar reads `BT`. The session is per-run — after relaunching either side, re-advertise and reconnect.

Expect ~10–20 ms added over USB's ~1–3 ms on the transport hop; the Console `TarabLink:` RTT lines measure a given room. At most one fresh state frame is in flight, so latency cannot creep.

### Wired-first, automatic

`MIDIEngine` classifies destinations by `kMIDIPropertyDriverOwner` (endpoint/entity/device level):

| Class | Rule |
|---|---|
| Bluetooth | the Apple Bluetooth MIDI driver; used only when no wired destination exists |
| wired | any other driver (USB/IDAM bridge, IAC, network); carries traffic whenever present |
| virtual | no driver owner (app-published endpoints, including the iPad's own "Tarabdaar Scale" receiver); always targeted, counts as neither link |

The switch rides the CoreMIDI setup-change notification (`refreshEndpointCounts` re-partitions a cached snapshot; the send path never re-queries endpoint properties). `sendSysEx` applies the name filter across ALL destinations first and wired-first within the matches. **No name crosses a BLE-MIDI link** (the Mac sees `iOS Bluetooth`), so Bluetooth destinations bypass the name filter — a BLE-MIDI session in this rig is only ever the iPad.

**One bearer at a time, decided by the iPad.** The iPad's wired-first rule picks the bearer for its own frames; the Mac learns its peer from the source those frames arrive on (`noteLinkFrame(from:)` → the destination on that source's entity — the USB device or the BLE-MIDI session) and replies there alone. So with the cable in, both directions ride USB even while a Bluetooth session is connected, and nothing depends on the iPad's endpoint name; pulling the cable drops the peer on the next setup change and the pad's first Bluetooth frame re-learns it. On the development Mac the USB endpoint is `iPad` (owner `com.apple.AppleMIDIUSBDriver`) and an `IAC Driver Bus` counts as wired too — which is why the Mac's UI reads the bearer from the learned peer, never from `wiredDestinationCount`.

**Reading it.** `MIDITransport` (`.wired` = USB, `.bluetooth`, `.virtualEndpoint`) is the public classification, with a label and an SF Symbol. The iPad toolbar's USB icon (`cable.connector`) and antenna show the state from `wiredDestinationCount` / `bluetoothDestinationCount`: **green** = carrying the link, **white** = connected but idle, **dim** = absent; exactly one is green whenever any destination exists, and the bearer is named beside them (`USB` / `BT` / `no link`, from `linkTransport`). On the Mac, `LinkReadout` (`ConnectionStatusView.swift`) turns `linkPeerTransport` / `linkPeerName` and `TarabLink.Status` into one reading shared by the top-bar pill, the Live tab and the Setup tab: `USB 1.2 ms` / `Bluetooth 14 ms` green, `USB · stale` orange, `No iPad` yellow, `Link off` red, `USB · version mismatch` red.

## Scale sync (Mac → iPad)

The Mac is the scale editor, the iPad the performer. Scale and fret arrangement are pushed as the `SCALE_STATE` / `FRET_ARRANGEMENT` events above — the tuning state beside the JOYCON_STATE acted-on fields and the read-only taraf-bank snapshot.

- **Mac send** (`AppController` + `TarabLink`): Combine subscriptions push on every `pitchPad.scale` / `tonic` / `margin` / `layout` edit (debounced ~300 ms) and whenever a destination appears; the iPad also asks via `RESYNC_REQUEST` on link-up.
- **iPad receive** (`ScaleSyncReceiver` + `TarabLink`): the receiver keeps its CoreMIDI plumbing (input port on all sources + the "Tarabdaar Scale" virtual destination) as the tunnel's reassembler; decoded events call the appliers, which publish and persist (`SyncedScaleStore` / `FretArrangementSyncStore`, UserDefaults blobs). `PitchPadEngine.applySyncedState` panics on a scale/layout change (no note stranded on a vanishing cell) and swaps scale/tonic/margin/layout.

One-way; the iPad has no scale editor and its tonic is read-only. It persists the last synced state and opens on it after an offline relaunch. See [Fret Pad](fret-pad.md).

## External MIDI hosts

Neither side speaks MIDI to anything else: the iPad does not drive third-party DAWs, and the Mac plays nothing from an external MIDI controller. The instrument is played from the iPad's Fret Pad, the Mac's own pads and the Joy-Con.
