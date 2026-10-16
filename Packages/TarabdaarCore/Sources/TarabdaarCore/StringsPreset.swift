import Foundation
import SarangiKit

/// The editable Strings-tab setup; pitch references resolve against the active tuning.
public struct StringsPreset: Codable, Sendable {
    public var version = 1
    public var strings: [StringSpec]
    public var droneStringIds: [UUID?]
    public var strumStringIds: [UUID]
    public var droneVoice: String
    public var droneSequence: [Int]

    public init(state: InstrumentState, droneVoice: String,
                droneSequence: [Int]) {
        strings = state.strings
        droneStringIds = state.droneStringIds
        strumStringIds = state.strumStringIds
        self.droneVoice = droneVoice
        self.droneSequence = droneSequence
    }

    /// Loading never replaces the scale or regenerates a saved bank when degree counts differ.
    public func state(tonicHz: Double, scaleRatios: [Double]) -> InstrumentState {
        InstrumentState(tonicHz: tonicHz, scaleRatios: scaleRatios, strings: strings,
                        droneStringIds: droneStringIds, strumStringIds: strumStringIds)
    }

    public func validate() throws {
        guard version == 1 else {
            throw Self.invalid("This Strings preset needs a newer app.")
        }
        let ids = Set(strings.map(\.id))
        guard ids.count == strings.count,
              strings.allSatisfy({ $0.degree >= 0 && (-2...2).contains($0.octave)
                  && $0.gain.isFinite && $0.gain >= 0 && $0.t60.isFinite && $0.t60 > 0 }),
              droneStringIds.count == InstrumentState.droneSlotCount,
              droneStringIds.compactMap({ $0 }).allSatisfy({ ids.contains($0) }),
              strumStringIds.allSatisfy({ ids.contains($0) }),
              Set(strumStringIds).count == strumStringIds.count,
              ["tanpura", "sympathetic"].contains(droneVoice),
              !droneSequence.isEmpty,
              droneSequence.allSatisfy({ (0..<InstrumentState.droneSlotCount).contains($0) }) else {
            throw Self.invalid("Invalid Strings preset.")
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> StringsPreset {
        let preset = try JSONDecoder().decode(Self.self, from: data)
        try preset.validate()
        return preset
    }

    /// The captured playing setup shipped with the app, independent of the DSP seed fixtures.
    public static let bundledDefault: StringsPreset = {
        guard let url = Bundle.module.url(forResource: "DefaultStrings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let preset = try? decode(data) else {
            preconditionFailure("Missing or invalid bundled Strings preset")
        }
        return preset
    }()

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "StringsPreset", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Named Strings setups, with an overridable Default and atomic replacement.
public struct StringsPresetLibrary {
    public static let defaultName = "Default"
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func standard() -> Self {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return Self(directory: base.appendingPathComponent("Tarabdaar", isDirectory: true)
            .appendingPathComponent("StringsPresets", isDirectory: true))
    }

    public func names() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent } + [Self.defaultName])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @discardableResult
    public func save(_ preset: StringsPreset, name: String) throws -> String {
        let clean = try PresetLibrary.sanitized(name)
        let data = try preset.encoded()
        _ = try StringsPreset.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: clean), options: .atomic)
        return clean
    }

    public func load(name: String) throws -> StringsPreset {
        let clean = try PresetLibrary.sanitized(name)
        let url = url(for: clean)
        if clean == Self.defaultName && !FileManager.default.fileExists(atPath: url.path) {
            return .bundledDefault
        }
        return try StringsPreset.decode(Data(contentsOf: url))
    }

    public func delete(name: String) throws {
        try FileManager.default.removeItem(at: url(for: PresetLibrary.sanitized(name)))
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}
