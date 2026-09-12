import Foundation

public enum SettingsDomainMigration {
    public struct Source {
        public let values: [String: Any]
        public let markerKey: String

        public init(values: [String: Any], markerKey: String) {
            self.values = values
            self.markerKey = markerKey
        }
    }

    /// Copies values from an earlier defaults domain without overwriting
    /// settings that the current app identity has already saved.
    ///
    /// The shipped app migrates no defaults domain and does not call this; it
    /// is kept, with its tests, for a future change of bundle identifier.
    @discardableResult
    public static func copyMissingValuesOnce(
        _ legacyValues: [String: Any],
        to defaults: UserDefaults,
        markerKey: String
    ) -> Bool {
        guard
            !defaults.bool(forKey: markerKey),
            !legacyValues.isEmpty
        else {
            return false
        }

        for (key, value) in legacyValues where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: markerKey)
        return true
    }

    /// Applies earlier defaults domains in priority order. Existing target
    /// values always win, followed by the first source that supplies a key.
    ///
    /// Kept for the same reason as `copyMissingValuesOnce(_:to:markerKey:)`.
    @discardableResult
    public static func copyMissingValuesInPriorityOrder(
        _ sources: [Source],
        to defaults: UserDefaults
    ) -> Int {
        let markerKeys = Set(sources.map(\.markerKey))
        return sources.reduce(into: 0) { migrationCount, source in
            let values = source.values.filter { key, _ in
                !markerKeys.contains(key)
            }
            if copyMissingValuesOnce(
                values,
                to: defaults,
                markerKey: source.markerKey
            ) {
                migrationCount += 1
            }
        }
    }

    /// Copies the first available legacy value to a renamed target key.
    @discardableResult
    public static func copyFirstAvailableValue(
        from sourceKeys: [String],
        to targetKey: String,
        in defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: targetKey) == nil else {
            return false
        }

        for sourceKey in sourceKeys {
            if let value = defaults.object(forKey: sourceKey) {
                defaults.set(value, forKey: targetKey)
                return true
            }
        }
        return false
    }
}
