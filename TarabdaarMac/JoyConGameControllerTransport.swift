import Foundation
import GameController
import TarabdaarCore
import simd

// MARK: - Bearer 1: the GameController profile

/// The framework path: whatever macOS itself presents. Delivers button
/// EDGES (one callback per element), the stick already in unit range, and
/// — on pads whose presentation carries one — a motion profile.
///
/// Every handler consults `standDown` first: once the raw HID stream is in
/// full mode it carries the same buttons at higher fidelity, and letting
/// both through fires each press twice. Motion is exempt — nothing else
/// delivers it.
final class JoyConGameControllerTransport: JoyConTransport {
    var onReport: ((JoyConReport) -> Void)?
    /// Device name + the alias-grouped element inventory.
    var onAttach: ((String, [String]) -> Void)?
    var onDetach: (() -> Void)?
    /// Raw element traffic for the panel's "last event" line.
    var onRawEvent: ((GCControllerElement) -> Void)?
    /// True while the raw HID full-mode stream owns the buttons.
    var standDown: () -> Bool = { false }

    private var attached: GCController?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    /// A LONE Joy-Con is presented SIDEWAYS; held UPRIGHT, stick and face
    /// buttons rotate 90° back (upright (x, y) → sideways (−y, x)). A
    /// paired L+R duo ("Joy-Con (L/R)") is a real gamepad — no rotation.
    private var rotateForUpright = false

    var isAttached: Bool { attached != nil }

    func connect() {
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let c = note.object as? GCController else { return }
            self?.attach(c)
        })
        observers.append(nc.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let c = note.object as? GCController,
                  c === self.attached else { return }
            self.detach()
            NSLog("Tarabdaar: game controller disconnected")
            // Fall over to any other controller still paired.
            if let next = GCController.controllers().first { self.attach(next) }
        })
        if let c = GCController.controllers().first { attach(c) }
    }

    func disconnect() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        detach()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// One controller at a time — the first to appear wins.
    private func attach(_ c: GCController) {
        guard attached == nil else { return }
        attached = c
        generation += 1
        let name = c.vendorName ?? c.productCategory
        c.handlerQueue = .main
        let profile = c.physicalInputProfile

        var groups: [ObjectIdentifier: [String]] = [:]
        for (elementName, el) in profile.elements {
            groups[ObjectIdentifier(el), default: []].append(elementName)
        }
        let elements = groups.values
            .map { $0.sorted().joined(separator: " / ") }.sorted()
        onAttach?(name, elements)
        NSLog("Tarabdaar: game controller attached — %@ [%@]",
              name, elements.joined(separator: ", "))

        profile.valueDidChangeHandler = { [weak self] _, element in
            self?.onRawEvent?(element)
        }

        let cat = c.productCategory
        rotateForUpright = cat.localizedCaseInsensitiveContains("joy-con")
            && !cat.localizedCaseInsensitiveContains("l/r")

        // The stick: left thumbstick, else right, else a lone Direction Pad.
        let stick = profile.dpads[GCInputLeftThumbstick]
            ?? profile.dpads[GCInputRightThumbstick]
            ?? profile.dpads[GCInputDirectionPad]
        stick?.valueChangedHandler = { [weak self] _, x, y in
            guard let self, !self.standDown() else { return }
            if self.rotateForUpright {
                // Sideways frame → upright: x = y_os, y = −x_os.
                self.emit(stick: .unit(Double(y), Double(-x)))
            } else {
                self.emit(stick: .unit(Double(x), Double(y)))
            }
        }

        // A d-pad element only when DISTINCT from the stick (alias trap)…
        if let dpad = profile.dpads[GCInputDirectionPad], dpad !== stick {
            bind(dpad.up, .dpadUp)
            bind(dpad.down, .dpadDown)
            bind(dpad.left, .dpadLeft)
            bind(dpad.right, .dpadRight)
        }
        // …and the sideways A/B/X/Y, rotated 90° CCW: A=↓, B=←, X=→, Y=↑.
        if rotateForUpright {
            bind(profile.buttons[GCInputButtonA], .dpadDown)
            bind(profile.buttons[GCInputButtonB], .dpadLeft)
            bind(profile.buttons[GCInputButtonX], .dpadRight)
            bind(profile.buttons[GCInputButtonY], .dpadUp)
        } else {
            bind(profile.buttons[GCInputButtonA], .dpadRight)
            bind(profile.buttons[GCInputButtonB], .dpadDown)
            bind(profile.buttons[GCInputButtonX], .dpadUp)
            bind(profile.buttons[GCInputButtonY], .dpadLeft)
        }

        // Shoulder family: L/ZL naming is presentation-dependent, bind all.
        if rotateForUpright {
            // Sideways: the rail's SL/SR are Left/Right Shoulder.
            bind(profile.buttons[GCInputLeftShoulder], .sl)
            bind(profile.buttons[GCInputRightShoulder], .sr)
            bind(profile.buttons[GCInputLeftTrigger], .l)
            bind(profile.buttons[GCInputRightTrigger], .zl)
        } else {
            bind(profile.buttons[GCInputLeftShoulder], .l)
            bind(profile.buttons[GCInputLeftTrigger], .zl)
            bind(profile.buttons[GCInputRightShoulder], .sr)
            bind(profile.buttons[GCInputRightTrigger], .sr)
        }
        bind(profile.buttons[GCInputButtonOptions], .minus)
        bind(profile.buttons[GCInputLeftThumbstickButton], .stickClick)

        // GC MOTION (classic-Bluetooth pads: Pro Controller presentations,
        // multi-mode pads in Switch-1 mode) — same fusion + panels as the
        // BLE path; acceleration includes gravity, rotation rate in rad/s.
        if let motion = c.motion {
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = true
            }
            NSLog("Tarabdaar: GC motion available (manual activation %@, rotation rate %@)",
                  motion.sensorsRequireManualActivation ? "yes" : "no",
                  motion.hasRotationRate ? "yes" : "no")
            motion.valueChangedHandler = { [weak self] m in
                guard let self else { return }
                let a = SIMD3(m.acceleration.x, m.acceleration.y,
                              m.acceleration.z)
                let w = m.hasRotationRate
                    ? SIMD3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z)
                    : SIMD3<Double>.zero
                let now = CFAbsoluteTimeGetCurrent()
                self.onReport?(JoyConReport(
                    source: .gameController, timestamp: now,
                    generation: self.generation,
                    imu: [JoyConIMUSample(t: now, gyroDps: w * 180 / .pi,
                                          accelG: a, gyroRadPerSec: w)],
                    fuseIMU: true))
            }
        } else {
            NSLog("Tarabdaar: GC controller has no motion profile")
        }
    }

    private func detach() {
        attached?.motion?.valueChangedHandler = nil
        attached = nil
        onDetach?()
    }

    private func bind(_ button: GCControllerButtonInput?, _ control: JoyConControl) {
        button?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self, !self.standDown() else { return }
            self.onReport?(JoyConReport(
                source: .gameController, timestamp: CFAbsoluteTimeGetCurrent(),
                generation: self.generation,
                buttons: .edge(control, pressed)))
        }
    }

    private func emit(stick: JoyConStickValue) {
        onReport?(JoyConReport(source: .gameController,
                               timestamp: CFAbsoluteTimeGetCurrent(),
                               generation: generation, stick: stick))
    }
}
