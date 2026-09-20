import CoreAudio
import XCTest
@testable import AudioLevelBarCore

final class AggregateMembershipPolicyTests: XCTestCase {
    private func aggregate(
        _ active: [AudioDeviceTransport]?,
        full: [AudioDeviceTransport?]? = nil
    ) -> AudioDeviceTransportInfo {
        AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: active,
            fullSubDeviceTransports: full ?? active.map { $0.map { Optional($0) } }
        )
    }

    func testOnlyAnAggregateIsWatched() {
        XCTAssertTrue(AggregateMembershipPolicy.watchesSubDeviceLists(aggregate([.builtIn])))
        XCTAssertTrue(
            AggregateMembershipPolicy.watchesSubDeviceLists(aggregate(nil)),
            "an aggregate whose sub-devices could not be listed is still watched"
        )
        let direct: [AudioDeviceTransport] = [.builtIn, .usb, .virtual, .continuityCapture, .unknown]
        for transport in direct {
            XCTAssertFalse(
                AggregateMembershipPolicy.watchesSubDeviceLists(
                    AudioDeviceTransportInfo(transport: transport)
                ),
                "\(transport)"
            )
        }
        XCTAssertFalse(AggregateMembershipPolicy.watchesSubDeviceLists(nil))
    }

    func testABluetoothDeviceJoiningStopsAtOnce() {
        let joined: [AudioDeviceTransport] = [.bluetooth, .bluetoothLE]
        for transport in joined {
            XCTAssertEqual(
                AggregateMembershipPolicy.afterActiveSubDevicesChanged(
                    aggregate([.builtIn, transport])
                ),
                .stopNow,
                "\(transport)"
            )
        }
        XCTAssertEqual(
            AggregateMembershipPolicy.afterActiveSubDevicesChanged(aggregate([.bluetooth])),
            .stopNow
        )
    }

    func testChangesThatAddNoBluetoothDeviceAreLeftToTheOwner() {
        let lists: [[AudioDeviceTransport]] = [[.builtIn, .usb], [], [.unknown], [.aggregate]]
        for list in lists {
            XCTAssertEqual(
                AggregateMembershipPolicy.afterActiveSubDevicesChanged(aggregate(list)),
                .leaveToOwner,
                "\(list)"
            )
        }
    }

    /// A Bluetooth member that is in the full composition but not active
    /// carries no IO. The listener's invalidation arms the window, and the
    /// owner refuses the aggregate after it, outside the headset's change.
    func testFullListGainingBluetoothIsLeftToTheOwner() {
        for transport in [AudioDeviceTransport.bluetooth, .bluetoothLE] {
            XCTAssertEqual(
                AggregateMembershipPolicy.afterActiveSubDevicesChanged(
                    aggregate([.builtIn], full: [.builtIn, transport])
                ),
                .leaveToOwner,
                "\(transport)"
            )
        }
        XCTAssertEqual(
            AggregateMembershipPolicy.afterActiveSubDevicesChanged(aggregate([.builtIn], full: [.builtIn, nil])),
            .leaveToOwner,
            "an unresolved member is refused by the owner, not stopped at once"
        )
    }

    func testUnreadableDevicesAreLeftToTheOwner() {
        XCTAssertEqual(AggregateMembershipPolicy.afterActiveSubDevicesChanged(nil), .leaveToOwner)
        XCTAssertEqual(
            AggregateMembershipPolicy.afterActiveSubDevicesChanged(aggregate(nil)),
            .leaveToOwner
        )
    }

    func testAHeadsetJoiningAnOpenAggregateFromRawTransportTypes() {
        let aggregateID: UInt32 = 10
        let builtInID: UInt32 = 20
        let headsetID: UInt32 = 30
        let transportTypes: [UInt32: UInt32] = [
            aggregateID: kAudioDeviceTransportTypeAggregate,
            builtInID: kAudioDeviceTransportTypeBuiltIn,
            headsetID: kAudioDeviceTransportTypeBluetooth
        ]
        var active = [builtInID]
        var full: [UInt32?] = [builtInID]
        func readAggregate() -> AudioDeviceTransportInfo? {
            AudioDeviceTransportInfo.read(
                deviceID: aggregateID,
                transportOf: { transportTypes[$0].map(AudioDeviceTransport.init(transportType:)) },
                activeSubDevicesOf: { _ in active },
                fullSubDevicesOf: { _ in full }
            )
        }

        let opened = readAggregate()
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: aggregateID, info: opened), .open(.knownTransport))
        XCTAssertTrue(AggregateMembershipPolicy.watchesSubDeviceLists(opened))
        XCTAssertEqual(AggregateMembershipPolicy.afterActiveSubDevicesChanged(opened), .leaveToOwner)

        // The composition is edited to name the headset, which is not active.
        full = [builtInID, headsetID]
        XCTAssertEqual(AggregateMembershipPolicy.afterActiveSubDevicesChanged(readAggregate()), .leaveToOwner)
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: aggregateID, info: readAggregate()),
            .refuse(.aggregateWithBluetoothMember)
        )

        // The last resort: it becomes active while the IOProc still runs.
        active = [builtInID, headsetID]
        XCTAssertEqual(AggregateMembershipPolicy.afterActiveSubDevicesChanged(readAggregate()), .stopNow)
    }
}
