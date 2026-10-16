#if os(macOS)
import AppKit
import AVFoundation
import CoreAudio

struct AudioOutputRoute: Equatable {
    let id: AudioDeviceID
    let uid: String
}

/// The recovery policy can exercise disappearance and failed restarts without changing host devices.
protocol AudioOutputRecoveryDriver: AnyObject {
    var availableOutputRoutes: [AudioOutputRoute] { get }
    var defaultOutputDevice: AudioDeviceID { get }
    var activeOutputDevice: AudioDeviceID { get }
    func outputIsHealthy(on device: AudioDeviceID) -> Bool
    func startOutput(on device: AudioDeviceID, matchRate: Bool) throws
    func stopOutput()
    func outputRecoveryChanged(selection: AudioDeviceID, error: String?)
}

/// Main-queue owner of route intent, recovery retries and sleep state; never runs on the audio thread.
final class AudioOutputRecovery {
    private weak var driver: AudioOutputRecoveryDriver?
    private(set) var preferredUID: String?
    private var selectedID: AudioDeviceID = 0
    private(set) var active = false
    private(set) var sleeping = false
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var attempts = 0
    private var lastTarget: AudioDeviceID?
    private var selectionError: String?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var healthTimer: DispatchSourceTimer?
    private let retryDelays: [Double]

    init(driver: AudioOutputRecoveryDriver, retryDelays: [Double] = [0.1, 0.25, 0.5, 1, 2]) {
        self.driver = driver
        self.retryDelays = retryDelays
    }

    func start() {
        precondition(Thread.isMainThread)
        active = true
        recover(matchRate: true)
    }

    /// ID zero means follow the system default, including future default-device changes.
    @discardableResult
    func select(_ id: AudioDeviceID) -> Bool {
        precondition(Thread.isMainThread)
        guard let driver else { return false }
        let route = driver.availableOutputRoutes.first { $0.id == id }
        guard id == 0 || route != nil else {
            selectionError = "Output device \(id) is unavailable"
            publish(error: selectionError)
            return false
        }
        let previous = (preferredUID, selectedID)
        preferredUID = route?.uid
        selectedID = id
        selectionError = nil
        cancelPending()
        attempts = 0
        if !active || sleeping { publish(error: nil); return true }
        do {
            guard let target = desiredDevice() else { throw AudioOutputError.unavailable }
            try driver.startOutput(on: target, matchRate: true)
            publish(error: nil)
            return true
        } catch {
            (preferredUID, selectedID) = previous
            selectionError = "Output switch failed: \(error.localizedDescription)"
            // A failed switch must not replace the requested route or strand a working engine.
            recover(matchRate: false)
            return false
        }
    }

    func configurationChanged() {
        precondition(Thread.isMainThread)
        guard active, !sleeping else { return }
        let target = desiredDevice()
        if target != lastTarget {
            cancelPending()
            attempts = 0
            lastTarget = target
        }
        guard let driver, let device = target, driver.outputIsHealthy(on: device) else {
            // Coalesce device/engine notifications. Self-generated notifications do not reset retries.
            schedule(after: 0.1)
            return
        }
        publish(error: selectionError)
    }

    func setSleeping(_ value: Bool) {
        precondition(Thread.isMainThread)
        guard active, value != sleeping else { return }
        sleeping = value
        cancelPending()
        attempts = 0
        if value { driver?.stopOutput() }
        else { schedule(after: 0.1) }
    }

    func shutdown() {
        active = false
        cancelPending()
        healthTimer?.cancel()
        healthTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for (object, var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }

    private func desiredDevice() -> AudioDeviceID? {
        guard let driver else { return nil }
        let routes = driver.availableOutputRoutes
        if let uid = preferredUID, let route = routes.first(where: { $0.uid == uid }) { return route.id }
        // A missing selected device temporarily uses the system default; its UID stays reserved.
        return routes.first(where: { $0.id == driver.defaultOutputDevice })?.id
    }

    private func publish(error: String?) {
        guard let driver else { return }
        let selection = preferredUID.flatMap { uid in
            driver.availableOutputRoutes.first(where: { $0.uid == uid })?.id
        } ?? selectedID
        selectedID = selection
        driver.outputRecoveryChanged(selection: selection, error: error)
    }

    private func recover(matchRate: Bool = false) {
        guard active, !sleeping, let driver else { return }
        lastTarget = desiredDevice()
        guard let device = lastTarget else {
            driver.stopOutput()
            publish(error: "No output device available")
            retry()
            return
        }
        do {
            if !driver.outputIsHealthy(on: device) {
                try driver.startOutput(on: device, matchRate: matchRate || driver.activeOutputDevice != device)
            }
            attempts = 0
            publish(error: selectionError)
        } catch {
            driver.stopOutput()
            publish(error: "Audio recovery failed: \(error.localizedDescription)")
            retry()
        }
    }

    private func retry() {
        guard attempts < retryDelays.count else {
            schedule(after: 5)
            return
        }
        let delay = retryDelays[attempts]
        attempts += 1
        schedule(after: delay)
    }

    private func schedule(after delay: Double) {
        guard pending == nil else { return }
        let expected = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expected, self.active, !self.sleeping else { return }
            self.pending = nil
            self.recover()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPending() {
        generation += 1
        pending?.cancel()
        pending = nil
    }

    func observe(engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.configurationChanged() }
            }))
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.setSleeping(sleeping) }
            }))
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.configurationChanged()
            }
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                &address, DispatchQueue.main, block)
            if status == noErr { listeners.append((AudioObjectID(kAudioObjectSystemObject), address, block)) }
            else { NSLog("Tarabdaar: output-device observer failed: \(status)") }
        }
        // Also catches missed notifications and keeps the published running state honest.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.configurationChanged() }
        healthTimer = timer
        timer.resume()
    }

    deinit { shutdown() }
}

enum AudioOutputError: LocalizedError {
    case unavailable
    case coreAudio(String, OSStatus)
    case format(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "No usable output device"
        case let .coreAudio(operation, status): return "\(operation) (CoreAudio \(status))"
        case let .format(message): return message
        }
    }
}
#endif
