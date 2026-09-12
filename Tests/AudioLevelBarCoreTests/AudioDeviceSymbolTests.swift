import AppKit
import XCTest
@testable import AudioLevelBarCore

final class AudioDeviceSymbolTests: XCTestCase {
    func testBuiltInDevicesUseMacIcon() {
        XCTAssertEqual(
            AudioDeviceSymbol.systemName(
                direction: .output,
                name: "MacBook Proのスピーカー",
                uid: "BuiltInSpeakerDevice",
                transport: .builtIn
            ),
            "laptopcomputer"
        )
        XCTAssertEqual(
            AudioDeviceSymbol.systemName(
                direction: .input,
                name: "MacBook Proのマイク",
                uid: "BuiltInMicrophoneDevice",
                transport: .builtIn
            ),
            "laptopcomputer"
        )
    }

    func testHeadphonesOverrideBuiltInTransport() {
        XCTAssertEqual(
            AudioDeviceSymbol.systemName(
                direction: .output,
                name: "外部ヘッドフォン",
                uid: "BuiltInHeadphoneOutputDevice",
                transport: .builtIn
            ),
            "headphones"
        )
    }

    func testDisplayAndVirtualDevicesUseDistinctIcons() {
        XCTAssertEqual(
            AudioDeviceSymbol.systemName(
                direction: .output,
                name: "External Display",
                uid: "display",
                transport: .displayPort
            ),
            "display"
        )
        XCTAssertEqual(
            AudioDeviceSymbol.systemName(
                direction: .input,
                name: "Microsoft Teams Audio",
                uid: "MSLoopbackDriverDevice_UID",
                transport: .virtual
            ),
            "waveform"
        )
    }

    func testContinuityMicrophoneUsesIPhoneIcon() {
        XCTAssertEqual(
            AudioDeviceSymbol.systemName(
                direction: .input,
                name: "iPhoneのマイク",
                uid: "continuity",
                transport: .continuityCapture
            ),
            "iphone"
        )
    }

    func testUnknownDevicesHaveDirectionSpecificFallbacks() {
        XCTAssertEqual(
            AudioDeviceSymbol.systemName(
                direction: .output,
                name: "Unknown",
                uid: "unknown-output",
                transport: .unknown
            ),
            "speaker.wave.2.fill"
        )
        XCTAssertEqual(
            AudioDeviceSymbol.systemName(
                direction: .input,
                name: "Unknown",
                uid: "unknown-input",
                transport: .unknown
            ),
            "mic.fill"
        )
    }

    func testEveryReturnedSystemSymbolExistsOnSupportedMacOS() {
        let symbolNames = [
            "appletv.fill", "display", "headphones", "hifispeaker.fill",
            "iphone", "laptopcomputer", "mic.fill", "speaker.wave.2.fill",
            "waveform"
        ]

        for symbolName in symbolNames {
            XCTAssertNotNil(
                NSImage(
                    systemSymbolName: symbolName,
                    accessibilityDescription: nil
                ),
                "Missing SF Symbol: \(symbolName)"
            )
        }
    }
}
