import XCTest
@testable import AudioLevelBarCore

final class PublisherOutputRetryTests: XCTestCase {
    private let speakers: UInt32 = 60
    private let usb: UInt32 = 80
    private let builtInInfo = AudioDeviceTransportInfo(transport: .builtIn)
    private let usbInfo = AudioDeviceTransportInfo(transport: .usb)

    private func survey(
        listing listed: [UInt32]? = nil,
        default defaultOutputID: UInt32,
        _ defaultOutput: AudioDeviceTransportInfo?
    ) -> PublisherOutputSurvey {
        let devices = (listed ?? [speakers, usb]).map { deviceID in
            ListedOutputDevice(
                deviceID: deviceID,
                transport: deviceID == speakers ? .builtIn : .usb,
                hasOutputChannels: true
            )
        }
        return PublisherOutputSurvey(listed: devices, defaultOutputID: defaultOutputID, defaultOutput: defaultOutput)
    }

    /// Ends the retries on `deviceID` with the poll showing `polled`.
    private func exhausted(on deviceID: UInt32, polled: PublisherOutputSurvey) -> PublisherOutputRetry {
        var retry = PublisherOutputRetry()
        for attempt in 0..<PublisherOutputRetry.maximumConsecutiveFailures {
            retry.outputUnavailable(deviceID: deviceID, at: TimeInterval(attempt * 10), survey: polled)
        }
        return retry
    }

    func testRetriesOnOneOutputAreSpacedAndThenEnd() {
        var retry = PublisherOutputRetry()
        let polled = survey(default: speakers, builtInInfo)
        XCTAssertEqual(retry.gate(at: 0), .open)

        XCTAssertFalse(retry.outputUnavailable(deviceID: speakers, at: 10, survey: polled))
        XCTAssertEqual(retry.retryNotBefore, 12)
        XCTAssertEqual(retry.gate(at: 11.9), .spaced)
        XCTAssertEqual(retry.gate(at: 12), .open)

        XCTAssertFalse(retry.outputUnavailable(deviceID: speakers, at: 20, survey: polled))
        XCTAssertEqual(retry.retryNotBefore, 24)
        XCTAssertFalse(retry.outputUnavailable(deviceID: speakers, at: 30, survey: polled))
        XCTAssertEqual(retry.retryNotBefore, 38)
        XCTAssertEqual(retry.consecutiveFailures, 3)

        XCTAssertTrue(
            retry.outputUnavailable(deviceID: speakers, at: 40, survey: polled),
            "the maximum read in a row ends the retries"
        )
        XCTAssertEqual(PublisherOutputRetry.maximumConsecutiveFailures, 4)
        XCTAssertTrue(retry.isExhausted)
        XCTAssertNil(retry.retryNotBefore)
        XCTAssertEqual(retry.gate(at: 40), .exhausted)
        XCTAssertEqual(retry.gate(at: 10_000), .exhausted, "however long it waits")
        XCTAssertFalse(retry.outputUnavailable(deviceID: speakers, at: 50, survey: polled), "they end once")
    }

    func testAnotherOutputStartsTheCountOver() {
        var retry = PublisherOutputRetry()
        let polled = survey(default: speakers, builtInInfo)
        for attempt in 0..<(PublisherOutputRetry.maximumConsecutiveFailures - 1) {
            retry.outputUnavailable(deviceID: speakers, at: TimeInterval(attempt), survey: polled)
        }

        XCTAssertFalse(retry.outputUnavailable(deviceID: usb, at: 100, survey: polled))
        XCTAssertEqual(retry.outputDeviceID, usb)
        XCTAssertEqual(retry.consecutiveFailures, 1)
        XCTAssertEqual(retry.retryNotBefore, 102)
    }

    func testStartingOverForgetsTheCountAndTheSpacing() {
        var retry = exhausted(on: speakers, polled: survey(default: speakers, builtInInfo))
        retry.startOver()
        XCTAssertEqual(retry, PublisherOutputRetry())
        XCTAssertEqual(retry.gate(at: 0), .open)
    }

    func testRetriesThatEndedStandUntilTheDefaultOrTheChosenOutputChanges() {
        let polled = survey(default: usb, usbInfo)
        let retry = exhausted(on: speakers, polled: polled)

        XCTAssertTrue(retry.exhaustionStands(for: polled))
        XCTAssertTrue(retry.exhaustionStands(for: survey(default: usb, usbInfo)), "an identical poll")
        XCTAssertFalse(
            retry.exhaustionStands(for: survey(default: speakers, builtInInfo)),
            "another default output, although the publisher would still be bound to the same built-in output"
        )
        XCTAssertFalse(
            retry.exhaustionStands(for: survey(default: usb, AudioDeviceTransportInfo(transport: .thunderbolt))),
            "the same default output with another transport"
        )
        XCTAssertFalse(
            retry.exhaustionStands(for: survey(listing: [usb], default: usb, usbInfo)),
            "the same default output, but the publisher would be bound to another output"
        )
        XCTAssertFalse(PublisherOutputRetry().exhaustionStands(for: polled), "nothing ended")
    }
}
