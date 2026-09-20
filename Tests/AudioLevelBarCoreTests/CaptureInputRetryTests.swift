import XCTest
@testable import AudioLevelBarCore

final class CaptureInputRetryTests: XCTestCase {
    private let builtIn: UInt32 = 41
    private let usb: UInt32 = 42
    private let maximum = CaptureInputRetry.maximumConsecutiveFailures

    func testFailedReadsOnOneInputAreSpacedAndThenEnd() {
        var retry = CaptureInputRetry()
        XCTAssertFalse(retry.holdsStarts(on: builtIn, at: 0))

        XCTAssertFalse(retry.readFailed(deviceID: builtIn, at: 10))
        XCTAssertEqual(retry.retryNotBefore, 12)
        XCTAssertTrue(retry.holdsStarts(on: builtIn, at: 11.9))
        XCTAssertFalse(retry.holdsStarts(on: builtIn, at: 12))

        XCTAssertFalse(retry.readFailed(deviceID: builtIn, at: 20))
        XCTAssertEqual(retry.retryNotBefore, 24)
        XCTAssertFalse(retry.readFailed(deviceID: builtIn, at: 30))
        XCTAssertEqual(retry.retryNotBefore, 38)
        XCTAssertFalse(retry.readFailed(deviceID: builtIn, at: 40))
        XCTAssertEqual(retry.retryNotBefore, 48, "8 s from the third on")

        for attempt in 5..<maximum {
            XCTAssertFalse(retry.readFailed(deviceID: builtIn, at: TimeInterval(attempt * 10)))
        }
        XCTAssertFalse(retry.isExhausted)
        XCTAssertTrue(
            retry.readFailed(deviceID: builtIn, at: TimeInterval(maximum * 10)),
            "the maximum failed read in a row ends the retries"
        )
        XCTAssertTrue(retry.isExhausted)
        XCTAssertEqual(retry.consecutiveFailures, maximum)
        XCTAssertNil(retry.retryNotBefore)
        XCTAssertFalse(retry.readFailed(deviceID: builtIn, at: 1_000), "they end once")
    }

    func testTheSpacingAndTheCapAreTheMicrophoneMetersForTheSameOpenTimeResult() {
        XCTAssertEqual(maximum, MeterSession.maximumStartAttempts)
        var retry = CaptureInputRetry()
        var session = MeterSession()
        var now: TimeInterval = 100
        for attempt in 1...maximum {
            XCTAssertEqual(
                session.handle(.evaluate(target: .device(builtIn), holding: false, startsHeld: false, now: now)),
                .start(builtIn)
            )
            XCTAssertNil(session.handle(.refusedAtStart(builtIn, .aggregateWithUnresolvedMember, now: now)))
            let ended = retry.readFailed(deviceID: builtIn, at: now)
            guard case let .failed(_, attempts, retryAt) = session.phase else {
                return XCTFail("\(session.phase)")
            }
            XCTAssertEqual(attempts, attempt)
            XCTAssertEqual(ended, session.retriesExhausted, "attempt \(attempt)")
            if !ended {
                XCTAssertEqual(retry.retryNotBefore, retryAt, "attempt \(attempt)")
            }
            now += MeterSession.maximumRetryDelay
        }
        XCTAssertTrue(retry.isExhausted)
    }

    func testAnotherInputStartsTheCountOverAndDoesNotWaitForTheSpacing() {
        var retry = CaptureInputRetry()
        retry.readFailed(deviceID: builtIn, at: 10)
        retry.readFailed(deviceID: builtIn, at: 20)
        XCTAssertTrue(retry.holdsStarts(on: builtIn, at: 21))
        XCTAssertFalse(retry.holdsStarts(on: usb, at: 21), "the spacing belongs to the input whose read failed")

        XCTAssertFalse(retry.readFailed(deviceID: usb, at: 22))
        XCTAssertEqual(retry.inputDeviceID, usb)
        XCTAssertEqual(retry.consecutiveFailures, 1)
        XCTAssertEqual(retry.retryNotBefore, 24)
        XCTAssertFalse(retry.holdsStarts(on: builtIn, at: 23))
    }

    func testStartingOverSpendsTheCountAndTheSpacing() {
        var retry = CaptureInputRetry()
        for attempt in 0..<maximum {
            retry.readFailed(deviceID: builtIn, at: TimeInterval(attempt * 10))
        }
        XCTAssertTrue(retry.isExhausted)

        retry.startOver()

        XCTAssertEqual(retry, CaptureInputRetry())
        XCTAssertFalse(retry.readFailed(deviceID: builtIn, at: 500), "the next failed read counts from one again")
        XCTAssertEqual(retry.retryNotBefore, 502)
    }
}
