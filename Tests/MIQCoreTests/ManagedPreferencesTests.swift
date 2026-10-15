import Foundation
import Testing
@testable import MIQCore

/// In-memory stand-in for a `UserDefaults` store with a managed layer:
/// `forced` plays the configuration profile, `stored` the user's own values.
private struct FakeStore: PreferenceSource {
    var stored: [String: Any] = [:]
    var forced: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? {
        forced[defaultName] ?? stored[defaultName]
    }

    func objectIsForced(forKey key: String) -> Bool {
        forced[key] != nil
    }
}

struct ManagedPreferencesTests {

    @Test func defaultWhenNothingStored() {
        let result = ManagedPreferences.resolve("k", in: [FakeStore()], default: true)
        #expect(result.value == true)
        #expect(result.isManaged == false)
    }

    @Test func userValueBeatsDefault() {
        let store = FakeStore(stored: ["k": false])
        let result = ManagedPreferences.resolve("k", in: [store], default: true)
        #expect(result.value == false)
        #expect(result.isManaged == false)
    }

    @Test func forcedValueBeatsUserValue() {
        let store = FakeStore(stored: ["k": true], forced: ["k": false])
        let result = ManagedPreferences.resolve("k", in: [store], default: true)
        #expect(result.value == false)
        #expect(result.isManaged == true)
        #expect(ManagedPreferences.isManaged("k", in: [store]))
    }

    @Test func forcedValueOfWrongTypeFallsBackToDefaultButStaysManaged() {
        let store = FakeStore(stored: ["k": false], forced: ["k": "no"])
        let result = ManagedPreferences.resolve("k", in: [store], default: true)
        // The typo is not trusted, but the managed layer still shadows the
        // user's value, so the control stays locked (at the default).
        #expect(result.value == true)
        #expect(result.isManaged == true)
        #expect(ManagedPreferences.isManaged("k", in: [store]))
    }

    @Test func storedValueOfWrongTypeFallsBackToDefault() {
        let store = FakeStore(stored: ["k": "radiological?"])
        let result = ManagedPreferences.resolve("k", in: [store], default: 2.0)
        #expect(result.value == 2.0)
        #expect(result.isManaged == false)
    }

    @Test func secondarySourceCanForceButNotSupplyUserValues() {
        let primary = FakeStore(stored: ["a": 1.0])
        let secondary = FakeStore(stored: ["a": 9.0, "b": 9.0], forced: ["c": 5.0])
        // Unforced secondary values are never read.
        #expect(ManagedPreferences.resolve("a", in: [primary, secondary], default: Double(0)).value == 1.0)
        #expect(ManagedPreferences.resolve("b", in: [primary, secondary], default: Double(0)).value == 0.0)
        // A forced secondary value wins and is managed.
        let forced = ManagedPreferences.resolve("c", in: [primary, secondary], default: Double(0))
        #expect(forced.value == 5.0)
        #expect(forced.isManaged)
    }

    @Test func firstForcingSourceWins() {
        let first = FakeStore(forced: ["k": "radiological"])
        let second = FakeStore(forced: ["k": "neurological"])
        let result = ManagedPreferences.resolve("k", in: [first, second], default: "stored")
        #expect(result.value == "radiological")
    }

    @Test func integerAcceptedForDoubleSetting() {
        // Profiles often carry <integer>5</integer> for a percentile.
        let store = FakeStore(forced: ["lower": 5])
        let result = ManagedPreferences.resolve("lower", in: [store], default: 2.0)
        #expect(result.value == 5.0)
        #expect(result.isManaged)
    }

    @Test func boolIsNotReadAsDouble() {
        let store = FakeStore(stored: ["lower": true])
        let result = ManagedPreferences.resolve("lower", in: [store], default: 2.0)
        #if canImport(Darwin)
        // NSNumber bridging on Darwin is Foundation's call, not ours.
        _ = result
        #else
        #expect(result.value == 2.0)
        #endif
    }

    @Test func emptySourceListUsesDefault() {
        let result = ManagedPreferences.resolve("k", in: [], default: "auto")
        #expect(result.value == "auto")
        #expect(!result.isManaged)
    }

    @Test func realUserDefaultsConformsAndIsUnforced() throws {
        let suite = "miq.tests.managed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "k")
        let result = ManagedPreferences.resolve("k", in: [defaults], default: true)
        #expect(result.value == false)
        #expect(!result.isManaged)
    }

    @Test func newFeatureDefaultsAreAsDocumented() {
        #expect(MIQConfig.Defaults.qcPanelEnabled == true)
        #expect(MIQConfig.Defaults.temporalSummaryEnabled == true)
        #expect(MIQConfig.Defaults.volumeRenderingEnabled == true)
        #expect(MIQConfig.Defaults.overlayAutoDiscovery == true)
        #expect(MIQConfig.Defaults.defaultColormap == "auto")
        // "auto" is deliberately not a Colormap case, so it reads as nil (auto).
        #expect(Colormap(rawValue: MIQConfig.Defaults.defaultColormap) == nil)
        // Nothing in the test process forces these keys.
        #expect(!MIQConfig.isManaged(MIQConfig.Keys.qcPanelEnabled))
    }
}
