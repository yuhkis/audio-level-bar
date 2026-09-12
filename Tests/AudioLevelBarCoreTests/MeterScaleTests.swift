import XCTest
@testable import AudioLevelBarCore

final class MeterScaleTests: XCTestCase {
    func testFullScaleAmplitudeIsZeroDecibels() {
        XCTAssertEqual(MeterScale.decibels(amplitude: 1), 0, accuracy: 0.001)
    }

    func testTenthAmplitudeIsMinusTwentyDecibels() {
        XCTAssertEqual(MeterScale.decibels(amplitude: 0.1), -20, accuracy: 0.001)
    }

    func testSilenceUsesCalculationFloor() {
        XCTAssertEqual(
            MeterScale.decibels(amplitude: 0),
            MeterScale.calculationFloorDecibels
        )
    }

    func testDisplayScaleClampsAtBothEnds() {
        XCTAssertEqual(MeterScale.normalized(decibels: -90), 0)
        XCTAssertEqual(MeterScale.normalized(decibels: -30), 0.5, accuracy: 0.001)
        XCTAssertEqual(MeterScale.normalized(decibels: 3), 1)
    }

    func testMenuTextUsesStableSilenceValue() {
        XCTAssertEqual(MeterScale.menuText(decibels: -80), "-inf")
        XCTAssertEqual(MeterScale.menuText(decibels: -18.4), "-18")
    }
}
