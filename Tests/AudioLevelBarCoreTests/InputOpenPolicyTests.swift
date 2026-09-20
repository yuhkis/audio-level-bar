import XCTest
@testable import AudioLevelBarCore

final class InputOpenPolicyTests: XCTestCase {
    private func info(
        _ transport: AudioDeviceTransport,
        _ subDevices: [AudioDeviceTransport]? = nil
    ) -> AudioDeviceTransportInfo {
        AudioDeviceTransportInfo(transport: transport, activeSubDeviceTransports: subDevices)
    }

    /// An aggregate whose active sub-devices are `active` and whose full
    /// composition is `full`, nil elements being unresolved members.
    private func aggregate(
        active: [AudioDeviceTransport]?,
        full: [AudioDeviceTransport?]?
    ) -> AudioDeviceTransportInfo {
        AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: active,
            fullSubDeviceTransports: full
        )
    }

    func testUnreadTransportIsNotOpened() {
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: nil),
            .refuse(.transportNotRead)
        )
    }

    func testNoDeviceIsNotOpened() {
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 0, info: nil), .refuse(.noDevice))
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 0, info: info(.builtIn)),
            .refuse(.noDevice)
        )
    }

    func testBluetoothMicrophonesAreRefused() {
        for transport in [AudioDeviceTransport.bluetooth, .bluetoothLE] {
            XCTAssertEqual(
                InputOpenPolicy.decide(deviceID: 42, info: info(transport)),
                .refuse(.bluetooth),
                "\(transport)"
            )
        }
    }

    func testAggregateWithActiveBluetoothMemberIsRefused() {
        XCTAssertEqual(
            InputOpenPolicy.decide(
                deviceID: 42,
                info: aggregate(active: [.builtIn, .bluetooth], full: [.builtIn, .bluetooth])
            ),
            .refuse(.aggregateWithBluetoothMember)
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.bluetoothLE], full: [.bluetoothLE])),
            .refuse(.aggregateWithBluetoothMember)
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn, .bluetooth], full: nil)),
            .refuse(.aggregateWithBluetoothMember),
            "an active list that names Bluetooth is enough, whatever the full list read"
        )
    }

    /// The case the full composition exists for: a user aggregate of the
    /// built-in microphone and a headset whose member is resolved but not
    /// active. Connecting the headset recomposes the aggregate under whatever
    /// runs on it.
    func testAggregateWithInactiveBluetoothMemberIsRefused() {
        for transport in [AudioDeviceTransport.bluetooth, .bluetoothLE] {
            XCTAssertEqual(
                InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn], full: [.builtIn, transport])),
                .refuse(.aggregateWithBluetoothMember),
                "\(transport)"
            )
        }
    }

    /// A headset in its case is absent from the system, so its UID resolves
    /// to no device: the member is unresolved, and counts as Bluetooth.
    func testAggregateWithAbsentMemberIsRefused() {
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn], full: [.builtIn, nil])),
            .refuse(.aggregateWithUnresolvedMember)
        )
    }

    func testAggregateWithUnreadableFullCompositionIsRefused() {
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn], full: nil)),
            .refuse(.aggregateWithUnresolvedMember)
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: info(.aggregate, [.builtIn, .usb])),
            .refuse(.aggregateWithUnresolvedMember),
            "the active list alone does not rule out a member that is not active"
        )
    }

    func testANestedAggregateLeftInTheFullCompositionIsRefused() {
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn], full: [.builtIn, .aggregate])),
            .refuse(.aggregateWithUnresolvedMember)
        )
    }

    func testBluetoothSubDeviceIsRefusedWhateverTheTopLevelTransportSays() {
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: info(.unknown, [.usb, .bluetooth])),
            .refuse(.aggregateWithBluetoothMember)
        )
    }

    func testAggregateWithOnlyWiredMembersOpens() {
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn, .usb], full: [.builtIn, .usb])),
            .open(.knownTransport)
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn], full: [.builtIn, .usb])),
            .open(.knownTransport),
            "a wired member that is not active rules nothing out"
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: nil, full: [.builtIn, .usb])),
            .open(.knownTransport),
            "the full composition decides; the active list only adds evidence of Bluetooth"
        )
    }

    func testAnAggregateWhoseCompositionNamesNoMemberIsRefused() {
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [], full: [])),
            .refuse(.aggregateWithUnresolvedMember),
            "a tap-only aggregate: what feeds it cannot be checked"
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn], full: [])),
            .refuse(.aggregateWithUnresolvedMember),
            "an active list the full composition does not back"
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.aggregate], full: [])),
            .refuse(.aggregateWithUnresolvedMember),
            "a nested aggregate only the active list names"
        )
    }

    func testAggregateWithUnknownMemberOpensWithNote() {
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.unknown], full: [.unknown])),
            .open(.unknownTransport)
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn], full: [.builtIn, .unknown])),
            .open(.unknownTransport)
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: aggregate(active: [.builtIn, .unknown], full: [.builtIn])),
            .open(.unknownTransport),
            "an active sub-device whose transport could not be read"
        )
    }

    func testUnknownTransportOpensWithNote() {
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 42, info: info(.unknown)),
            .open(.unknownTransport)
        )
    }

    func testKnownNonBluetoothTransportsOpen() {
        let transports: [AudioDeviceTransport] = [
            .builtIn, .usb, .virtual, .continuityCapture, .hdmi, .airPlay,
            .pci, .fireWire, .displayPort, .avb, .thunderbolt
        ]
        for transport in transports {
            XCTAssertEqual(
                InputOpenPolicy.decide(deviceID: 42, info: info(transport)),
                .open(.knownTransport),
                "\(transport)"
            )
        }
    }

    func testOnlyKnownTransportGoesUnlogged() {
        XCTAssertFalse(InputOpenNote.knownTransport.shouldBeLogged)
        XCTAssertTrue(InputOpenNote.unknownTransport.shouldBeLogged)
    }

    func testInvolvesBluetoothForDirectDevices() {
        XCTAssertTrue(InputOpenPolicy.involvesBluetooth(info(.bluetooth)))
        XCTAssertTrue(InputOpenPolicy.involvesBluetooth(info(.bluetoothLE)))
        XCTAssertFalse(InputOpenPolicy.involvesBluetooth(info(.builtIn)))
        XCTAssertFalse(InputOpenPolicy.involvesBluetooth(info(.unknown)))
        XCTAssertFalse(InputOpenPolicy.involvesBluetooth(nil))
    }

    func testInvolvesBluetoothForAggregates() {
        XCTAssertTrue(InputOpenPolicy.involvesBluetooth(aggregate(active: [.usb, .bluetooth], full: [.usb, .bluetooth])))
        XCTAssertTrue(InputOpenPolicy.involvesBluetooth(aggregate(active: [.usb], full: [.usb, .bluetoothLE])))
        XCTAssertTrue(
            InputOpenPolicy.involvesBluetooth(aggregate(active: [.usb], full: [.usb, nil])),
            "an unresolved member counts as Bluetooth"
        )
        XCTAssertTrue(
            InputOpenPolicy.involvesBluetooth(aggregate(active: nil, full: nil)),
            "so does a composition that could not be read"
        )
        XCTAssertFalse(InputOpenPolicy.involvesBluetooth(aggregate(active: [.usb, .builtIn], full: [.usb, .builtIn])))
    }

    func testActiveBluetoothIsOnlyWhatIsActive() {
        XCTAssertTrue(aggregate(active: [.usb, .bluetooth], full: [.usb, .bluetooth]).showsActiveBluetooth)
        XCTAssertFalse(aggregate(active: [.usb], full: [.usb, .bluetooth]).showsActiveBluetooth)
        XCTAssertFalse(aggregate(active: [.usb], full: [.usb, nil]).showsActiveBluetooth)
        XCTAssertTrue(info(.bluetooth).showsActiveBluetooth)
    }
}
