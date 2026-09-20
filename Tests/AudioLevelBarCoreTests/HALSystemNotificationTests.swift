import XCTest
@testable import AudioLevelBarCore

final class HALSystemNotificationTests: XCTestCase {
    func testSelectorsAreTheCoreAudioConstants() {
        // 'dev#', 'dIn ', 'dOut', 'sOut' and 'srst' in AudioHardware.h.
        XCTAssertEqual(HALSystemNotification.devices.selector, 0x6465_7623)
        XCTAssertEqual(HALSystemNotification.defaultInput.selector, 0x6449_6E20)
        XCTAssertEqual(HALSystemNotification.defaultOutput.selector, 0x644F_7574)
        XCTAssertEqual(HALSystemNotification.defaultSystemOutput.selector, 0x734F_7574)
        XCTAssertEqual(HALSystemNotification.serviceRestarted.selector, 0x7372_7374)

        for notification in HALSystemNotification.allCases {
            XCTAssertEqual(HALSystemNotification(selector: notification.selector), notification)
        }
        XCTAssertNil(HALSystemNotification(selector: 0x6E61_6D65))
    }

    func testDefaultDeviceChangesArmAndAdvanceTheGenerationAtOnce() {
        for notification in [HALSystemNotification.defaultInput, .defaultOutput, .defaultSystemOutput] {
            XCTAssertEqual(notification.quietWindowReason, "hal-notification")
            XCTAssertTrue(notification.advancesHoldGenerationAtOnce)
            XCTAssertFalse(notification.requestsPoll)
        }
    }

    func testDeviceListChangeOnlyAsksForAPoll() {
        // The app's own aggregate devices change the list too; only the poll's
        // Bluetooth set decides whether it arms.
        XCTAssertNil(HALSystemNotification.devices.quietWindowReason)
        XCTAssertFalse(HALSystemNotification.devices.advancesHoldGenerationAtOnce)
        XCTAssertTrue(HALSystemNotification.devices.requestsPoll)
    }

    func testServiceRestartArmsTheWindowEvenWithAnUnchangedTopology() {
        let topology = AudioTopology(defaultInput: 10, defaultOutput: 20, bluetoothDeviceIDs: [])
        XCTAssertFalse(
            AudioTopology.armsQuietWindow(previous: topology, current: topology),
            "the poll sees nothing to arm on"
        )

        let notification = HALSystemNotification.serviceRestarted
        XCTAssertEqual(notification.quietWindowReason, "service-restarted")
        XCTAssertTrue(notification.advancesHoldGenerationAtOnce)

        var window = LifecycleQuietWindow()
        if notification.quietWindowReason != nil {
            window.noteChange(at: 100)
        }
        XCTAssertTrue(window.isHolding(at: 100))
        XCTAssertEqual(
            window.admission(at: 103.1, freshestSnapshotIssuedAt: 103.05, outstandingDefaultWrites: 0),
            .full
        )
    }

    func testOnlyAServiceRestartResetsHALState() {
        for notification in HALSystemNotification.allCases {
            XCTAssertEqual(notification.resetsHALState, notification == .serviceRestarted, "\(notification)")
        }
    }
}
