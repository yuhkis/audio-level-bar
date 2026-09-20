import XCTest
@testable import AudioLevelBarCore

final class ProcessedMicrophoneEngineStalenessTests: XCTestCase {
    private let speakers: UInt32 = 10
    private let headset: UInt32 = 20
    private let multiOutput: UInt32 = 30

    private func survey(
        _ listed: [ListedOutputDevice],
        default defaultID: UInt32,
        _ info: AudioDeviceTransportInfo?
    ) -> PublisherOutputSurvey {
        PublisherOutputSurvey(listed: listed, defaultOutputID: defaultID, defaultOutput: info)
    }

    private func isStale(
        running: Bool = true,
        needsRestart: Bool = false,
        modeChanged: Bool = false,
        inputChanged: Bool = false,
        runsVoiceProcessing: Bool,
        outputChanged: Bool = false,
        bound: UInt32?,
        survey: PublisherOutputSurvey
    ) -> Bool {
        ProcessedMicrophoneEngineStaleness.isStale(
            running: running,
            needsRestart: needsRestart,
            modeChanged: modeChanged,
            inputChanged: inputChanged,
            runsVoiceProcessing: runsVoiceProcessing,
            outputChanged: outputChanged,
            boundPublisherOutputID: bound,
            survey: survey
        )
    }

    func testAPublisherOutputThatGainedBluetoothIsStaleInEveryMode() {
        let withHeadset = AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb, .bluetooth])
        let gained = survey(
            [ListedOutputDevice(deviceID: multiOutput, transport: .aggregate, hasOutputChannels: true)],
            default: multiOutput,
            withHeadset
        )
        let gone = survey(
            [ListedOutputDevice(deviceID: speakers, transport: .builtIn, hasOutputChannels: true)],
            default: speakers,
            AudioDeviceTransportInfo(transport: .builtIn)
        )
        for runsVoiceProcessing in [false, true] {
            XCTAssertTrue(isStale(runsVoiceProcessing: runsVoiceProcessing, bound: multiOutput, survey: gained))
            XCTAssertTrue(
                isStale(runsVoiceProcessing: runsVoiceProcessing, bound: multiOutput, survey: gone),
                "an output no longer listed"
            )
        }
    }

    func testTheDefaultOutputMovingRebuildsOnlyAppleVoiceProcessing() {
        let moved = survey(
            [
                ListedOutputDevice(deviceID: speakers, transport: .builtIn, hasOutputChannels: true),
                ListedOutputDevice(deviceID: headset, transport: .bluetooth, hasOutputChannels: true)
            ],
            default: headset,
            AudioDeviceTransportInfo(transport: .bluetooth)
        )
        XCTAssertFalse(
            isStale(runsVoiceProcessing: false, outputChanged: true, bound: speakers, survey: moved),
            "the muted tap captures the publisher wherever it renders"
        )
        XCTAssertTrue(isStale(runsVoiceProcessing: true, outputChanged: true, bound: speakers, survey: moved))
    }

    func testEnginesThatAreNotRunningAreNeverStale() {
        let empty = survey([], default: 0, nil)
        XCTAssertFalse(isStale(running: false, needsRestart: true, runsVoiceProcessing: true, bound: nil, survey: empty))
        XCTAssertTrue(isStale(needsRestart: true, runsVoiceProcessing: false, bound: nil, survey: empty))
        XCTAssertTrue(isStale(modeChanged: true, runsVoiceProcessing: false, bound: nil, survey: empty))
        XCTAssertTrue(isStale(inputChanged: true, runsVoiceProcessing: false, bound: nil, survey: empty))
    }
}
