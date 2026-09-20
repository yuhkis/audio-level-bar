import CoreAudio
import XCTest
@testable import AudioLevelBarCore

final class DeviceTransportClassificationTests: XCTestCase {
    // MARK: Transport type mapping

    func testEveryKnownTransportTypeMaps() {
        let expected: [(UInt32, AudioDeviceTransport)] = [
            (kAudioDeviceTransportTypeBuiltIn, .builtIn),
            (kAudioDeviceTransportTypeAggregate, .aggregate),
            (kAudioDeviceTransportTypeAutoAggregate, .aggregate),
            (kAudioDeviceTransportTypeVirtual, .virtual),
            (kAudioDeviceTransportTypePCI, .pci),
            (kAudioDeviceTransportTypeUSB, .usb),
            (kAudioDeviceTransportTypeFireWire, .fireWire),
            (kAudioDeviceTransportTypeBluetooth, .bluetooth),
            (kAudioDeviceTransportTypeBluetoothLE, .bluetoothLE),
            (kAudioDeviceTransportTypeHDMI, .hdmi),
            (kAudioDeviceTransportTypeDisplayPort, .displayPort),
            (kAudioDeviceTransportTypeAirPlay, .airPlay),
            (kAudioDeviceTransportTypeAVB, .avb),
            (kAudioDeviceTransportTypeThunderbolt, .thunderbolt),
            (kAudioDeviceTransportTypeContinuityCaptureWired, .continuityCapture),
            (kAudioDeviceTransportTypeContinuityCaptureWireless, .continuityCapture)
        ]
        for (rawValue, transport) in expected {
            XCTAssertEqual(
                AudioDeviceTransport(transportType: rawValue),
                transport,
                fourCC(rawValue)
            )
        }
    }

    /// Pins the FourCC values the refusals depend on, so a constant swapped
    /// for a similar-looking one fails here and not on a headset.
    func testBluetoothAndAggregateFourCCs() {
        XCTAssertEqual(AudioDeviceTransport(transportType: fourCC("blue")), .bluetooth)
        XCTAssertEqual(AudioDeviceTransport(transportType: fourCC("blea")), .bluetoothLE)
        XCTAssertEqual(AudioDeviceTransport(transportType: fourCC("grup")), .aggregate)
        XCTAssertEqual(AudioDeviceTransport(transportType: fourCC("fgrp")), .aggregate)
    }

    func testUnrecognizedTransportTypeIsUnknown() {
        XCTAssertEqual(AudioDeviceTransport(transportType: 0), .unknown)
        XCTAssertEqual(AudioDeviceTransport(transportType: fourCC("zzzz")), .unknown)
    }

    func testRawBluetoothTypeIsRefusedEndToEnd() {
        let rawTypes: [UInt32: UInt32] = [
            7: kAudioDeviceTransportTypeBluetooth,
            8: kAudioDeviceTransportTypeBluetoothLE,
            9: kAudioDeviceTransportTypeAutoAggregate,
            10: kAudioDeviceTransportTypeBuiltIn
        ]
        let read: (UInt32) -> AudioDeviceTransport? = { deviceID in
            rawTypes[deviceID].map(AudioDeviceTransport.init(transportType:))
        }

        for deviceID: UInt32 in [7, 8] {
            let info = AudioDeviceTransportInfo.read(
                deviceID: deviceID,
                transportOf: read,
                activeSubDevicesOf: { _ in nil },
                fullSubDevicesOf: { _ in nil }
            )
            XCTAssertEqual(
                InputOpenPolicy.decide(deviceID: deviceID, info: info),
                .refuse(.bluetooth)
            )
        }

        // A framework's automatic aggregate around a headset is refused too.
        let autoAggregate = AudioDeviceTransportInfo.read(
            deviceID: 9,
            transportOf: read,
            activeSubDevicesOf: { _ in [10, 7] },
            fullSubDevicesOf: { _ in [10, 7] }
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 9, info: autoAggregate),
            .refuse(.aggregateWithBluetoothMember)
        )
    }

    // MARK: Transport info

    func testNoDeviceReadsNothing() {
        var reads = 0
        let info = AudioDeviceTransportInfo.read(
            deviceID: 0,
            transportOf: { _ in reads += 1; return .builtIn },
            activeSubDevicesOf: { _ in reads += 1; return [] },
            fullSubDevicesOf: { _ in reads += 1; return [] }
        )
        XCTAssertNil(info)
        XCTAssertEqual(reads, 0)
    }

    func testUnreadableOwnTransportIsNilAndRefused() {
        let info = AudioDeviceTransportInfo.read(
            deviceID: 5,
            transportOf: { _ in nil },
            activeSubDevicesOf: { _ in [1, 2] },
            fullSubDevicesOf: { _ in [1, 2] }
        )
        XCTAssertNil(info)
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 5, info: info), .refuse(.transportNotRead))
    }

    func testNonAggregateDoesNotReadSubDevices() {
        var subDeviceReads = 0
        let info = AudioDeviceTransportInfo.read(
            deviceID: 5,
            transportOf: { _ in .usb },
            activeSubDevicesOf: { _ in subDeviceReads += 1; return [1] },
            fullSubDevicesOf: { _ in subDeviceReads += 1; return [1] }
        )
        XCTAssertEqual(info, AudioDeviceTransportInfo(transport: .usb))
        XCTAssertEqual(subDeviceReads, 0)
    }

    func testUnreadableActiveSubDeviceCountsAsUnknown() {
        let transports: [UInt32: AudioDeviceTransport] = [5: .aggregate, 1: .builtIn]
        let info = AudioDeviceTransportInfo.read(
            deviceID: 5,
            transportOf: { transports[$0] },
            activeSubDevicesOf: { _ in [1, 2] },
            fullSubDevicesOf: { _ in [1] }
        )
        XCTAssertEqual(
            info,
            AudioDeviceTransportInfo(
                transport: .aggregate,
                activeSubDeviceTransports: [.builtIn, .unknown],
                fullSubDeviceTransports: [.builtIn]
            )
        )
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 5, info: info), .open(.unknownTransport))
    }

    func testUnreadableSubDeviceListsAreRefused() {
        let info = AudioDeviceTransportInfo.read(
            deviceID: 5,
            transportOf: { _ in .aggregate },
            activeSubDevicesOf: { _ in nil },
            fullSubDevicesOf: { _ in nil }
        )
        XCTAssertEqual(info, AudioDeviceTransportInfo(transport: .aggregate))
        XCTAssertNil(info?.fullSubDeviceTransports)
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 5, info: info), .refuse(.aggregateWithUnresolvedMember))
    }

    // MARK: Full composition

    private let composition: [UInt32: AudioDeviceTransport] = [
        1: .builtIn,
        2: .usb,
        3: .bluetooth,
        4: .bluetoothLE,
        50: .aggregate,
        60: .aggregate,
        70: .aggregate,
        80: .aggregate
    ]

    private func readComposition(
        of deviceID: UInt32,
        active: [UInt32: [UInt32]] = [:],
        full: [UInt32: [UInt32?]]
    ) -> AudioDeviceTransportInfo? {
        AudioDeviceTransportInfo.read(
            deviceID: deviceID,
            transportOf: { self.composition[$0] },
            activeSubDevicesOf: { active[$0] ?? [] },
            fullSubDevicesOf: { full[$0] }
        )
    }

    func testAMemberThatIsNotActiveIsInTheFullComposition() {
        let info = readComposition(of: 50, active: [50: [1]], full: [50: [1, 3]])
        XCTAssertEqual(info?.activeSubDeviceTransports, [.builtIn])
        XCTAssertEqual(info?.fullSubDeviceTransports, [.builtIn, .bluetooth])
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 50, info: info), .refuse(.aggregateWithBluetoothMember))
    }

    func testAnAbsentMemberIsUnresolved() {
        // The member's UID resolved to no device, as for a headset in its case.
        let info = readComposition(of: 50, active: [50: [1]], full: [50: [1, nil]])
        XCTAssertEqual(info?.fullSubDeviceTransports, [.builtIn, nil])
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 50, info: info), .refuse(.aggregateWithUnresolvedMember))
    }

    func testAMemberWhoseTransportCannotBeReadIsUnresolved() {
        let info = readComposition(of: 50, full: [50: [1, 99]])
        XCTAssertEqual(info?.fullSubDeviceTransports, [.builtIn, nil])
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 50, info: info), .refuse(.aggregateWithUnresolvedMember))
    }

    func testANestedAggregateIsReplacedByItsMembers() {
        let wired = readComposition(of: 50, full: [50: [1, 60], 60: [2]])
        XCTAssertEqual(wired?.fullSubDeviceTransports, [.builtIn, .usb])
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 50, info: wired), .open(.knownTransport))

        let headsetInside = readComposition(of: 50, full: [50: [1, 60], 60: [2, 70], 70: [4]])
        XCTAssertEqual(headsetInside?.fullSubDeviceTransports, [.builtIn, .usb, .bluetoothLE])
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 50, info: headsetInside),
            .refuse(.aggregateWithBluetoothMember)
        )
    }

    func testANestedAggregateThatCannotBeReadIsUnresolved() {
        let info = readComposition(of: 50, full: [50: [1, 60]])
        XCTAssertEqual(info?.fullSubDeviceTransports, [.builtIn, nil])
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 50, info: info), .refuse(.aggregateWithUnresolvedMember))
    }

    func testAnAggregateThatNamesItselfIsUnresolvedAndTerminates() {
        let info = readComposition(of: 50, full: [50: [1, 60], 60: [50]])
        XCTAssertEqual(info?.fullSubDeviceTransports, [.builtIn, nil])
    }

    func testNestingDeeperThanTheLimitIsUnresolved() {
        XCTAssertEqual(AudioDeviceTransportInfo.maximumNestingDepth, 4)
        let withinLimit = readComposition(of: 50, full: [50: [60], 60: [70], 70: [80], 80: [1]])
        XCTAssertEqual(withinLimit?.fullSubDeviceTransports, [.builtIn])

        var deeper: [UInt32: AudioDeviceTransport] = composition
        deeper[90] = .aggregate
        let info = AudioDeviceTransportInfo.read(
            deviceID: 50,
            transportOf: { deeper[$0] },
            activeSubDevicesOf: { _ in [] },
            fullSubDevicesOf: { [50: [60], 60: [70], 70: [80], 80: [90], 90: [1]][$0] }
        )
        XCTAssertEqual(info?.fullSubDeviceTransports, [nil])
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 50, info: info), .refuse(.aggregateWithUnresolvedMember))
    }

    func testTheRawAirPodsAggregateCaseIsRefusedEndToEnd() {
        let rawTypes: [UInt32: UInt32] = [
            9: kAudioDeviceTransportTypeAggregate,
            10: kAudioDeviceTransportTypeBuiltIn,
            7: kAudioDeviceTransportTypeBluetooth
        ]
        let read: (UInt32) -> AudioDeviceTransport? = { rawTypes[$0].map(AudioDeviceTransport.init(transportType:)) }
        let absent = AudioDeviceTransportInfo.read(
            deviceID: 9,
            transportOf: read,
            activeSubDevicesOf: { _ in [10] },
            fullSubDevicesOf: { _ in [10, nil] }
        )
        XCTAssertEqual(InputOpenPolicy.decide(deviceID: 9, info: absent), .refuse(.aggregateWithUnresolvedMember))
        let connectedNotActive = AudioDeviceTransportInfo.read(
            deviceID: 9,
            transportOf: read,
            activeSubDevicesOf: { _ in [10] },
            fullSubDevicesOf: { _ in [10, 7] }
        )
        XCTAssertEqual(
            InputOpenPolicy.decide(deviceID: 9, info: connectedNotActive),
            .refuse(.aggregateWithBluetoothMember)
        )
    }

    // MARK: Device transport cache

    private let transports: [UInt32: AudioDeviceTransport] = [
        10: .builtIn,
        20: .builtIn,
        30: .bluetooth,
        40: .usb,
        50: .bluetoothLE
    ]

    func testUSBArrivalLeavesTheBluetoothSetUnchanged() {
        var cache = DeviceTransportCache()
        cache.update(listing: [10, 20, 30]) { self.transports[$0] }
        XCTAssertEqual(cache.bluetoothDeviceIDs, [30])

        cache.update(listing: [10, 20, 30, 40]) { self.transports[$0] }
        XCTAssertEqual(cache[40], .usb)
        XCTAssertEqual(cache.bluetoothDeviceIDs, [30])
    }

    func testBluetoothArrivalAndDepartureChangeTheSet() {
        var cache = DeviceTransportCache()
        cache.update(listing: [10, 20]) { self.transports[$0] }
        XCTAssertEqual(cache.bluetoothDeviceIDs, [])

        cache.update(listing: [10, 20, 50]) { self.transports[$0] }
        XCTAssertEqual(cache.bluetoothDeviceIDs, [50])

        cache.update(listing: [10, 20]) { self.transports[$0] }
        XCTAssertEqual(cache.bluetoothDeviceIDs, [])
        XCTAssertNil(cache[50], "a removed ID is dropped")
    }

    func testFailedListReadKeepsTheCache() {
        var cache = DeviceTransportCache()
        cache.update(listing: [10, 30]) { self.transports[$0] }
        let before = cache

        var reads = 0
        cache.update(listing: nil) { _ in reads += 1; return nil }
        XCTAssertEqual(cache, before)
        XCTAssertEqual(cache.bluetoothDeviceIDs, [30])
        XCTAssertEqual(reads, 0)
    }

    func testEmptyListIsEveryDeviceLeaving() {
        var cache = DeviceTransportCache()
        cache.update(listing: [10, 30]) { self.transports[$0] }
        cache.update(listing: []) { self.transports[$0] }
        XCTAssertEqual(cache.transports, [:])
        XCTAssertEqual(cache.bluetoothDeviceIDs, [])
    }

    func testKnownIDsAreNotReadAgain() {
        var cache = DeviceTransportCache()
        var reads: [UInt32] = []
        cache.update(listing: [10, 30]) { reads.append($0); return self.transports[$0] }
        cache.update(listing: [10, 30, 40]) { reads.append($0); return self.transports[$0] }
        XCTAssertEqual(reads, [10, 30, 40])
    }

    func testFailedReadIsRetriedOnTheNextUpdate() {
        var cache = DeviceTransportCache()
        cache.update(listing: [10, 30]) { $0 == 30 ? nil : self.transports[$0] }
        XCTAssertNil(cache[30])
        XCTAssertEqual(cache.bluetoothDeviceIDs, [])

        var reads: [UInt32] = []
        cache.update(listing: [10, 30]) { reads.append($0); return self.transports[$0] }
        XCTAssertEqual(reads, [30])
        XCTAssertEqual(cache.bluetoothDeviceIDs, [30])
    }

    func testReusedIDIsReadAgainAfterAnAbsence() {
        var cache = DeviceTransportCache()
        cache.update(listing: [30]) { _ in .usb }
        cache.update(listing: []) { _ in .usb }
        cache.update(listing: [30]) { _ in .bluetooth }
        XCTAssertEqual(cache.bluetoothDeviceIDs, [30])
    }

    // MARK: Helpers

    private func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
