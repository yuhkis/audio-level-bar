import XCTest
@testable import AudioLevelBarCore

final class MeterColorScaleTests: XCTestCase {
    func testLevelBelowGreenThresholdIsNeutral() {
        XCTAssertEqual(
            MeterColorScale.band(for: 0.39, greenThreshold: 0.4, redThreshold: 0.9),
            .neutral
        )
    }

    func testGreenThresholdIsInclusive() {
        XCTAssertEqual(
            MeterColorScale.band(for: 0.4, greenThreshold: 0.4, redThreshold: 0.9),
            .green
        )
    }

    func testRedThresholdIsInclusive() {
        XCTAssertEqual(
            MeterColorScale.band(for: 0.9, greenThreshold: 0.4, redThreshold: 0.9),
            .red
        )
    }

    func testLevelIsClampedBeforeColorSelection() {
        XCTAssertEqual(
            MeterColorScale.band(for: 2, greenThreshold: 0.4, redThreshold: 0.9),
            .red
        )
        XCTAssertEqual(
            MeterColorScale.band(for: -1, greenThreshold: 0.4, redThreshold: 0.9),
            .neutral
        )
    }

    func testChannelsUseDifferentDefaults() {
        XCTAssertEqual(
            MeterColorScale.defaultThresholds(for: .microphone),
            .microphoneDefault
        )
        XCTAssertEqual(
            MeterColorScale.defaultThresholds(for: .systemOutput),
            .systemOutputDefault
        )
        XCTAssertNotEqual(
            MeterColorThresholds.microphoneDefault.greenThreshold,
            MeterColorThresholds.systemOutputDefault.greenThreshold
        )
    }

    func testMicrophoneDefaultKeepsSpeechRecognitionRangeGreen() {
        let thresholds = MeterColorThresholds.microphoneDefault
        XCTAssertEqual(thresholds.band(for: normalized(decibels: -35)), .neutral)
        XCTAssertEqual(thresholds.band(for: normalized(decibels: -30)), .green)
        XCTAssertEqual(thresholds.band(for: normalized(decibels: -18)), .green)
        XCTAssertEqual(thresholds.band(for: normalized(decibels: -8)), .green)
        XCTAssertEqual(thresholds.band(for: normalized(decibels: -6)), .red)
    }

    func testSystemOutputDefaultTreatsAudiblePlaybackAsGreen() {
        let thresholds = MeterColorThresholds.systemOutputDefault
        XCTAssertEqual(thresholds.band(for: normalized(decibels: -50)), .neutral)
        XCTAssertEqual(thresholds.band(for: normalized(decibels: -45)), .green)
        XCTAssertEqual(thresholds.band(for: normalized(decibels: -14)), .green)
        XCTAssertEqual(thresholds.band(for: normalized(decibels: -6)), .red)
    }

    func testThresholdsKeepMinimumGap() {
        let thresholds = MeterColorThresholds(greenThreshold: 0.95, redThreshold: 0.9)
        XCTAssertEqual(thresholds.redThreshold, 0.9)
        XCTAssertEqual(
            thresholds.greenThreshold,
            0.9 - MeterColorScale.minimumThresholdGap,
            accuracy: 0.0001
        )
    }

    func testThresholdsAreClampedToUnitRange() {
        let low = MeterColorThresholds(greenThreshold: -1, redThreshold: -1)
        XCTAssertEqual(low.greenThreshold, 0)
        XCTAssertEqual(low.redThreshold, MeterColorScale.minimumThresholdGap)

        let high = MeterColorThresholds(greenThreshold: 2, redThreshold: 2)
        XCTAssertEqual(high.redThreshold, 1)
        XCTAssertEqual(
            high.greenThreshold,
            1 - MeterColorScale.minimumThresholdGap,
            accuracy: 0.0001
        )
    }

    func testLoweringRedThresholdPushesItAboveGreen() {
        let thresholds = MeterColorThresholds(greenThreshold: 0.5, redThreshold: 0.9)
            .settingRedThreshold(0.2)
        XCTAssertEqual(thresholds.greenThreshold, 0.5)
        XCTAssertEqual(
            thresholds.redThreshold,
            0.5 + MeterColorScale.minimumThresholdGap,
            accuracy: 0.0001
        )
    }

    func testRaisingGreenThresholdStopsBelowRed() {
        let thresholds = MeterColorThresholds(greenThreshold: 0.5, redThreshold: 0.9)
            .settingGreenThreshold(0.99)
        XCTAssertEqual(thresholds.redThreshold, 0.9)
        XCTAssertEqual(
            thresholds.greenThreshold,
            0.9 - MeterColorScale.minimumThresholdGap,
            accuracy: 0.0001
        )
    }

    func testUntouchedSharedThresholdsMigrateToChannelDefaults() {
        XCTAssertEqual(
            MeterColorThresholdMigration.resolvedThresholds(
                legacyGreen: 0.4,
                legacyRed: 0.9,
                channelDefault: .microphoneDefault
            ),
            .microphoneDefault
        )
        XCTAssertEqual(
            MeterColorThresholdMigration.resolvedThresholds(
                legacyGreen: nil,
                legacyRed: nil,
                channelDefault: .systemOutputDefault
            ),
            .systemOutputDefault
        )
    }

    func testCustomizedSharedThresholdsCarryOverPerValue() {
        let thresholds = MeterColorThresholdMigration.resolvedThresholds(
            legacyGreen: 0.62,
            legacyRed: 0.9,
            channelDefault: .systemOutputDefault
        )
        XCTAssertEqual(thresholds.greenThreshold, 0.62, accuracy: 0.0001)
        XCTAssertEqual(
            thresholds.redThreshold,
            MeterColorThresholds.systemOutputDefault.redThreshold
        )
    }

    private func normalized(decibels: Float) -> Float {
        MeterScale.normalized(decibels: decibels)
    }
}
