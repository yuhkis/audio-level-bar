import XCTest
@testable import AudioLevelBarCore

final class VoiceProcessingDeviceCheckTests: XCTestCase {
    private let builtIn = AudioDeviceTransportInfo(transport: .builtIn)
    private let usb = AudioDeviceTransportInfo(transport: .usb)
    private let headset = AudioDeviceTransportInfo(transport: .bluetooth)

    /// The start was decided for input 10 and output 20.
    private func check(
        input: UInt32 = 10,
        output: UInt32 = 20,
        inputInfo: AudioDeviceTransportInfo?,
        outputInfo: AudioDeviceTransportInfo?,
        bluetoothPresent: Bool? = false
    ) -> VoiceProcessingDeviceCheck {
        ProcessedMicrophoneSourcePolicy.checkVoiceProcessingDevices(
            decidedInputDeviceID: 10,
            decidedOutputDeviceID: 20,
            inputDeviceID: input,
            outputDeviceID: output,
            input: inputInfo,
            output: outputInfo,
            bluetoothDevicePresent: bluetoothPresent
        )
    }

    func testABluetoothDeviceTheFreshReadListsStopsTheStart() {
        XCTAssertEqual(
            check(inputInfo: builtIn, outputInfo: usb, bluetoothPresent: true),
            .refused(.bluetoothDevicePresentForVoiceProcessing)
        )
        XCTAssertEqual(
            check(inputInfo: builtIn, outputInfo: usb, bluetoothPresent: nil),
            .refused(.transportNotRead),
            "a list that could not be read cannot rule one out"
        )
        XCTAssertEqual(
            check(output: 30, inputInfo: builtIn, outputInfo: headset, bluetoothPresent: true),
            .outputMoved,
            "a default that moved is still reported first"
        )
    }

    // MARK: The defaults read around the engine start

    private func defaults(input: UInt32, output: UInt32) -> VoiceProcessingDeviceCheck {
        VoiceProcessingDeviceCheck.defaults(
            decidedInputDeviceID: 10,
            decidedOutputDeviceID: 20,
            inputDeviceID: input,
            outputDeviceID: output
        )
    }

    func testDefaultsReadAroundTheStartReportOnlyAMove() {
        XCTAssertEqual(defaults(input: 10, output: 20), .unchanged)
        XCTAssertEqual(defaults(input: 11, output: 20), .inputMoved)
        XCTAssertEqual(defaults(input: 10, output: 21), .outputMoved)
        XCTAssertEqual(defaults(input: 11, output: 21), .inputMoved, "the input is reported first")
    }

    func testADefaultThatCouldNotBeReadAroundTheStartCountsAsMoved() {
        XCTAssertEqual(defaults(input: 0, output: 20), .inputMoved)
        XCTAssertEqual(defaults(input: 10, output: 0), .outputMoved)
        XCTAssertEqual(
            VoiceProcessingDeviceCheck.defaults(
                decidedInputDeviceID: 0,
                decidedOutputDeviceID: 0,
                inputDeviceID: 0,
                outputDeviceID: 0
            ),
            .inputMoved,
            "an unread default never matches"
        )
    }

    // MARK: The read before the start

    func testSameWiredDevicesStart() {
        let result = check(inputInfo: builtIn, outputInfo: usb)
        XCTAssertEqual(result, .unchanged)
        XCTAssertFalse(result.concernsOutput)
    }

    func testInputThatMovedStopsTheStartEvenWhenWired() {
        let result = check(input: 11, inputInfo: usb, outputInfo: builtIn)
        XCTAssertEqual(result, .inputMoved)
        XCTAssertFalse(result.concernsOutput)
    }

    func testHeadsetThatJustBecameTheDefaultOutputStopsTheStart() {
        let result = check(output: 30, inputInfo: builtIn, outputInfo: headset)
        XCTAssertEqual(result, .outputMoved)
        XCTAssertTrue(result.concernsOutput)
    }

    func testMovedInputIsReportedBeforeAMovedOutput() {
        XCTAssertEqual(check(input: 31, output: 30, inputInfo: headset, outputInfo: headset), .inputMoved)
    }

    func testSameIDsNowInvolvingBluetoothAreRefused() {
        let aggregateWithHeadset = AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: [.builtIn, .bluetooth]
        )

        XCTAssertEqual(
            check(inputInfo: aggregateWithHeadset, outputInfo: builtIn),
            .refused(.bluetoothInput)
        )
        let output = check(inputInfo: builtIn, outputInfo: aggregateWithHeadset)
        XCTAssertEqual(output, .refused(.bluetoothOutputForVoiceProcessing))
        XCTAssertTrue(output.concernsOutput)
    }

    func testUnreadFreshTransportIsRefused() {
        XCTAssertEqual(check(inputInfo: nil, outputInfo: builtIn), .refused(.transportNotRead))
        XCTAssertEqual(check(inputInfo: builtIn, outputInfo: nil), .refused(.transportNotRead))
    }

    func testNoDefaultInputIsRefused() {
        XCTAssertEqual(
            ProcessedMicrophoneSourcePolicy.checkVoiceProcessingDevices(
                decidedInputDeviceID: 0,
                decidedOutputDeviceID: 20,
                inputDeviceID: 0,
                outputDeviceID: 20,
                input: nil,
                output: builtIn,
                bluetoothDevicePresent: false
            ),
            .refused(.noInput)
        )
    }
}
