import CoreBluetooth
import Foundation
import TarabdaarCore
import simd

// MARK: - Bearer 3: the Switch 2 vendor GATT

/// The Joy-Con 2 path: `JoyCon2BLE` owns the CoreBluetooth connection and
/// the console-style init; this type is only the PARSER, turning the two
/// notification streams into normalized reports.
final class JoyConBLETransport: JoyConTransport {
    var onReport: ((JoyConReport) -> Void)?
    var onStatus: ((String) -> Void)?
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?

    private let ble = JoyCon2BLE()
    private var generation = 0
    /// Full-report dump on a button change — the clone-mapping tool.
    private var lastAltButtons: [UInt8]?
    private var altMotionLengthLogged = false

    func connect() {
        ble.onStatus = { [weak self] s in self?.onStatus?(s) }
        ble.onConnect = { [weak self] name in
            guard let self else { return }
            self.generation += 1
            self.onConnect?(name)
        }
        ble.onDisconnect = { [weak self] in
            guard let self else { return }
            self.lastAltButtons = nil
            self.onDisconnect?()
        }
        ble.onNotification = { [weak self] data in
            self?.standardNotification(data)
        }
        ble.onAltNotification = { [weak self] data in
            self?.altNotification(data)
        }
        ble.start()
    }

    func disconnect() {
        ble.onNotification = nil
        ble.onAltNotification = nil
    }

    /// One Joy-Con 2 report-0x05 notification: buttons as a LE u32 at bytes
    /// 4–7 — left Joy-Con: dpad Down/Up/Right/Left = bits 16–19, SR 20,
    /// SL 21, L 22, ZL 23; shared: Minus 8, stick click 11, Capture 13 —
    /// and the 12-bit packed stick at bytes 10–12, device frame.
    private func standardNotification(_ d: Data) {
        guard d.count >= 13 else { return }
        let b = UInt32(d[4]) | (UInt32(d[5]) << 8)
              | (UInt32(d[6]) << 16) | (UInt32(d[7]) << 24)
        var down: Set<JoyConControl> = []
        if b & (1 << 16) != 0 { down.insert(.dpadDown) }
        if b & (1 << 17) != 0 { down.insert(.dpadUp) }
        if b & (1 << 18) != 0 { down.insert(.dpadRight) }
        if b & (1 << 19) != 0 { down.insert(.dpadLeft) }
        if b & (1 << 21) != 0 { down.insert(.sl) }
        if b & (1 << 22) != 0 { down.insert(.l) }
        if b & (1 << 20) != 0 { down.insert(.sr) }
        if b & (1 << 23) != 0 { down.insert(.zl) }
        if b & (1 << 8) != 0 { down.insert(.minus) }
        if b & (1 << 11) != 0 { down.insert(.stickClick) }
        if b & (1 << 13) != 0 { down.insert(.capture) }
        let s0 = Double(Int(d[10]) | (Int(d[11] & 0x0F) << 8))
        let s1 = Double((Int(d[11]) >> 4) | (Int(d[12]) << 4))
        // IMU (63-byte report): accel i16 LE ×3 at 0x30, gyro ×3 at 0x36,
        // classic scales (±8 g → /4096, ±2000 °/s → /16.4). Judge axes
        // against the FUSED panels, not the raw trails; if a 90°-in-1 s
        // turn reads ~730 °/s the JC2 gyro scale is 133.3 LSB/°/s instead.
        let now = CFAbsoluteTimeGetCurrent()
        var imu: [JoyConIMUSample] = []
        if d.count >= 0x3C {
            func i16(_ o: Int) -> Double {
                Double(Int16(bitPattern: UInt16(d[o]) | (UInt16(d[o + 1]) << 8)))
            }
            let accelG = SIMD3(i16(0x30), i16(0x32), i16(0x34)) / 4096.0
            let gyroDps = SIMD3(i16(0x36), i16(0x38), i16(0x3A)) / 16.4
            // Magnetometer: i16 ×3 at 0x19, raw units; streams only with
            // FEATURE_MAGNETOMETER (0x80) in the feature-enable flags. The
            // panel appears only on non-zero data.
            let mag: SIMD3<Double>? = d.count >= 0x1F
                ? SIMD3(i16(0x19), i16(0x1B), i16(0x1D)) : nil
            imu.append(JoyConIMUSample(t: now, gyroDps: gyroDps,
                                       accelG: accelG, mag: mag))
        }
        onReport?(JoyConReport(
            source: .ble, timestamp: now, generation: generation,
            buttons: .snapshot(down), stick: .raw(s0, s1), imu: imu,
            fuseIMU: true, hexPrefix: "ble: ",
            hexBytes: Array(d.prefix(13))))
    }

    /// THIRD-PARTY ALTERNATE INPUT: report 0x07 on CC1BBBB5-… (the Mobacon
    /// clone's stream). Byte 0 = counter; byte 2: Down 0x01, Right 0x02,
    /// Left 0x04, Up 0x08, L 0x10 (the M2 paddle mirrors it), ZL 0x20,
    /// Minus 0x40, stick click 0x80; byte 3: Capture 0x01, SR 0x40, SL
    /// 0x80; 12-bit packed stick at bytes 5–7; byte 4 = constant flags.
    /// A button change dumps the full report for mapping.
    private func altNotification(_ d: Data) {
        guard d.count >= 8 else { return }
        let btn = [d[2], d[3], d[4]]
        if let last = lastAltButtons, btn != last {
            NSLog("Tarabdaar ble: alt buttons %02x %02x %02x → %02x %02x %02x  full [%@]",
                  last[0], last[1], last[2], btn[0], btn[1], btn[2],
                  d.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        lastAltButtons = btn
        var down: Set<JoyConControl> = []
        if d[2] & 0x01 != 0 { down.insert(.dpadDown) }
        if d[2] & 0x02 != 0 { down.insert(.dpadRight) }
        if d[2] & 0x04 != 0 { down.insert(.dpadLeft) }
        if d[2] & 0x08 != 0 { down.insert(.dpadUp) }
        if d[2] & 0x10 != 0 { down.insert(.l) }   // L (and the M2 mirror)
        if d[2] & 0x20 != 0 { down.insert(.zl) }
        if d[2] & 0x40 != 0 { down.insert(.minus) }
        if d[2] & 0x80 != 0 { down.insert(.stickClick) }
        if d[3] & 0x01 != 0 { down.insert(.capture) }
        if d[3] & 0x80 != 0 { down.insert(.sl) }
        if d[3] & 0x40 != 0 { down.insert(.sr) }
        let s0 = Double(Int(d[5]) | (Int(d[6] & 0x0F) << 8))
        let s1 = Double((Int(d[6]) >> 4) | (Int(d[7]) << 4))
        // Motion: a LENGTH byte at 0x0E ({0, 30, 40}) + an undecoded packed
        // blob at 0x0F — not parsed; logged once if a device fills it.
        if d.count > 0x0E, d[0x0E] != 0, !altMotionLengthLogged {
            altMotionLengthLogged = true
            NSLog("Tarabdaar ble: alt report motion length %d — packed format, not decoded",
                  d[0x0E])
        }
        onReport?(JoyConReport(
            source: .bleAlt, timestamp: CFAbsoluteTimeGetCurrent(),
            generation: generation,
            buttons: .snapshot(down), stick: .raw(s0, s1),
            hexPrefix: "alt: ", hexBytes: Array(d.prefix(13))))
    }
}

/// CoreBluetooth client for Switch 2 Joy-Cons: scan broadly, filter on
/// Nintendo's manufacturer-data company ID, connect, run the console-style
/// init, subscribe to the input characteristic, forward notifications.
/// First connection needs the Joy-Con advertising — hold its sync button.
/// One peripheral at a time; rescans when unconnected. Main-queue delegate.
final class JoyCon2BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0")
    static let inputCharacteristic = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2")
    /// The `0x91`-framed command channel (the classic `30 …` subcommand
    /// format is IGNORED by Joy-Con 2): commands write here, acks arrive
    /// on the response characteristic.
    static let commandWriteCharacteristic =
        CBUUID(string: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005")
    static let commandResponseCharacteristic =
        CBUUID(string: "C765A961-D9D8-4D36-A20A-5315B111836A")
    /// The controller-specific report-0x07 characteristic — where clones
    /// stream their input (`bleAltNotification`).
    static let altInputCharacteristic =
        CBUUID(string: "CC1BBBB5-7354-4D32-A716-A81CB241A32A")
    /// Nintendo's Bluetooth SIG company identifier — NOT 0x057E (their USB
    /// vendor ID, which appears further into the payload: a live Joy-Con 2
    /// (L) advertises `53 05 01 00 03 7e 05 67 20 …`, name empty).
    private static let nintendoCompanyID: UInt16 = 0x0553

    var onStatus: ((String) -> Void)?
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onNotification: ((Data) -> Void)?
    /// Notifications from the alternate input characteristic — forwarded
    /// only while the standard input characteristic stays silent.
    var onAltNotification: ((Data) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// The command write characteristic.
    private var outputCharacteristic: CBCharacteristic?
    private var inputCharacteristic: CBCharacteristic?
    private var cmdRespCharacteristic: CBCharacteristic?
    private var ledSent = false
    private var initStarted = false
    // Wire diagnostics (Console filter `Tarabdaar ble`): arrival/rate, and
    // a full hex dump whenever the button word (bytes 4–7) changes.
    private var notifCount = 0
    private var lastNotifLog: CFAbsoluteTime = 0
    private var lastButtonWord: UInt32?
    /// Per-characteristic log throttle for unknown characteristics.
    private var lastCharLog: [CBUUID: CFAbsoluteTime] = [:]
    // MOTION-ENABLE PROBE (clones only): walk every write-capable
    // characteristic × two command dialects (0x91 feature-enable, classic
    // subcommand mode+IMU), one per 1.2 s, watching the motion-length byte.
    private var probeChars: [CBCharacteristic] = []
    private var probeStarted = false
    private var probeStep = -1
    private var altMotionSeen = false
    /// Notify-capable characteristics other than the standard input and
    /// command-response ones. Subscribed only by `scheduleAltFallback` — a
    /// real Joy-Con 2 silences report 0x05 the moment 0x07 is enabled.
    private var deferredNotifyChars: [CBCharacteristic] = []
    /// Silence allowed on the standard input characteristic before the
    /// clone fallback subscribes the rest (a real Joy-Con 2 streams within
    /// ~100 ms of the CCCD write).
    static let altFallbackDelay: TimeInterval = 2.0

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: scan()
        case .unauthorized: onStatus?("Bluetooth permission denied — grant in System Settings ▸ Privacy")
        case .poweredOff: onStatus?("Bluetooth is off")
        default: onStatus?("Bluetooth unavailable")
        }
    }

    private func scan() {
        guard let central, central.state == .poweredOn, peripheral == nil
        else { return }
        // The advertisement doesn't list the vendor service — scan broadly.
        central.scanForPeripherals(withServices: nil)
        onStatus?("scanning — hold the Joy-Con 2 sync button")
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        var nintendo = false
        if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 {
            let bytes = [UInt8](m)
            let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            nintendo = company == Self.nintendoCompanyID
        }
        // Name fallback only — a live Joy-Con 2 advertises an EMPTY name.
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "")
        if !nintendo {
            nintendo = name.localizedCaseInsensitiveContains("joy-con")
        }
        guard nintendo, peripheral == nil else { return }
        peripheral = p
        c.stopScan()
        let mfg = (ad[CBAdvertisementDataManufacturerDataKey] as? Data)?
            .prefix(12).map { String(format: "%02x", $0) }
            .joined(separator: " ") ?? "—"
        NSLog("Tarabdaar ble: discovered \"%@\" rssi %@ mfg [%@]",
              name.isEmpty ? "(no name)" : name, rssi, mfg)
        onStatus?("connecting — \(name.isEmpty ? "Joy-Con 2" : name)")
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.delegate = self
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral,
                        error: Error?) {
        peripheral = nil
        onStatus?("connect failed — \(error?.localizedDescription ?? "?")")
        scan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        peripheral = nil
        outputCharacteristic = nil
        inputCharacteristic = nil
        cmdRespCharacteristic = nil
        ledSent = false
        initStarted = false
        lastCharLog = [:]
        probeChars = []
        probeStarted = false
        probeStep = -1
        altMotionSeen = false
        NSLog("Tarabdaar ble: disconnected after %d notifications — %@",
              notifCount, error?.localizedDescription ?? "clean")
        notifCount = 0
        lastButtonWord = nil
        onDisconnect?()
        onStatus?("disconnected")
        scan()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        NSLog("Tarabdaar ble: services [%@]%@",
              services.map { $0.uuid.uuidString }.joined(separator: ", "),
              error.map { " error: \($0.localizedDescription)" } ?? "")
        guard services.contains(where: { $0.uuid == Self.service }) else {
            // No vendor service — drop it and keep scanning.
            onStatus?("no Joy-Con 2 input service — skipping \(p.name ?? "device")")
            central?.cancelPeripheralConnection(p)
            return
        }
        // The command channel may live in another service — sweep all.
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        NSLog("Tarabdaar ble: service %@ chars [%@]",
              service.uuid.uuidString,
              (service.characteristics ?? []).map {
                  String(format: "%@ (props 0x%02x)",
                         $0.uuid.uuidString, $0.properties.rawValue)
              }.joined(separator: ", "))
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.inputCharacteristic:
                inputCharacteristic = ch
            case Self.commandResponseCharacteristic:
                // Subscribe before commanding — acks land here.
                cmdRespCharacteristic = ch
                p.setNotifyValue(true, for: ch)
            case Self.commandWriteCharacteristic:
                outputCharacteristic = ch
                ledSent = false
            default:
                break
            }
        }
        // Read every readable characteristic: a write-without-response
        // cannot surface an ATT "insufficient authentication" error, a
        // READ does — and macOS then pairs itself. Other notify chars are
        // only COLLECTED here (see `deferredNotifyChars`).
        for ch in service.characteristics ?? [] {
            if ch.properties.contains(.read) {
                p.readValue(for: ch)
            }
            if ch.properties.contains(.notify),
               ch.uuid != Self.inputCharacteristic,
               ch.uuid != Self.commandResponseCharacteristic,
               !deferredNotifyChars.contains(where: { $0.uuid == ch.uuid }) {
                deferredNotifyChars.append(ch)
            }
            if ch.properties.contains(.write)
                || ch.properties.contains(.writeWithoutResponse),
               !probeChars.contains(where: { $0.uuid == ch.uuid }) {
                probeChars.append(ch)
            }
        }
        maybeBeginInit(p)
        // A device exposing the input characteristic without the command
        // channel: subscribe directly.
        if inputCharacteristic != nil, !initStarted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.peripheral === p, !self.initStarted,
                      let input = self.inputCharacteristic else { return }
                self.initStarted = true
                NSLog("Tarabdaar ble: no command channel — subscribing input directly")
                p.setNotifyValue(true, for: input)
                self.onConnect?(p.name ?? "Joy-Con 2")
                self.scheduleAltFallback(p)
            }
        }
    }

    /// CLONE FALLBACK: if no report-0x05 notification has arrived
    /// `altFallbackDelay` after the standard subscribe, subscribe every
    /// other notify characteristic (a real Joy-Con 2 never reaches this).
    private func scheduleAltFallback(_ p: CBPeripheral) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.altFallbackDelay) { [weak self] in
            guard let self, self.peripheral === p else { return }
            guard self.notifCount == 0 else { return }
            NSLog("Tarabdaar ble: standard input silent for %.1f s — subscribing %d alternate characteristic(s) (clone fallback)",
                  Self.altFallbackDelay, self.deferredNotifyChars.count)
            for ch in self.deferredNotifyChars {
                p.setNotifyValue(true, for: ch)
            }
        }
    }

    /// CONSOLE-STYLE INIT: a real Joy-Con 2 streams on subscribe alone, but
    /// clones wait for the console handshake (and drop the link after
    /// 60 s). Sequence: controller-info read → player LED → vibration
    /// preset (tactile proof) → feature init/enable → INPUT subscribe LAST,
    /// paced by delay rather than acks (a clone that acks nothing stalls).
    private func maybeBeginInit(_ p: CBPeripheral) {
        guard !initStarted, let input = inputCharacteristic,
              outputCharacteristic != nil, cmdRespCharacteristic != nil
        else { return }
        initStarted = true
        let steps: [(Double, String, () -> Void)] = [
            (0.30, "controller-info read", { [weak self] in self?.readControllerInfo() }),
            (0.55, "player LED", { [weak self] in self?.setPlayerLED(1) }),
            (0.80, "vibration preset", { [weak self] in self?.playVibrationPreset(0x03) }),
            (1.05, "feature enable", { [weak self] in self?.enableFeatures() }),
            (1.30, "input subscribe", { [weak self] in
                guard let self, self.peripheral === p else { return }
                p.setNotifyValue(true, for: input)
                self.onConnect?(p.name ?? "Joy-Con 2")
                self.scheduleAltFallback(p)
            }),
        ]
        for (delay, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.peripheral === p else { return }
                NSLog("Tarabdaar ble: init — %@", name)
                action()
            }
        }
    }

    /// The console's first command: read 0x40 bytes of controller info
    /// at 0x00013000 (command 0x02 = memory, subcommand 0x04 = read;
    /// payload = length, 7e 00 00, address little-endian).
    private func readControllerInfo() {
        writeCommand(0x02, 0x04,
                     [0x40, 0x7E, 0x00, 0x00, 0x00, 0x30, 0x01, 0x00])
    }

    /// Play a built-in rumble preset (command 0x0A, subcommand 0x02);
    /// 0x03 = soft.
    private func playVibrationPreset(_ preset: UInt8) {
        writeCommand(0x0A, 0x02, [preset, 0x00, 0x00, 0x00])
    }

    /// Assign the player-number LEDs — without this the lights race
    /// forever. `0x91` framing on the command characteristic: command 0x09
    /// = LEDs, subcommand 0x07 = set player, pattern 0x01 = player 1.
    private func setPlayerLED(_ player: Int) {
        let patterns: [UInt8] = [0x01, 0x03, 0x07, 0x0F, 0x09, 0x05, 0x0D, 0x06]
        writeCommand(0x09, 0x07,
                     [patterns[max(0, min(7, player - 1))], 0x00, 0x00, 0x00])
        ledSent = true
    }

    /// Feature init + enable: 0x07 = base | FEATURE_MOTION 0x04, 0x80 =
    /// FEATURE_MAGNETOMETER (the mag block at 0x19). The two commands MUST
    /// be spaced 150 ms: back to back, the ack returns zeros, motion off.
    private func enableFeatures() {
        let flags: [UInt8] = [0x87, 0x00, 0x00, 0x00]
        writeCommand(0x0C, 0x02, flags)   // SUBCOMMAND_FEATURE_INIT
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.writeCommand(0x0C, 0x04, flags)   // SUBCOMMAND_FEATURE_ENABLE
        }
    }

    /// One `0x91`-framed command:
    /// `<cmd> 91 01 <sub> 00 <len> 00 00 <payload…>`.
    private func writeCommand(_ command: UInt8, _ subcommand: UInt8,
                              _ payload: [UInt8]) {
        guard let p = peripheral, let ch = outputCharacteristic else {
            NSLog("Tarabdaar ble: command %02x/%02x dropped — no command characteristic",
                  command, subcommand)
            return
        }
        NSLog("Tarabdaar ble: command %02x/%02x sent", command, subcommand)
        let cmd: [UInt8] = [command, 0x91, 0x01, subcommand, 0x00,
                            UInt8(payload.count), 0x00, 0x00] + payload
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse
                                                          : .withResponse
        p.writeValue(Data(cmd), for: ch, type: type)
    }

    /// Motion-probe success detector: report 0x07's motion-length byte at
    /// 0x0E is 0 with the IMU off, 30 or 40 once enabled.
    private func checkAltMotion(_ d: Data) {
        guard !altMotionSeen, d.count > 0x0E else { return }
        let nonzero = d[0x0E] != 0
        if nonzero {
            altMotionSeen = true
            NSLog("Tarabdaar ble: ALT MOTION LIVE — IMU region nonzero (after probe step %d)",
                  probeStep)
        }
    }

    /// Raw write for the motion probe — any characteristic.
    private func probeWrite(_ ch: CBCharacteristic, _ bytes: [UInt8]) {
        guard let p = peripheral else { return }
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse
                                                          : .withResponse
        p.writeValue(Data(bytes), for: ch, type: type)
    }

    /// Walk every write-capable characteristic with both command dialects.
    /// Steps stop the moment `checkAltMotion` fires.
    private func startMotionProbe() {
        guard peripheral != nil, !altMotionSeen, !probeChars.isEmpty else { return }
        let feat: [[UInt8]] = [
            [0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x87, 0x00, 0x00, 0x00],
            [0x0C, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0x87, 0x00, 0x00, 0x00],
        ]
        let classic: [[UInt8]] = [
            [0x01, 0x01, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x03, 0x30],
            [0x01, 0x02, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x40, 0x01],
        ]
        var steps: [(String, CBCharacteristic, [[UInt8]])] = []
        for ch in probeChars {
            steps.append(("0x91 feature-enable", ch, feat))
            steps.append(("classic mode+IMU", ch, classic))
        }
        NSLog("Tarabdaar ble: motion probe starting — %d candidates over %d write chars",
              steps.count, probeChars.count)
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) { [weak self] in
                guard let self, self.peripheral != nil, !self.altMotionSeen
                else { return }
                self.probeStep = i
                NSLog("Tarabdaar ble: motion probe %d/%d — %@ → %@",
                      i + 1, steps.count, step.0, step.1.uuid.uuidString)
                self.probeWrite(step.1, step.2[0])
                if step.2.count > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self, self.peripheral != nil else { return }
                        self.probeWrite(step.1, step.2[1])
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(steps.count) * 1.2 + 1.0
        ) { [weak self] in
            guard let self, self.peripheral != nil, !self.altMotionSeen
            else { return }
            NSLog("Tarabdaar ble: motion probe exhausted — IMU region still zero")
        }
    }

    func peripheral(_ p: CBPeripheral,
                    didUpdateNotificationStateFor ch: CBCharacteristic,
                    error: Error?) {
        NSLog("Tarabdaar ble: notify %@ on %@%@",
              ch.isNotifying ? "ON" : "OFF", ch.uuid.uuidString,
              error.map { " error: \($0.localizedDescription)" } ?? "")
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic,
                    error: Error?) {
        if let error {
            NSLog("Tarabdaar ble: write to %@ FAILED — %@",
                  ch.uuid.uuidString, error.localizedDescription)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic,
                    error: Error?) {
        if let error {
            // An "insufficient authentication" ATT error = a paired link is
            // wanted; macOS follows up by pairing.
            NSLog("Tarabdaar ble: read/notify on %@ FAILED — %@",
                  ch.uuid.uuidString, error.localizedDescription)
            return
        }
        if ch.uuid == Self.commandResponseCharacteristic {
            let hex = (ch.value ?? Data()).prefix(16)
                .map { String(format: "%02x", $0) }.joined(separator: " ")
            NSLog("Tarabdaar ble: command ack [%@]", hex)
            return
        }
        if ch.uuid == Self.altInputCharacteristic {
            // Report-0x07 stream (clone fallback): forwarded only while the
            // standard characteristic is silent — never races the 0x05 parse.
            if notifCount == 0, let d = ch.value {
                onAltNotification?(d)
                checkAltMotion(d)
                if !probeStarted {
                    probeStarted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.startMotionProbe()
                    }
                }
            }
            return
        }
        if ch.uuid != Self.inputCharacteristic {
            // Reads and unknown-characteristic notifications, throttled.
            let now = CFAbsoluteTimeGetCurrent()
            if now - (lastCharLog[ch.uuid] ?? 0) > 1 {
                lastCharLog[ch.uuid] = now
                let d = ch.value ?? Data()
                NSLog("Tarabdaar ble: %@ value, %d bytes [%@]",
                      ch.uuid.uuidString, d.count, d.prefix(24)
                          .map { String(format: "%02x", $0) }.joined(separator: " "))
            }
            return
        }
        // If the LED write raced discovery, re-send once input flows.
        if !ledSent, outputCharacteristic != nil {
            setPlayerLED(1)
            enableFeatures()
        }
        guard let d = ch.value else { return }
        notifCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if notifCount == 1 || now - lastNotifLog > 5 {
            lastNotifLog = now
            NSLog("Tarabdaar ble: input #%d, %d bytes [%@]",
                  notifCount, d.count, d.prefix(16)
                      .map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        if d.count >= 8 {
            let word = UInt32(d[4]) | (UInt32(d[5]) << 8)
                     | (UInt32(d[6]) << 16) | (UInt32(d[7]) << 24)
            if let last = lastButtonWord, word != last {
                NSLog("Tarabdaar ble: buttons %08x → %08x  full [%@]",
                      last, word, d.map { String(format: "%02x", $0) }
                          .joined(separator: " "))
            }
            lastButtonWord = word
        }
        onNotification?(d)
    }
}
