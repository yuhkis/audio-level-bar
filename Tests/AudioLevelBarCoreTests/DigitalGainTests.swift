import XCTest
@testable import AudioLevelBarCore

final class DigitalGainTests: XCTestCase {
    func testZeroDecibelsIsUnityGain() {
        XCTAssertEqual(DigitalGain.amplitude(decibels: 0), 1, accuracy: 0.0001)
    }

    func testPositiveAndNegativeSixDecibelsAreReciprocal() {
        let positive = DigitalGain.amplitude(decibels: 6)
        let negative = DigitalGain.amplitude(decibels: -6)

        XCTAssertEqual(positive * negative, 1, accuracy: 0.0001)
    }

    func testNonFiniteAndOutOfRangeValuesAreSanitized() {
        XCTAssertEqual(DigitalGain.clampedDecibels(.nan), 0)
        XCTAssertEqual(DigitalGain.clampedDecibels(-30), -12)
        XCTAssertEqual(DigitalGain.clampedDecibels(30), 12)
    }
}
