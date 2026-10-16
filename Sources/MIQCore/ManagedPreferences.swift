import Foundation

// MARK: - Managed (MDM) preferences
//
// An administrator can push a configuration profile that *forces* a preference
// (`com.apple.ManagedClient.preferences`, or an MDM's "Custom Settings"
// payload). macOS then reports the key as forced (`objectIsForced(forKey:)`)
// and returns the managed value from `object(forKey:)` ahead of whatever the
// user stored. The rules MIQ layers on top of that live here, as a pure
// function over abstract stores, so they are unit-tested without a real
// `UserDefaults` or profile:
//
//   1. A forced value of the expected type wins, from the first source (in
//      order) that forces the key. The setting is then *managed*: Settings shows
//      its control disabled with "Managed by your organisation".
//   2. A forced value of the wrong type (a profile typo — `<string>` where a
//      Bool is expected) is not trusted: the built-in default applies. The key
//      still counts as managed, because the managed layer shadows the user's
//      own value in that store — a user write could never take effect, so the
//      control must not pretend otherwise.
//   3. Otherwise the first source's own value of the expected type (the user's
//      choice in the primary store), else the built-in default. Later sources
//      only ever contribute forced values.
//
// Integer ↔ Double: profiles commonly carry `<integer>2</integer>` for a
// percentile; `Double` settings accept an integer value (both forced and
// stored). No other coercion is attempted.

/// A preference store as `ManagedPreferences` sees it. `UserDefaults`
/// conforms with its own methods; tests use an in-memory stand-in.
public protocol PreferenceSource {
    func object(forKey defaultName: String) -> Any?
    func objectIsForced(forKey key: String) -> Bool
}

extension UserDefaults: PreferenceSource {}

/// A resolved setting and whether an administrator fixed it.
public struct ResolvedPreference<Value> {
    public let value: Value
    /// `true` when the value came from a forced (managed) preference.
    public let isManaged: Bool

    public init(value: Value, isManaged: Bool) {
        self.value = value
        self.isManaged = isManaged
    }
}

public enum ManagedPreferences {
    /// Resolves `key` across `sources` (primary store first) — see the rules at
    /// the top of this file.
    public static func resolve<Value>(
        _ key: String,
        in sources: [any PreferenceSource],
        default fallback: Value
    ) -> ResolvedPreference<Value> {
        if let forcing = sources.first(where: { $0.objectIsForced(forKey: key) }) {
            let value: Value = coerce(forcing.object(forKey: key)) ?? fallback
            return ResolvedPreference(value: value, isManaged: true)
        }
        if let primary = sources.first, let value: Value = coerce(primary.object(forKey: key)) {
            return ResolvedPreference(value: value, isManaged: false)
        }
        return ResolvedPreference(value: fallback, isManaged: false)
    }

    /// Whether any source forces `key` — i.e. whether `resolve` reports it as
    /// managed and Settings should lock its control.
    public static func isManaged(_ key: String, in sources: [any PreferenceSource]) -> Bool {
        sources.contains { $0.objectIsForced(forKey: key) }
    }

    /// `raw` as `Value`, accepting an integer for a `Double` setting. A Swift
    /// `Bool` is never read as a number (or vice versa) here: on Darwin,
    /// `NSNumber` bridging already makes `<true/>`/`<integer>1</integer>`
    /// interchangeable for `as? Bool`, and that is left as Foundation does it.
    static func coerce<Value>(_ raw: Any?) -> Value? {
        guard let raw else { return nil }
        if let value = raw as? Value { return value }
        if Value.self == Double.self, !(raw is Bool), let integer = raw as? Int {
            return Double(integer) as? Value
        }
        return nil
    }
}
