import XCTest
@testable import AudioLevelBarCore

final class InputOpenSequenceTests: XCTestCase {
    private let deviceID: UInt32 = 42

    private let wiredAggregate = AudioDeviceTransportInfo(
        transport: .aggregate,
        activeSubDeviceTransports: [.builtIn],
        fullSubDeviceTransports: [.builtIn]
    )

    private var refusedReads: [AudioDeviceTransportInfo?] {
        [
            nil,
            AudioDeviceTransportInfo(transport: .bluetooth),
            AudioDeviceTransportInfo(transport: .bluetoothLE),
            AudioDeviceTransportInfo(
                transport: .aggregate,
                activeSubDeviceTransports: [.builtIn, .bluetooth],
                fullSubDeviceTransports: [.builtIn, .bluetooth]
            ),
            AudioDeviceTransportInfo(
                transport: .aggregate,
                activeSubDeviceTransports: [.builtIn],
                fullSubDeviceTransports: [.builtIn, .bluetooth]
            ),
            AudioDeviceTransportInfo(
                transport: .aggregate,
                activeSubDeviceTransports: [.builtIn],
                fullSubDeviceTransports: [.builtIn, nil]
            )
        ]
    }

    func testSecondReadShowingBluetoothNeverStarts() {
        for info in refusedReads {
            for generationCurrent in [true, false] {
                let step = InputOpenSequence.afterListeners(
                    deviceID: deviceID,
                    secondInfo: info,
                    generationCurrent: generationCurrent
                )
                if case .start = step {
                    XCTFail("\(AudioDeviceTransportInfo.logDescription(info)) started")
                }
            }
        }
    }

    func testSecondReadRefusalReleasesWhenNoWindowArmed() {
        XCTAssertEqual(
            InputOpenSequence.afterListeners(
                deviceID: deviceID,
                secondInfo: AudioDeviceTransportInfo(transport: .bluetooth),
                generationCurrent: true
            ),
            .refuseAndRelease(.bluetooth)
        )
        XCTAssertEqual(
            InputOpenSequence.afterListeners(deviceID: deviceID, secondInfo: nil, generationCurrent: true),
            .refuseAndRelease(.transportNotRead)
        )
    }

    func testSecondReadRefusalAfterWindowArmedInterrupts() {
        XCTAssertEqual(
            InputOpenSequence.afterListeners(
                deviceID: deviceID,
                secondInfo: AudioDeviceTransportInfo(
                    transport: .aggregate,
                    activeSubDeviceTransports: [.builtIn, .bluetooth],
                    fullSubDeviceTransports: [.builtIn, .bluetooth]
                ),
                generationCurrent: false
            ),
            .interrupt(refusal: .aggregateWithBluetoothMember),
            "nothing is released inside the window, but the refusal is still logged"
        )
    }

    func testAWindowArmedWithoutARefusalInterrupts() {
        XCTAssertEqual(
            InputOpenSequence.afterListeners(deviceID: deviceID, secondInfo: wiredAggregate, generationCurrent: false),
            .interrupt(refusal: nil)
        )
    }

    func testAnAllowedSecondReadStartsWithItsOwnNote() {
        XCTAssertEqual(
            InputOpenSequence.afterListeners(deviceID: deviceID, secondInfo: wiredAggregate, generationCurrent: true),
            .start(.knownTransport)
        )
        XCTAssertEqual(
            InputOpenSequence.afterListeners(
                deviceID: deviceID,
                secondInfo: AudioDeviceTransportInfo(transport: .unknown),
                generationCurrent: true
            ),
            .start(.unknownTransport)
        )
    }

    func testSubDeviceListenersAreAddedLateOnlyForAnAggregateTheFirstReadDidNotShow() {
        let builtIn = AudioDeviceTransportInfo(transport: .builtIn)
        XCTAssertTrue(InputOpenSequence.addsSubDeviceListenersAfterSecondRead(first: builtIn, second: wiredAggregate))
        XCTAssertTrue(InputOpenSequence.addsSubDeviceListenersAfterSecondRead(first: nil, second: wiredAggregate))
        XCTAssertFalse(
            InputOpenSequence.addsSubDeviceListenersAfterSecondRead(first: wiredAggregate, second: wiredAggregate),
            "already added before the second read"
        )
        XCTAssertFalse(InputOpenSequence.addsSubDeviceListenersAfterSecondRead(first: builtIn, second: builtIn))
        XCTAssertFalse(InputOpenSequence.addsSubDeviceListenersAfterSecondRead(first: wiredAggregate, second: builtIn))
    }
}
