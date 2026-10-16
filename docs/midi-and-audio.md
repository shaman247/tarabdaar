# MIDI & Audio

The iPad↔Mac wire is **TLP** (the TarabLink Protocol). The iPad streams one compact binary **state frame** (all touches at full-resolution pitch + tilt + strike + drones + chord selection, atomic, latest-wins) plus a small set of ordered **events**; the Mac streams sync events and a display/control frame back. Both directions tunnel inside one SysEx envelope over the CoreMIDI transports — the USB session when wired, the BLE-MIDI session otherwise. Code: `Packages/TarabdaarCore/Sources/TarabdaarCore/Link/`.

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

Little-endian, explicitly encoded byte tables, one frame per envelope. `TLP.versionMin/Max` are 30/30 (the scale and arrangement blobs carry no version of their own — this one is theirs); HELLO intersects version ranges. Until a compatible HELLO arrives, only HELLO is sent and all other inbound frames are ignored. A version mismatch on an established link releases that link’s touches and drones. Install both apps together; version 30 carries fifteen-row arrangements and recording geometry.

| Type | Name | Class | Direction |
|---|---|---|---|
| `0x01` | HELLO | event | both — version handshake and sequence **epoch**: receiving one re-anchors all dedupe, so a restarted peer is never mistaken for stale traffic |
| `0x03` / `0x04` | PING / PONG | event | the Mac measures RTT + clock offset (`TarabLink:` lines in Console) |
| `0x08` | PANIC | event | both; routed through the surgical drop path below |
| `0x10` | SCALE_STATE | event | Mac → iPad, the scale blob (v4) |
| `0x11` | FRET_ARRANGEMENT | event | Mac → iPad, fifteen-row pitch masks with fine octave span (v30) |
| `0x12` | TARAF_BANK | event | Mac → iPad, running row identities and display pitches (v19) |
| `0x13` | TARAF_PLUCK | event | iPad → Mac, one discrete pluck in that bank (v19) |
| `0x14` | FRET_RECORDING | event | Mac → iPad session command; iPad → Mac completion fence (v29) |
| `0x15` | FRET_RECORDING_CHUNK | event | iPad → Mac, completed fitting records (v29) |
| `0x1F` | RESYNC_REQUEST | event | iPad → Mac; the host replies with all sync payloads |
| `0x40` | PERF_STATE | state | iPad → Mac |
| `0x41` | JOYCON_STATE | state | Mac → iPad |

Events (`0x01–0x3F`) are `[type][eventSeq u16]` + payload. After a compatible HELLO establishes the session, the sender queues events in order without state coalescing; this is not an acknowledgement/retransmission guarantee. Pre-handshake sync events are discarded and recovered by resync. State frames (`0x40–0x5F`) are latest-wins, coalescable per type; unknown state types are ignored. `0x42` is retired (not present — see docs/history/).

### `0x40 PERF_STATE` (iPad → Mac)

| Field | Type | Meaning |
|---|---|---|
| `type`, `flags` | u8, u8 | reserved (bit 0 was `backgrounded`; always 0) |
| `stateSeq` | u16 | wrap-aware sequence |
| `timestampUs` | u32 | sender monotonic µs (wraps ~71.6 min) |
| `tiltX/Y/Z` | s16 ×3 | the raw tilt report, ±32767 ↔ −1…+1 (~0.005° steps), atomic with pitch |
| `accelX/Y/Z` | s16 ×3 | raw `userAcceleration`, ±4 g full scale — display only (`LinkIngest.onAccel` → the Setup tab's received-acceleration view); no binding or physics reads them |
| `droneMask` | u8 | legacy bits 0–2 = drones held; retained for compatibility, 0 from the current pad UI |
| `strike` | u8 | the accelerometer strike envelope, 0–255 ↔ 0…1 (`LinkIngest.onStrike` → the `.strike`/`.acceleration` pair — see [Sensors](sensors.md)); 0 from producers without an accelerometer |
| `chordDegree`, `chordOctave` | u8, i8 | the chord bar selection as held state: degree index (0xFF = none) + octave (always 0 on the wire — reserved, still decoded); the Mac acts on change edges (`LinkIngest.onChordSelect` → `AppController.strumChord`) — see [Fret Pad](fret-pad.md) |
| `touchCount` | u8 | then per touch: |
| `id` | u16 | source-local wire id — one touch = one identity; the host remaps input lanes before voice routing |
| `onsetSeq` | u8 | bumps on retrigger |
| `radius` | u8 | FINGERTIP SIZE — `UITouch.majorRadius` in points × 2 (half-point steps, up to 127.5 pt); 0 = unknown (producers without a touchscreen). `LinkIngest.onTouchRadius` → `TouchSizeTracker` → the `.touchSize` control dimension — see [Sensors](sensors.md). Filled at onset and on every move. **v26** — positive finite values use bytes 1–255; zero, negative or nonfinite input is unknown. The touch record remains ten bytes |
| `pitch` | f32 | fractional MIDI (~0.0008 ¢ steps) |
| `fretPosition` | u16 | position along the fret, 0…65535 ↔ 0…1: inner end 0, outer end 1; 0 for producers without fret geometry. Filled at onset and on movement, including changes with unchanged pitch. **v18** |

The touch record is 10 bytes. The `TLPTouch` STRUCT also carries `exprScale` and `glideExempt` — in-process-only fields alive on the Mac's `LocalLinkPump` lane (the strum chord's per-note expression, the glide-queue exemption); the encoder skips them and decoded wire frames read the defaults.

**Touch lifecycle lives IN the frame.** Each frame is the complete touch set: an id absent from the newer frame is a note-off, a new id is a note-on, a changed `onsetSeq` on a present id is a retrigger that survived coalescing. The newest frame is the truth, so a coalesced queue can never lose a release, and onset + pitch arrive atomically (the tanpura/sitar main-instrument pluck fires at the exact bent pitch on this path).

### `0x41 JOYCON_STATE` (Mac → iPad)

`[type][flags][stateSeq u16][timestampUs u32]` then the u8 fields below in this order, followed by note-control bytes and ten fret-assist f32 values.

| Field | Encoding | Acted on by the pad? |
|---|---|---|
| `stickX`, `stickY` | 0–255 ↔ −1…+1, centre 128 | retained telemetry; no iPad UI |
| `wrist1–3` | same; the Joy-Con's fused/solved wrist attitude | retained telemetry; no iPad UI |
| `arm1–3` | same; the Mac-evaluated ARM axes — the iPad tilts after the arm solve, retained for compatibility | retained telemetry; no iPad UI |
| `strikeWin` | `ctl_strike_window` in 50 ms units (0 = unset → 2 s) | retained telemetry; no iPad UI |
| `volVoice`, `volChromatic`, `volRaga` | main voice, chromatic taraf and raga taraf readouts, `TLPVolume` log scale (0 = at/below −60 dBFS, 1–255 span −60…0 dBFS) | retained telemetry; no iPad UI |
| `fieldWarp` | `ctl_fret_warp`, 0–255 ↔ 0…1 | **YES** — every touch onset/move resolves its pitch through the latest warp (`FretPadSurfaceIOS` via `scaleSync.joyConTilt.fieldWarp`; link-down fallback 0 = linear) |
| `octave` | i8 bit pattern, −3…+3 | **YES** — mirrored into `PitchPadEngine.octaveShift`, the ONE outbound-pitch point; ONSET-CAPTURED per touch (a sounding note keeps its birth octave through every glide); fallback 0 |
| `wristRate1–3` | 0–255 ↔ −1…+1; d/dt of the displayed wrist tilt over `JoyConWristMotion.rateFullScale` (4 tilt full-scales/s, so ±1 = ±360°/s), one finite difference per IMU packet smoothed with a 50 ms one-pole; the raw yaw's ±180° wrap is unwrapped, and a calibration landing or lifting resets the tracker rather than reading as a flick | retained telemetry; no iPad UI |
| `accel1–3` | same; the fusion's gravity-removed acceleration per body axis over `JoyConWristMotion.accelFullScaleG` (±1 g) | retained telemetry; no iPad UI |
| `accelLevel` | 0–255 ↔ 0…1; the magnitude of `accel1–3` over the same 1 g full scale (deliberately NOT the Joy-Con Accel control axis: its `StrikeLaw` 0.01–0.5 g log scale reads 0.1 on rest noise and rails on a gentle move) | retained telemetry; no iPad UI |

Flags: bit 0 stick live (while connected, including at centre), bit 1 wrist/body live, bit 2 **`connected`** (a Joy-Con is attached), bit 3 arm live (a calibration is driving). `fieldWarp`, `octave` and the resolved fret-assist controls act on the pad; the other telemetry fields remain encoded for compatibility, without an iPad display. Nothing persists; a link drop or staleness resets the display to idle (`JoyConTiltDisplay.idle`). Sent via `JoyConDisplayRelay` → `link.setJoyConState` on each change-gated stick/arm/wrist/volume update: axis motion is link-paced, an edge on connected/strike-window/warp/octave goes out immediately (the relay compares against the last frame it sent), and a resync re-sends the frame outright.

**Volume readout sources**: three independent readings for **Main** (orange), **Chromatic** (cyan) and **Raga** (purple). The main reading combines the String voice bus with the tanpura/sitar node's `outputLevel` only while that node is the main instrument; the drone is excluded. The two taraf readings sum row radiation by the table's chromatic flag, after row gains, caps, the common body/tone filters and gain. A shadow linear filter separates chromatic from the summed signal without changing the audio arithmetic; raga is the remaining contribution. Their samples follow the same async FIFO, fade and underrun hold as the audible web. Both include `bow_bal` and the String engine’s trim/`bow_gain` (not the final `output_gain_db`), but tap before the shared taraf FX insert, whose nonlinear output cannot be uniquely assigned to either bank. The main tap remains after its voice FX and balance; the combined taraf meter remains available internally after its FX. These are bus levels, before the final room/global FX. Metering preserves rendered bytes (`ByteNullContractTests`, `DualTarafTests.testBankMeterIsolation`).

The Mac’s persistent **Output** strip separately measures L/R sample peaks at the main mixer after `output_gain_db` and the linked stereo limiter, including the complete three-voice mix. The final stage adds the selected 1–20 ms lookahead (default 5 ms) and reports gain reduction in the **LIMIT** readout. Its tap retains peak maxima and a full-scale clipping latch until reset; it does not consume the bus-meter intervals or add fields to TLP. The tap also supplies optional diagnostic recordings. Device volume follows this measurement.

Levels are **unsmoothed interval RMS** (integrate-and-dump), so decay rates on the scope follow the buses. A 60 Hz `VolumeMeterRelay` polls `AudioEngine.volumeLevels()` (the ONE poller — it owns the dump) → `TarabLink.setVolumeLevels`, change-gated on all three encoded bytes. TLP v20 carries the three adjacent bytes after `strikeWin`; both apps must use the same version. The Mac Live tab and persistent output strip read all three cached levels through `AudioEngine.performanceReadout()`, without consuming meter intervals. The same cache retains independent interval-RMS maxima at every 60 Hz poll, so a bloom between UI frames is not missed. The output strip shows these current values and maxima before final output gain; **Reset meters** clears the RMS maxima together with the final output peak history while leaving current RMS and TLP sampling intact. Each source has its own colored trace and dB reading; readings at or below the display floor show ≤ −60 dBFS. The iPad does not accumulate or display the returned volume telemetry.

Four note-control bytes remain after `accelLevel`: `noteActive` (0 or 1), then `expression`, `pressure`, and `position` (each 0–255 ↔ 0…1). The Mac samples the highest-pitched gated bowed slot at 15 Hz, including its expression scaling. Changed bytes ride the paced `JOYCON_STATE`; the iPad has no Expression / Pressure / Position readout. These telemetry fields retain their encoding for protocol compatibility.

**Fret assist (v23).** After `noteControls.position`, ten little-endian f32
values carry the Mac-resolved assist settings in this fixed order: amount,
capture radius (× Snap), pause radius (px), pause delay (ms), pause ramp
(ms), settle time (ms), slew limit (¢/s), turn pull, turn decay (ms), and
release distance (px). Non-finite or out-of-range values reject the frame.
These continuous controls use the paced, latest-wins state lane and resend
on resync; they do not send reliable events for each mapping update.
The iPad applies them to `PitchPadEngine.fretAssistSettings` on main, and
`FretTouchPlayer` reads them at onset, movement and every settle tick.
Disconnect/staleness restores registry defaults. The Mac alone persists
rests and evaluates mappings. Both apps must use the same TLP version.

### Taraf strip events

The taraf strip is Mac-only. These events remain in the wire contract; the
iPad retains the bank snapshot but has no control that emits `TARAF_PLUCK`.

`TARAF_BANK` carries `[type][eventSeq u16][revision u32][tonic f32][count u8]`,
then `count` records `[row u8][frequency f32][flags u8]`. Flags use bit 0 for
a two-direction raga row; all other bits are zero. The count is at most 128;
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

### Fret recording events

`FRET_RECORDING` is `[type][eventSeq u16][session u32][recording u8]`.
A nonzero Mac token with recording=1 arms iPad capture; recording=0 stops that
session, and token zero clears any prior session. Repeated active tokens are idempotent.
The Mac repeats the command every 500 ms while recording or finishing and
includes it in resync. On stop, the iPad discards still-held partial strokes,
drains already-completed records, then echoes that token with recording=0 as a completion
fence. Repeated stop commands recover a lost fence. The Mac keeps its file open
in **Saving** until that fence or a link drop; recording remains available across
Mac tab changes. The iPad never writes a recording file.

`FRET_RECORDING_CHUNK` is `[type][eventSeq u16][session u32][record u32]`
`[index u16][count u16][length u16][bytes]`. Session and record identities are
nonzero; indices are zero-based, lengths 1–256 bytes, and every non-final chunk
has 256 bytes. One assembled record is `[uncompressedLength u32][LZFSE data]`,
containing exactly one v7 JSON fitting record with the iPad's original geometry
and timestamps. Decompression is bounded to 1 MiB; the sender queues at most
4 MiB and logs rejected oversized records. Chunks use the event sequence gate,
and transfer sends at most one chunk per four 120 Hz link ticks, after normal
performance traffic. Missing/out-of-order chunks discard that partial record;
old sessions and repeated completed records are ignored. Files receive only
complete decoded records. This is diagnostic transfer, with no chunk retransmission.
A disconnect cancels pending iPad transfer and clears receiver partial state.

### Sync events

`SCALE_STATE` and `FRET_ARRANGEMENT` carry the binary blobs raw (`[len u16][blob]`): `PitchScaleSysEx.encodeBlob` (`[tonic][tonicCents14][margin][layout][count]`, then per point `num/den` 14-bit pairs, `y`, `enabled`, length-prefixed UTF-8 label) and `FretArrangementSysEx.encodeBlob`; neither carries a version byte — TLP's version is theirs. The synced state is a `SyncedScaleState` = scale + `tonicMidi` + `tonicCents` (±50 ¢ at 0.01 ¢ — the tonic is set in Hz on the Mac) + `marginPixels` + `layout` (`PadLayout`, always `.fretPad`; the enum keeps its other cases because the blob encodes the raw value). Peers with incompatible TLP versions are rejected; both apps ship the format together. Cached arrangement formats decode as described below. Arrangement flags bit 6 selects fifteen-row pitch masks: `[degreeIndex][rowMask u16 LE]`. Mask bits 0–14 select rows 1–15; bit 15 must be zero. Each pitch appears once, so even all 127 scale pitches assigned to all 15 rows fit within one event.
The blob starts with `[ghostTwentiethOctaves][flags=80][columnCount]`. Flag bit 4
selects 0.05-octave flank units, preserving the slider's 0.1-octave total-span
steps. Cached blobs without bit 4 retain their quarter-octave flank units.
Only pitches with assigned frets are sent. The receiver derives frequency-aligned x coordinates
and equal heights with no overlaps. Cached nine-row blobs (bit 5) retain rows 1–9
and leave rows 10–15 empty. Cached five-row blobs (bit 3) map to 1/3/5/7/9
and three-row blobs (bit 2) map to 1/5/9; their adjacent-row unions populate
rows 2/4/6/8 once. Old raga membership masks (bit 0) are consumed and ignored. Older
coordinate blobs migrate through their nearest old row and omit disabled frets. The fret pitch warp is deliberately NOT in the arrangement blob — it is a live param relayed via `fieldWarp`.

The iPad requests a fresh snapshot after recovery from a stale link and after every compatible host `HELLO`, including a host restart while the pad still considers the link up. This recovers an initial snapshot sent before the MIDI port was ready or before `HELLO` reset the receiver's event sequence epoch. Incompatible hosts do not trigger a sync request.

## Sender discipline (`LinkOutbox`, `TarabLink`)

| Rule | Value |
|---|---|
| Producers | O(1) locked writes into `OutboundPlayState` (main thread) |
| Pacing | a `DispatchSourceTimer` at 120 Hz on the link's own `userInteractive` serial queue — off main, so UI stalls cannot delay frames; ≤ 1 fresh state frame per tick (≤ 8.3 ms sampling age); events immediately |
| Coalescing | a state enqueue replaces any unsent frame of the same type; events on an established link stay ordered in the sender queue without coalescing |
| Heartbeat | 250 ms when idle — a still iPad stays distinguishable from a dead one; held state (`droneMask`, chord selection, `connected`) re-delivers on it |
| Staleness | 1.5 s of silence → the link is stale → `LinkIngest.linkDidDrop` |
| Drop path | **surgical**: releases only the touches and drones the peer's OWN frames introduced, never the Mac's local-pad notes; a PANIC event routes through the same path — a wire event never has global blast radius |
| Dedupe | wrap-aware u16 sequence gating per class; HELLO re-anchors |
| Throttles | `kick()` (re-HELLO + resync on a CoreMIDI setup change) at most 1/s; hello replies 1/s; the Mac's state pushes coalesce to ≥ 300 ms apart |

While the link is down, HELLO retries use the existing one-second throttle. Performance state stays pending until a compatible handshake. Pre-handshake sync events are discarded; the pad requests a fresh snapshot after HELLO, and the host marks its display frame dirty.

`LinkIngest` first applies change-gated tilt/strike/accel, then diffs consecutive PERF_STATE frames — removals → onsets/retriggers → glides, drone-mask and chord edges — into `AudioEngine.touchOn/touchGlide/touchOff` and `setDronePressed`, all on the link queue. Each onset anchors and evaluates its Strike blend before mounting the string, so onset-captured parameters see the current frame. The Mac's `PitchPadEngine(audio:)` runs the same path in-process (`OutboundPlayState` → `LocalLinkPump` → `LinkIngest`). Every production ingest (the wire and both Mac pad engines) shares one host `TouchIdentityAllocator`: equal source ids become distinct host ids before audio routing and all touch callbacks. Releases and link drops return only that ingest's mappings. `OutboundPlayState` uses the full u16 range and skips its own held ids, without a process-local namespace. The host also skips held ids, glide-chain identities (including a lifted chain origin and release grace), and identities with downstream callbacks still in flight. Both cursors advance monotonically across wrap, so a released id is not immediately reused. The encoded u16 field and TLP format are unchanged.

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
| SL, SR, stick click, Minus, Capture | unassigned; visible as panel chips |

Drones, the tarab and the strum do NOT follow the octave shift.

### Transports

| Path | What it provides |
|---|---|
| **GameController** (`attach`) | buttons and the stick as macOS presents them. A lone Joy-Con arrives SIDEWAYS: the stick is rotated back `(x, y) = (y_os, −x_os)` and A/B/X/Y map to ↓/←/→/↑; a paired L+R duo presents as a real gamepad and is not rotated. **Alias trap**: a `GCPhysicalInputProfile` names one element under several keys (the stick is BOTH `Left Thumbstick` and `Direction Pad`), so Direction Pad buttons bind only when `dpad !== stick` — otherwise stick deflection plucks drones |
| **IOHID full mode** (`startHID`, classic Joy-Con VID Nintendo, PIDs 0x2006/0x2007) | the GC profile omits L/ZL and delivers the stick as a digital 8-way hat. In simple mode 0x3F only the button bytes are real; `requestFullMode` sends subcommand `0x03 0x30` (retried until the first 0x30 report). Full mode (0x30, 60 Hz) carries the upright-frame button byte (arrows, SL/SR, L/ZL — four DISTINCT shoulder controls) and the 12-bit analog stick (bytes 6–8), which then drives the four directional stick dimensions; the GC hat AND the GC button bindings stand down entirely (clones alias GC face buttons unpredictably). IMU: subcommand `0x40 0x01` enables three 5 ms-spaced frames at byte 12 (accel 4096 LSB/g, gyro 16.4 LSB/°/s) |
| **Joy-Con 2 over BLE** (`JoyCon2BLE`) | BLE-only vendor GATT — macOS cannot pair them and neither GC nor IOHID sees them, so Tarabdaar's own CoreBluetooth client scans broadly, filters on manufacturer company ID **`0x0553`** (NOT the 0x057E USB VID, which appears later in the payload with the PID; the advertisement has an EMPTY name), connects and subscribes to `AB7DE9BE-…7FD2` on service `…7FD0`. Report 0x05: buttons as a u32 LE at bytes 4–7 (left: dpad Down/Up/Right/Left bits 16–19, SR 20, SL 21, L 22, ZL 23), the 12-bit packed stick at bytes 10–12, accel i16 ×3 at 0x30, gyro at 0x36 (classic scales), magnetometer at 0x19. Commands use `0x91` framing on `649D4AC9-…` (acks on `C765A961-…`, subscribed first): console-style init (command-response subscribe → controller-info read → LED → vibration preset → feature enable → input subscribe LAST), player-1 LED `09 91 01 07 00 04 00 00 01 00 00 00`, IMU + magnetometer feature enables (flags `0x03 | 0x04 | 0x80`) spaced 150 ms apart (back-to-back, the ack returns zeros and motion stays off). First connect: hold the sync button while the panel reads "scanning"; reconnects rescan. Needs `NSBluetoothAlwaysUsageDescription` |
| **Clone fallback** (`altFallbackDelay` 2 s) | third-party Switch-2 controllers impersonate a Joy-Con 2 at the link layer but ignore `0x91` commands, stream nothing on `…7FD2`, and disconnect after 60 s idle; their input streams continuously on `CC1BBBB5-…` (63-byte report: counter at byte 0, buttons at bytes 2–3 — byte 2: Down 0x01, Right 0x02, Left 0x04, Up 0x08, L 0x10, ZL 0x20, Minus 0x40, stick click 0x80; byte 3: Capture 0x01, SR 0x40, SL 0x80 — stick 12-bit packed at bytes 5–7, IMU zeros). That characteristic is ALSO the real Joy-Con 2 (L)'s report 0x07 (motion as a length byte at 0x0E + a packed blob at 0x0F in an undocumented encoding), and a real unit switches to 0x07 the moment it is subscribed — so `JoyCon2BLE` subscribes ONLY `…7FD2` at init, enables the rest after 2 s of silence, forwards them only while `…7FD2` stays silent, and the alternate parser reads no IMU |

BLE connection attempts have an **8-second link deadline**, followed by an independent **8-second setup/first-input deadline**. Standard input, clone alternate input, or recognized NYXI command-channel input completes setup; command acknowledgements alone do not. The connected state is published on the first input report. On either timeout, the client cancels the pending connection, discards that CoreBluetooth manager and its peripheral state, and starts a fresh scan. Recovery does not depend on receiving a cancellation callback. Bluetooth power loss/reset also clears the session. Every deferred init, feature-enable and clone-probe action carries an attempt generation, so work from an earlier connection cannot write into a later one. Console lines prefixed `Tarabdaar ble` record Bluetooth state, scans, attempt number and elapsed time, link readiness, service/characteristic discovery, initialization, first input, failures and the timed-out stage.

**Recalibrate the stick after switching controllers** — one stored calibration, different electrical ranges.

### Stick calibration (`StickCal`, `tarabdaar.joyconStickCal.v2`)

The in-hand neutral is off-centre and the gate is roughly a circle, so per-axis min/max can never send a diagonal to (±1, ±1). The rim is calibrated as a radius per angle bin (16 bins) and mapped circle → square at runtime: radius normalized by the interpolated rim radius at that angle, direction scaled so the larger component reaches 1. "Recalibrate stick" runs two phases: ~½ s at rest in the playing grip, then a full circle along the rim, then Done (an unswept segment or radius < 150 raw units discards; the panel counts segments live). Stick bindings remain neutral during a capture. Uncalibrated fallback: rest from the first 24 samples after attach + a fixed 1400-unit span.

### IMU, fusion and the wrist

While a controller streams motion, a complementary filter propagates body-frame gravity `gHat` (ġ = g × ω with a slow accel pull) and, with a magnetometer (Joy-Con 2 only), pins yaw to a body-frame north `nHat` — hard-iron offset learned as the running min/max midpoint, trusted once the seen extremes span most of the field sphere (figure-eight the controller; until then yaw is gyro-integrated). The fused attitude feeds the iPad's wrist bars (`onWristAttitude` → JOYCON_STATE at ~30 Hz, as a `JoyConWristMotion`: the displayed tilt, its rate, the linear acceleration and its magnitude), the **wrist calibration** (the shared tilt axes 0–2 while the controller is connected) and, gravity-removed through `StrikeLaw`, the **Joy-Con Accel** axis — see [Sensors](sensors.md). `jcIMUActive`/`jcMagActive`/`jcFusedActive` flip on the first sample to gate the panels.

### Setup tab panel (`JoyConStatusView`, ⌘7)

Connection status, the profile's element inventory with aliases grouped on one line, the raw stick X/Y values, the `Control` chips lighting while held, the last raw element event as the OS names it, the "Raw HID" report hex, and the IMU line (~10 Hz). Below it: **Received motion (3D)** and **Received acceleration (3D)** (60 Hz `TimelineView` off the live trails `liveTrace`/`liveAccelTrace`), the Joy-Con's own gyroscope (±360 °/s) and accelerometer (raw, includes gravity, ±2 g) trails, a magnetometer panel that appears only with non-zero data, and the fused **Joy-Con motion (3D)** / **Joy-Con acceleration (3D)** views (yaw as the continuous integrator, so the trail never jumps at ±180°; acceleration = `accel − gHat`, ±0.5 g). Publishes throttle to ~15 Hz; the trails are unpublished buffers read at 60 Hz.

## Audio graph (Mac, `AudioEngine.swift`)

```
touch ► StringVoiceSource         ─┐
               TanpuraVoiceSource ─┼► symGain ► final gain/limiter ► mainMixerNode ► output
               (sitar) TanpuraVoiceSource ─┘
```

- Three `AVAudioSourceNode`s connect DIRECTLY to `symGain` (`outputVolume` 1), which feeds the final gain/limiter and then the main mixer: the String voice (`SarangiKit.BowEngine` + the C kernel — the complete instrument: played strings + modal-jawari taraf + body + radiation + room + the FX rack), the tanpura node (default drone voice / optional main instrument) and the sitar node (main instrument; its output charges the String kernel's inject ring, `st_taraf`). The tanpura's output also feeds the inject ring (`tp_taraf`). No hosted AU, no master filter/reverb bus.
- The String kernel runs 96 kHz internally and half-band-decimates to 48 kHz. The String and plucked source nodes and mixer all use `Config.sampleRate` (48 kHz); the output device is matched to that rate when supported.
- The main mixer connects explicitly to the output node at 48 kHz **before** its fixed-rate meter/capture tap is installed. The tap must not change the mixer's reported rate while leaving the output connection at its implicit 44.1 kHz rate. `FinalOutputTests` pins agreement between the mixer output and device input before startup. The latency report includes both rates as well as the hardware rate; an offline recording alone cannot verify playback speed.
- The String node's async jawari worker pool renders one block late so the callback never waits. The audio thread never does link or state logic.

### Output device

| Setting | Rule |
|---|---|
| IO buffer | requested at engine start and on `setOutputDevice` via `preferredBufferFrames(for:)` → `setOutputBufferFrames` (the device's CoreAudio HAL buffer, clamped to its range; `outputBufferFrames` reads it back, `logAudioLatencyReport` is a diagnostic). `Config.preferredOutputBufferFrames` 128 (≈ 2.7 ms) for direct transports |
| Jitter-prone transports | DisplayPort/HDMI monitor audio, Bluetooth, AirPlay (by `kAudioDevicePropertyTransportType`) cannot hold the ~3 ms cadence and crackle on EVERY voice; they get `Config.jitterProneOutputBufferFrames` 512 (≈ 10.7 ms at 48 kHz). Check `system_profiler SPAudioDataType` before suspecting DSP |
| Sample rate | `matchOutputDeviceToEngineRate` sets the device to 48 kHz when supported (no output resampler — the whole graph runs at the artifacts' native 48 kHz) and `restoreOutputDeviceRate` restores it on quit (`willTerminate` + `deinit`); a device without 48 kHz keeps AVAudioEngine's converter |

`AudioOutputRecovery` owns output selection and recovery on the main queue. It
observes engine configuration changes, CoreAudio device/default-output changes,
and workspace sleep/wake. A one-second health check catches missed notifications.
Graph mutations share a control-thread lock; render callbacks do not acquire it.
Sleep stops output and cancels pending recovery. Wake retries after the device
settles. Repeated failures back off to five-second retries; a new target or
explicit selection cancels stale retries. Voices and held-note state remain
mounted throughout recovery.

**System Default** follows future default-device changes. An explicit selection
is remembered by device UID: disappearance temporarily uses the system default,
and reappearance restores the selected device even if its numeric ID changes.
No available output leaves the engine stopped with an accurate status. Device
switch calls check CoreAudio errors and read back the selected device; a failed
switch restores the previous selection and attempts to resume its output.
The Setup picker updates on device changes and reports failed selections.
Original device rates are also saved by UID, so restoration cannot accidentally
change a different device that reuses an old numeric ID. A later external rate
change supersedes the app's temporary 48 kHz request and is left in effect.

Every recovery stops the engine, removes the meter tap, reconnects the output,
and reinstalls the tap. Validation checks active source rates, the stereo 48 kHz
sum/final-stage/mixer/device-input formats, and agreement between the hardware
format and its current nominal rate, before and after starting. External rate
changes on the same device retain that device rate and use the output converter;
recovery does not repeatedly force another application's rate back to 48 kHz.
The latency report records the negotiated rates after each successful recovery.

`AudioOutputRecoveryTests` covers route intent, rollback, disappearance and return,
sleep cancellation, format failure, notification coalescing and retry backoff.
The opt-in `AudioOutputRecoveryLiveTests` uses BlackHole plus a disposable
aggregate device to exercise actual HAL changes and measure hardware-loopback
pitch, including a held String voice after recovery:

```bash
TARABDAAR_RECOVERY_CAPTURE_DIR="$PWD/output/output-recovery" \
  swift test --package-path Packages/TarabdaarCore --filter AudioOutputRecoveryLiveTests/testLiveRecoveryAndPitch
```

That probe temporarily changes the system output and virtual-device rates, then
restores them and destroys its aggregate. Physical unplug/replug and real sleep
use the separate operator-assisted test, enabled with
`TARABDAAR_RECOVERY_PHYSICAL_DIR`; its `phase.txt` requests each action. It compares
source sample cadence against wall time and an independent HAL hardware clock.
`TARABDAAR_RECOVERY_PHYSICAL_MODE=unplug` omits the real sleep cycle. These physical
clock checks do not record the analog headphone signal. Workspace notification
tests are explicitly distinct from an actual machine sleep.

See [Sound Design](sound-design.md) for the voice DSP.

### Pluck capture diagnostic

`TARABDAAR_PLUCK_CAPTURE_DIR` opts into one local recording per app launch.
The first accepted taraf-strip pluck or fret onset starts a twenty-second, unnormalized
Float32 stereo capture at the main mixer's output. Twenty-two seconds after the
gesture, a background writer saves `pluck-<timestamp>-<pid>.wav` and a JSON
report in that directory. The report includes the actual reference displacement
submitted to each dual-row strip pluck, row identities, live controls, FX,
structural overrides, held inputs, output-device settings, and worker/render
counters before and after. During the phrase, quarter-second snapshots record
live controls, bow pressure/expression/position, gated pitches, held inputs and
worker counters. Strip plucks and direct fret on/off events have command timestamps.
The tap copies into preallocated memory; file writing
runs off the audio thread. Without the environment variable, the shared output-meter tap remains active but does not record.

The shared Mac Xcode Run scheme leaves this diagnostic disabled. Set the
environment variable in a local Run configuration to enable it, using a path
under the ignored `output/` directory. This captures the app mix before the output device; it cannot
capture distortion introduced downstream by device conversion or playback hardware.
Tap timestamps locate the buffered audio; gesture uptime is a command timestamp,
not an assertion of sample-exact onset alignment. `frames` versus `capacityFrames`
and `formatErrors` indicate whether the recording completed correctly. The tap
also reports buffer sample timestamps, discontinuities, and missing/repeated
frame counts; concatenated WAV data alone does not establish an uninterrupted
device timeline. The render maximum is shared with the existing UI poller;
cumulative overrun and worker-drop
deltas are the reliable interval counters.

## Parameter update cadence

`AppController`'s `@Published` setters push to `AudioEngine` via `didSet` — slider drags fire immediately, no timer. The String voice routes through `StringParamStore` / `SarangiStore`: live keys and composite members push instantly (chunk-rate smoothed in `BowEngine`); a structural edit (tarab tuning, a `bow_*` build scalar) schedules a debounced off-thread `BowEngine` rebuild, published under a brief lock for crossfading, so rapid drags coalesce into one rebuild. See [Parameters](parameters.md).

## MIDIEngine (the tunnel's byte pump)

`MIDIEngine` owns the CoreMIDI client, the output port, destination classification and the wired-first rule, and has two send paths:

- **`sendSysExToLink`** — the TLP tunnel: real links only (wired first, BLE otherwise), never virtual endpoints (the device's own "Tarabdaar Scale" receiver would loop it back).
- **`sendSysExToLinkPeer`** — the Mac's side of the same tunnel: the learned peer alone, else the name-filtered wired-first `sendSysEx` (events fall back to every destination, state frames drop).
- **`sendSysEx`** — the general send with an optional destination-name filter; the stand-in above.

There are no other senders: SysEx is the only thing that leaves the port. Setup is deferred to `onAppear` (the iOS MIDI server may not be ready at launch; 3 retries). Playing emits nothing on CoreMIDI beyond the tunnel: `PitchPadEngine` writes touches into `OutboundPlayState`, `NoteManager`'s 60 Hz tick writes tilt/accel/strike into the same snapshot, and `TarabLink` paces it onto the wire.

Every outbound envelope has an explicit CoreMIDI host-clock timestamp, at least 2 ms after the preceding envelope. A send lock keeps timestamp reservation and submission in the same order. This preserves the scale / fret arrangement / taraf-bank burst on USB/IDAM, which drops messages when several SysEx sends use timestamp 0. CoreMIDI schedules the brief burst spacing; the link queue never sleeps, and ordinary 120 Hz performance frames send immediately once the burst has cleared. `MIDISysExScheduleTests` guards ordering and the return to immediate delivery. Packet-list construction checks CoreMIDI’s documented null result before sending; an envelope that does not fit is dropped without submitting an incomplete list.

## Connecting

### USB

1. Connect the iPad by cable.
2. Mac: **Audio MIDI Setup → Window → Show MIDI Studio**, double-click the iPad icon, enable it.
3. Launch both apps. The Mac's top-bar pill turns green with the cable icon and `USB 1.2 ms` (the bearer and the round trip); the iPad's status overlay disappears once scale and arrangement are synced. The first touch plays.

No Bonjour, no IP addresses. Each side keeps its own settings.

### Bluetooth (BLE-MIDI)

The same tunnel runs over a standard BLE-MIDI session — an ordinary CoreMIDI endpoint pair that `MIDIInput` picks up on the next setup-change notification. BLE-MIDI is the bearer DELIBERATELY: Apple grants its own MIDI service a privileged ~11.25 ms connection interval, while a custom GATT link floors at 15 ms — replacing the session would regress wireless latency. The tunnel's coalescing removes BLE-MIDI's real weakness, per-message queue buildup.

1. iPad: tap the **antenna button** at the top right while disconnected and enable **Advertise** (`CABTMIDILocalPeripheralViewController`; `NSBluetoothAlwaysUsageDescription` required).
2. Mac: **Audio MIDI Setup → MIDI Studio → Bluetooth**, find the iPad, **Connect**.
3. The pill turns green with the antenna icon and `Bluetooth N ms`; the iPad hides its status overlay once synced. The session is per-run — after relaunching either side, re-advertise and reconnect.

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

**Reading it.** `MIDITransport` (`.wired` = USB, `.bluetooth`, `.virtualEndpoint`) is the public classification, with a label and an SF Symbol. The iPad's USB icon and antenna are visible only when the TLP handshake is unavailable or stale: white means the transport exists, dim means absent, and the label names an available bearer followed by “no link”. Connected transport icons are hidden. A separate “no sync” warning remains until both scale and fret arrangement arrive on the current connection; cached data does not hide it. On the Mac, `LinkReadout` (`ConnectionStatusView.swift`) turns `linkPeerTransport` / `linkPeerName` and `TarabLink.Status` into one reading shared by the top-bar pill, the Live tab and the Setup tab: `USB 1.2 ms` / `Bluetooth 14 ms` green, `USB · stale` orange, `No iPad` yellow, `Link off` red, `USB · version mismatch` red.

## Scale sync (Mac → iPad)

The Mac is the scale editor, the iPad the performer. Scale and fret arrangement are pushed as the `SCALE_STATE` / `FRET_ARRANGEMENT` events above — the tuning state beside the JOYCON_STATE acted-on fields and the read-only taraf-bank snapshot.

- **Mac send** (`AppController` + `TarabLink`): Combine subscriptions push on every `pitchPad.scale` / `tonic` / `margin` / `layout` edit (debounced ~300 ms) and whenever a destination appears; the iPad also asks via `RESYNC_REQUEST` on link-up.
- **iPad receive** (`ScaleSyncReceiver` + `TarabLink`): the receiver keeps its CoreMIDI plumbing (input port on all sources + the "Tarabdaar Scale" virtual destination) as the tunnel's reassembler; decoded events call the appliers, which publish and persist (`SyncedScaleStore` / `FretArrangementSyncStore`, UserDefaults blobs). `PitchPadEngine.applySyncedState` panics on a scale/layout change (no note stranded on a vanishing cell) and swaps scale/tonic/margin/layout.

One-way; the iPad has no scale editor or tonic readout. It persists the last synced state and opens on it after an offline relaunch. See [Fret Pad](fret-pad.md).

## External MIDI hosts

Neither side speaks MIDI to anything else: the iPad does not drive third-party DAWs, and the Mac plays nothing from an external MIDI controller. The instrument is played from the iPad's Fret Pad, the Mac's own pads and the Joy-Con.
