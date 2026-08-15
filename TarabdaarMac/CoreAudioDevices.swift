import CoreAudio
import Foundation

/// A CoreAudio output device suitable for AVAudioEngine routing.
struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let manufacturer: String?
    let isDefault: Bool
}

/// Thin wrapper around `AudioObjectGetPropertyData` for enumerating
/// output devices. The macOS app polls this when the Audio Settings
/// section appears; we don't subscribe to device-added/removed
/// notifications yet (Phase 6 nicety).
enum CoreAudioDevices {
    static func listOutputDevices() -> [AudioOutputDevice] {
        let defaultID = systemDefaultOutputDevice()
        return allDeviceIDs()
            .filter { isOutputDevice($0) }
            .map { id in
                AudioOutputDevice(
                    id: id,
                    name: deviceName(id) ?? "Device \(id)",
                    manufacturer: deviceManufacturer(id),
                    isDefault: id == defaultID
                )
            }
    }

    static func systemDefaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &dev
        )
        return status == noErr ? dev : 0
    }

    // MARK: - Private

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        )
        return status == noErr ? ids : []
    }

    private static func isOutputDevice(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        readString(id, selector: kAudioObjectPropertyName)
    }

    private static func deviceManufacturer(_ id: AudioDeviceID) -> String? {
        readString(id, selector: kAudioObjectPropertyManufacturer)
    }

    private static func readString(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfStr)
        guard status == noErr, let cf = cfStr?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
