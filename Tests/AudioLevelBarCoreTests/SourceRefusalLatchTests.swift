import XCTest
@testable import AudioLevelBarCore

final class SourceRefusalLatchTests: XCTestCase {
    private let builtIn: UInt32 = 41
    private let usb: UInt32 = 42
    private let speakers: UInt32 = 51
    private let headphones: UInt32 = 52
    private let wired = AudioDeviceTransportInfo(transport: .builtIn)
    private let usbInfo = AudioDeviceTransportInfo(transport: .usb)
    private let aggregateWithHeadset = AudioDeviceTransportInfo(
        transport: .aggregate,
        activeSubDeviceTransports: [.builtIn, .bluetooth]
    )

    private func stands(
        _ latch: SourceRefusalLatch,
        voiceProcessing: Bool = true,
        input: UInt32? = nil,
        inputInfo: AudioDeviceTransportInfo?? = nil,
        output: UInt32? = nil,
        outputInfo: AudioDeviceTransportInfo?? = nil
    ) -> Bool {
        latch.stands(
            usesVoiceProcessing: voiceProcessing,
            inputDeviceID: input ?? latch.inputDeviceID,
            input: inputInfo ?? latch.input,
            outputDeviceID: output ?? latch.outputDeviceID,
            output: outputInfo ?? latch.output
        )
    }

    func testCaptureRefusalStandsUntilTheInputOrItsTransportChanges() {
        let latch = SourceRefusalLatch.captureInput(deviceID: builtIn, polledInput: wired)
        XCTAssertEqual(latch.refusal, .bluetoothInput)

        XCTAssertTrue(stands(latch))
        XCTAssertTrue(stands(latch, voiceProcessing: false), "the input is refused for every mode")
        XCTAssertTrue(stands(latch, output: headphones), "the output does not matter to the capture")
        XCTAssertFalse(stands(latch, input: usb))
        XCTAssertFalse(stands(latch, inputInfo: .some(usbInfo)))
        XCTAssertFalse(stands(latch, inputInfo: .some(nil)))
    }

    func testPublisherOutputRefusalStandsUntilTheDefaultOutputOrItsTransportChanges() {
        let latch = SourceRefusalLatch.publisherOutput(outputDeviceID: speakers, polledOutput: aggregateWithHeadset)
        XCTAssertEqual(latch.refusal, .noNonBluetoothOutput)
        XCTAssertEqual(latch.scope, .publisherOutput)

        XCTAssertTrue(stands(latch))
        XCTAssertTrue(stands(latch, voiceProcessing: false), "the publisher is bound in every mode")
        XCTAssertTrue(stands(latch, input: usb, inputInfo: .some(usbInfo)), "the input does not matter to the publisher")
        XCTAssertFalse(stands(latch, output: headphones))
        XCTAssertFalse(stands(latch, outputInfo: .some(wired)))
        XCTAssertFalse(stands(latch, outputInfo: .some(nil)))
    }

    func testVoiceProcessingLatchesOnlyABluetoothRefusal() {
        for refusal: ProcessedMicrophoneRefusal in [.bluetoothInput, .bluetoothOutputForVoiceProcessing] {
            let latch = SourceRefusalLatch.voiceProcessing(
                .refused(refusal),
                inputDeviceID: builtIn,
                polledInput: wired,
                outputDeviceID: speakers,
                polledOutput: wired
            )
            XCTAssertEqual(latch?.refusal, refusal)
            XCTAssertEqual(latch?.scope, .voiceProcessing)
        }

        let waitedOut: [VoiceProcessingDeviceCheck] = [
            .unchanged, .inputMoved, .outputMoved, .refused(.noInput), .refused(.transportNotRead),
            // The latch compares the defaults, which say nothing about a
            // connected device; the poll that shows it refuses by itself.
            .refused(.bluetoothDevicePresentForVoiceProcessing)
        ]
        for check in waitedOut {
            XCTAssertNil(
                SourceRefusalLatch.voiceProcessing(
                    check,
                    inputDeviceID: builtIn,
                    polledInput: wired,
                    outputDeviceID: speakers,
                    polledOutput: wired
                ),
                "\(check)"
            )
        }
    }

    func testVoiceProcessingRefusalStandsUntilEitherDefaultOrItsTransportChanges() {
        guard let latch = SourceRefusalLatch.voiceProcessing(
            .refused(.bluetoothOutputForVoiceProcessing),
            inputDeviceID: builtIn,
            polledInput: wired,
            outputDeviceID: speakers,
            polledOutput: aggregateWithHeadset
        ) else {
            return XCTFail("a Bluetooth refusal latches")
        }

        XCTAssertTrue(stands(latch))
        XCTAssertFalse(stands(latch, voiceProcessing: false), "another mode does not open the output")
        XCTAssertFalse(stands(latch, input: usb))
        XCTAssertFalse(stands(latch, inputInfo: .some(usbInfo)))
        XCTAssertFalse(stands(latch, output: headphones))
        XCTAssertFalse(stands(latch, outputInfo: .some(wired)))
        XCTAssertFalse(stands(latch, outputInfo: .some(nil)))
    }
}
