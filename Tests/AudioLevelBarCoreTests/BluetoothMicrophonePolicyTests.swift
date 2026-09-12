import XCTest
@testable import AudioLevelBarCore

final class BluetoothMicrophonePolicyTests: XCTestCase {
    func testUnknownTransportHoldsOffRegardlessOfEverythingElse() {
        for always in [false, true] {
            for visible in [false, true] {
                XCTAssertTrue(
                    BluetoothMicrophonePolicy.shouldPauseMonitoring(
                        transport: nil,
                        alwaysMonitorBluetooth: always,
                        metersAreVisible: visible
                    )
                )
            }
        }
    }

    func testNonBluetoothTransportsAlwaysMonitor() {
        let transports: [AudioDeviceTransport] = [
            .builtIn, .usb, .aggregate, .virtual, .continuityCapture, .unknown
        ]
        for transport in transports {
            XCTAssertFalse(
                BluetoothMicrophonePolicy.shouldPauseMonitoring(
                    transport: transport,
                    alwaysMonitorBluetooth: false,
                    metersAreVisible: false
                ),
                "\(transport) must not pause"
            )
        }
    }

    func testBluetoothPausesOnlyWhileHiddenAndNotOverridden() {
        for transport in [AudioDeviceTransport.bluetooth, .bluetoothLE] {
            XCTAssertTrue(
                BluetoothMicrophonePolicy.shouldPauseMonitoring(
                    transport: transport,
                    alwaysMonitorBluetooth: false,
                    metersAreVisible: false
                )
            )
            XCTAssertFalse(
                BluetoothMicrophonePolicy.shouldPauseMonitoring(
                    transport: transport,
                    alwaysMonitorBluetooth: false,
                    metersAreVisible: true
                ),
                "a visible panel resumes monitoring"
            )
            XCTAssertFalse(
                BluetoothMicrophonePolicy.shouldPauseMonitoring(
                    transport: transport,
                    alwaysMonitorBluetooth: true,
                    metersAreVisible: false
                ),
                "the override monitors continuously"
            )
        }
    }
}
