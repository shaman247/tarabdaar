import Foundation

/// The one UserDefaults-as-JSON idiom: every persisted document (tarab
/// state, overrides, resting values, composites, curves, calibrations,
/// bindings) loads and saves through here, so the coder is configured in
/// one place. A missing or undecodable record reads as nil.
public enum DefaultsStore {
    public static func load<T: Decodable>(_ type: T.Type, key: String,
                                          from defaults: UserDefaults = .standard) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public static func save<T: Encodable>(_ value: T, key: String,
                                          to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
