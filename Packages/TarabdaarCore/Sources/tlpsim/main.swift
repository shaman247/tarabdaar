// Fake iPad: the REAL pad-side TLP stack (OutboundPlayState + TarabLink
// role .pad + ScaleSyncReceiver) over REAL CoreMIDI, driven by a script —
// synthetic 60 Hz tilt jitter (a real device's tilt never sits still, so
// every tick is dirty: worst-case frame rate) plus held, gliding touches.
// Run beside a live TarabdaarMac and watch both logs.
//
// Outbound rides a virtual source ("tlpsim Out") the Mac's MIDIInput
// auto-connects to; inbound arrives on ScaleSyncReceiver's "Tarabdaar
// Scale" virtual destination via the Mac's event-send fallback.
//
// Usage: swift run tlpsim [seconds]

import CoreMIDI
import Foundation
import TarabdaarCore

let runSeconds = CommandLine.arguments.count > 1
    ? Double(CommandLine.arguments[1]) ?? 20 : 20

var client = MIDIClientRef()
var source = MIDIEndpointRef()
MIDIClientCreateWithBlock("tlpsim" as CFString, &client) { _ in }
MIDISourceCreate(client, "tlpsim Out" as CFString, &source)

func sendSysEx(_ bytes: [UInt8]) {
    let bufSize = bytes.count + 128
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: bufSize, alignment: MemoryLayout<MIDIPacketList>.alignment)
    defer { raw.deallocate() }
    let listPtr = raw.assumingMemoryBound(to: MIDIPacketList.self)
    var packet = MIDIPacketListInit(listPtr)
    packet = MIDIPacketListAdd(listPtr, bufSize, packet, 0, bytes.count, bytes)
    MIDIReceived(source, listPtr)
}

let state = OutboundPlayState()
let link = TarabLink(role: .pad)
let scaleSync = ScaleSyncReceiver()

var sentFrames = 0
var rxJoy = 0
link.attach(playState: state)
link.sendRaw = { bytes, _ in
    sentFrames += 1
    sendSysEx(bytes)
}
scaleSync.onSysEx = { link.receivedSysEx($0) }
link.onEvent = { event in NSLog("tlpsim: event \(event)") }
link.onJoyConState = { _ in rxJoy += 1 }
link.onStatus = { s in
    NSLog("tlpsim: status up=%d stale=%d rtt=%@",
          s.isUp ? 1 : 0, s.isStale ? 1 : 0,
          s.rttMs.map { String(format: "%.1fms", $0) } ?? "–")
}

scaleSync.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { link.start() }

// 60 Hz tilt jitter — a random walk changing EVERY tick, like a real
// accelerometer, so the outbound state is permanently dirty.
var tilt: [Double] = [0.5, 0.5, 0.5]
let tiltTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
    for a in 0..<3 {
        tilt[a] = min(max(tilt[a] + Double.random(in: -0.004...0.004), 0), 1)
        state.setTilt(a, tilt[a])
    }
}
RunLoop.main.add(tiltTimer, forMode: .common)

// Script: held 4-s touches with continuous glide — kills/staccato become
// unmistakable in the Mac's readout log.
func playPhrase(at t: Double, token: String, basePitch: Double) {
    DispatchQueue.main.asyncAfter(deadline: .now() + t) {
        NSLog("tlpsim: touchOn %@", token)
        state.touchOn(token, pitchSemis: basePitch, velocity: 0.8)
    }
    for i in 1...40 {
        DispatchQueue.main.asyncAfter(deadline: .now() + t + Double(i) * 0.1) {
            state.touchGlide(token, pitchSemis: basePitch + Double(i) * 0.02)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + t + 4.2) {
        NSLog("tlpsim: touchOff %@", token)
        state.touchOff(token)
    }
}
playPhrase(at: 3.0, token: "simA", basePitch: 55.0)
playPhrase(at: 9.0, token: "simB", basePitch: 60.0)

// 1 Hz outbound-rate report.
let rateTimer = Timer(timeInterval: 1.0, repeats: true) { _ in
    NSLog("tlpsim: sent %d msgs so far, joycon rx %d", sentFrames, rxJoy)
}
RunLoop.main.add(rateTimer, forMode: .common)

DispatchQueue.main.asyncAfter(deadline: .now() + runSeconds) {
    NSLog("tlpsim: done — sent %d, joycon rx %d", sentFrames, rxJoy)
    exit(0)
}

RunLoop.main.run()
