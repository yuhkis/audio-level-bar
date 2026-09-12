import AudioLevelBarCore
import Foundation
import XCTest

final class SettingsDomainMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsDomainMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testCopiesMissingValuesWithoutOverwritingCurrentSettings() {
        defaults.set("current", forKey: "shared")

        let migrated = SettingsDomainMigration.copyMissingValuesOnce(
            ["shared": "legacy", "legacyOnly": 42],
            to: defaults,
            markerKey: "migrationComplete"
        )

        XCTAssertTrue(migrated)
        XCTAssertEqual(defaults.string(forKey: "shared"), "current")
        XCTAssertEqual(defaults.integer(forKey: "legacyOnly"), 42)
        XCTAssertTrue(defaults.bool(forKey: "migrationComplete"))
    }

    func testMigrationRunsOnlyOnce() {
        XCTAssertTrue(
            SettingsDomainMigration.copyMissingValuesOnce(
                ["value": "first"],
                to: defaults,
                markerKey: "migrationComplete"
            )
        )

        defaults.removeObject(forKey: "value")
        XCTAssertFalse(
            SettingsDomainMigration.copyMissingValuesOnce(
                ["value": "second"],
                to: defaults,
                markerKey: "migrationComplete"
            )
        )
        XCTAssertNil(defaults.object(forKey: "value"))
    }

    func testEmptyLegacyDomainDoesNotConsumeMigration() {
        XCTAssertFalse(
            SettingsDomainMigration.copyMissingValuesOnce(
                [:],
                to: defaults,
                markerKey: "migrationComplete"
            )
        )
        XCTAssertFalse(defaults.bool(forKey: "migrationComplete"))
    }

    func testPriorityOrderPreservesTargetThenUsesNewestLegacySource() {
        defaults.set("target", forKey: "targetWins")

        let count = SettingsDomainMigration.copyMissingValuesInPriorityOrder(
            [
                .init(
                    values: [
                        "targetWins": "newest",
                        "sourcePriority": "newest",
                    ],
                    markerKey: "migrated.newest"
                ),
                .init(
                    values: [
                        "sourcePriority": "oldest",
                        "oldestOnly": "oldest",
                    ],
                    markerKey: "migrated.oldest"
                ),
            ],
            to: defaults
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(defaults.string(forKey: "targetWins"), "target")
        XCTAssertEqual(defaults.string(forKey: "sourcePriority"), "newest")
        XCTAssertEqual(defaults.string(forKey: "oldestOnly"), "oldest")
    }

    func testCopiedOldMarkerDoesNotBlockDistinctNewMigrationMarker() {
        let count = SettingsDomainMigration.copyMissingValuesInPriorityOrder(
            [
                .init(
                    values: [
                        "didMigrateDefaultsFromLegacyBundleIdentifier": true,
                        "value": "currentLegacy",
                    ],
                    markerKey: "didMigrateDefaultsFrom.currentLegacy"
                ),
            ],
            to: defaults
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(defaults.string(forKey: "value"), "currentLegacy")
        XCTAssertTrue(defaults.bool(forKey: "didMigrateDefaultsFrom.currentLegacy"))
    }

    func testHigherPrioritySourceCannotPreemptLowerPriorityMarker() {
        let count = SettingsDomainMigration.copyMissingValuesInPriorityOrder(
            [
                .init(
                    values: [
                        "migration.oldest": true,
                        "newestOnly": "newest",
                    ],
                    markerKey: "migration.newest"
                ),
                .init(
                    values: ["oldestOnly": "oldest"],
                    markerKey: "migration.oldest"
                ),
            ],
            to: defaults
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(defaults.string(forKey: "newestOnly"), "newest")
        XCTAssertEqual(defaults.string(forKey: "oldestOnly"), "oldest")
        XCTAssertTrue(defaults.bool(forKey: "migration.oldest"))
    }

    func testFallsBackToOldestSourceWhenNewestDomainIsEmpty() {
        let count = SettingsDomainMigration.copyMissingValuesInPriorityOrder(
            [
                .init(values: [:], markerKey: "migration.newest"),
                .init(
                    values: ["value": "oldest"],
                    markerKey: "migration.oldest"
                ),
            ],
            to: defaults
        )

        XCTAssertEqual(count, 1)
        XCTAssertFalse(defaults.bool(forKey: "migration.newest"))
        XCTAssertEqual(defaults.string(forKey: "value"), "oldest")
        XCTAssertTrue(defaults.bool(forKey: "migration.oldest"))
    }

    func testCopiesFirstAvailableRenamedValueWithoutOverwritingTarget() {
        defaults.set(282, forKey: "legacy.current")
        defaults.set(100, forKey: "legacy.oldest")

        XCTAssertTrue(
            SettingsDomainMigration.copyFirstAvailableValue(
                from: ["legacy.current", "legacy.oldest"],
                to: "target",
                in: defaults
            )
        )
        XCTAssertEqual(defaults.integer(forKey: "target"), 282)

        defaults.set(450, forKey: "legacy.current")
        XCTAssertFalse(
            SettingsDomainMigration.copyFirstAvailableValue(
                from: ["legacy.current", "legacy.oldest"],
                to: "target",
                in: defaults
            )
        )
        XCTAssertEqual(defaults.integer(forKey: "target"), 282)
    }

    func testStatusItemPositionFallsBackToOldestGenericAppKitKey() {
        let genericKey = "NSStatusItem Preferred Position Item-0"
        let targetKey = "NSStatusItem Preferred Position io.github.yuhkis.audio-level-bar.status-item"
        defaults.set(201, forKey: genericKey)

        XCTAssertTrue(
            SettingsDomainMigration.copyFirstAvailableValue(
                from: [
                    "NSStatusItem Preferred Position com.example.app.status-item",
                    "NSStatusItem Preferred Position com.example.legacy.status-item",
                    genericKey,
                ],
                to: targetKey,
                in: defaults
            )
        )
        XCTAssertEqual(defaults.integer(forKey: targetKey), 201)
    }
}
