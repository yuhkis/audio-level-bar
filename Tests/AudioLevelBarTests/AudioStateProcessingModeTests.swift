import XCTest
@testable import AudioLevelBar

/// Apple voice processing behind the hidden
/// `experimentalAppleVoiceProcessingEnabled` setting.
final class AudioStateProcessingModeTests: XCTestCase {
    func testWithoutTheHiddenSettingAppleVoiceProcessingIsNeitherOfferedNorUsed() {
        let harness = AudioStateHarness(
            processedMicrophone: true,
            processingMode: .apple,
            appleVoiceProcessingAvailable: false
        )
        defer { harness.tearDown() }

        XCTAssertFalse(harness.state.appleVoiceProcessingAvailable)
        XCTAssertFalse(harness.state.availableProcessingModes.contains(.apple))
        XCTAssertEqual(harness.state.availableProcessingModes.count, MicrophoneProcessingMode.allCases.count - 1)
        XCTAssertEqual(harness.state.microphoneProcessingMode, .off, "a saved choice of it reads as off")
        XCTAssertEqual(
            harness.defaults.string(forKey: "microphoneProcessingMode"),
            "apple",
            "and is kept as saved"
        )

        harness.state.setMicrophoneProcessingMode(.apple)
        XCTAssertEqual(harness.state.microphoneProcessingMode, .off, "it cannot be chosen")

        harness.state.setMicrophoneProcessingMode(.webRTCLow)
        XCTAssertEqual(harness.state.microphoneProcessingMode, .webRTCLow, "the other modes can")
    }

    func testWithTheHiddenSettingAppleVoiceProcessingIsOffered() {
        let harness = AudioStateHarness(processedMicrophone: true, processingMode: .apple)
        defer { harness.tearDown() }

        XCTAssertTrue(harness.state.availableProcessingModes.contains(.apple))
        XCTAssertEqual(harness.state.microphoneProcessingMode, .apple)
    }
}
