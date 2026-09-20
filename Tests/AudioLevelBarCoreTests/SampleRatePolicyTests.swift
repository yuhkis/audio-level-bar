import XCTest
@testable import AudioLevelBarCore

final class SampleRatePolicyTests: XCTestCase {
    func testSampleRatePolicyRejectsZeroNaNInfinityAndOutOfRange() {
        for rate in [
            0,
            -1,
            -48_000,
            .nan,
            .infinity,
            -.infinity,
            7_999,
            768_001,
            4_294_967_296,
            1e12,
            .greatestFiniteMagnitude
        ] {
            XCTAssertFalse(SampleRatePolicy.isUsable(rate), "\(rate) must be rejected")
        }
    }

    func testBufferFramesNeverTrapsOnAnUnusableRateOrDuration() {
        for rate in [Double.infinity, .nan, 0, 1e12, 4_294_967_296] {
            XCTAssertNil(SampleRatePolicy.bufferFrames(sampleRate: rate, duration: 0.25, minimum: 8_192, maximum: 262_144), "\(rate)")
        }
        for duration in [0, -1, TimeInterval.nan, .infinity] {
            XCTAssertNil(SampleRatePolicy.bufferFrames(sampleRate: 48_000, duration: duration, minimum: 8_192, maximum: 262_144), "\(duration)")
        }
    }

    func testBufferFramesIsClampedToItsBounds() {
        XCTAssertEqual(SampleRatePolicy.bufferFrames(sampleRate: 48_000, duration: 0.1, minimum: 8_192, maximum: 262_144), 8_192)
        XCTAssertEqual(SampleRatePolicy.bufferFrames(sampleRate: 768_000, duration: 0.25, minimum: 8_192, maximum: 262_144), 192_000)
        XCTAssertEqual(SampleRatePolicy.bufferFrames(sampleRate: 768_000, duration: 10, minimum: 8_192, maximum: 262_144), 262_144)
    }

    func testWebRTCSampleRateOnlyConvertsUsableRates() {
        XCTAssertEqual(SampleRatePolicy.webRTCSampleRate(48_000), 48_000)
        XCTAssertNil(SampleRatePolicy.webRTCSampleRate(.infinity))
        XCTAssertNil(SampleRatePolicy.webRTCSampleRate(1e12))
        XCTAssertNil(SampleRatePolicy.webRTCSampleRate(.nan))
    }

    func testNonFiniteSamplesBecomeZero() {
        XCTAssertEqual(SampleSanitizer.finiteOrZero(.nan), 0)
        XCTAssertEqual(SampleSanitizer.finiteOrZero(.infinity), 0)
        XCTAssertEqual(SampleSanitizer.finiteOrZero(-.infinity), 0)
        XCTAssertEqual(SampleSanitizer.finiteOrZero(0.5), 0.5)
        XCTAssertEqual(SampleSanitizer.finiteOrZero(-1), -1)
    }

    func testSampleRatePolicyAcceptsCommonRates() {
        for rate in [8_000, 16_000, 22_050, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 384_000, 768_000.0] {
            XCTAssertTrue(SampleRatePolicy.isUsable(rate), "\(rate) must be accepted")
        }
    }
}
