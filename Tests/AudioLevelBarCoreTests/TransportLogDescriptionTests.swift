import XCTest
@testable import AudioLevelBarCore

final class TransportLogDescriptionTests: XCTestCase {
    func testDirectDeviceUsesTheTransportName() {
        XCTAssertEqual(AudioDeviceTransportInfo(transport: .usb).logDescription, "usb")
        XCTAssertEqual(AudioDeviceTransportInfo(transport: .bluetoothLE).logDescription, "bluetoothLE")
        XCTAssertEqual(AudioDeviceTransportInfo(transport: .unknown).logDescription, "unknown")
    }

    func testAggregateListsItsActiveSubDevicesThenItsFullComposition() {
        let info = AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: [.builtIn],
            fullSubDeviceTransports: [.builtIn, .bluetooth, nil]
        )
        XCTAssertEqual(info.logDescription, "aggregate[builtIn|builtIn,bluetooth,?]")
    }

    func testAggregateWithAnUnreadableOrEmptyListSaysSo() {
        XCTAssertEqual(
            AudioDeviceTransportInfo(transport: .aggregate).logDescription,
            "aggregate[unread|unread]"
        )
        XCTAssertEqual(
            AudioDeviceTransportInfo(
                transport: .aggregate,
                activeSubDeviceTransports: [],
                fullSubDeviceTransports: []
            ).logDescription,
            "aggregate[|]"
        )
    }

    func testANonAggregateWithASubDeviceListShowsOnlyTheActiveList() {
        XCTAssertEqual(
            AudioDeviceTransportInfo(transport: .usb, activeSubDeviceTransports: [.bluetoothLE]).logDescription,
            "usb[bluetoothLE]"
        )
    }

    func testTheDescriptionHasNoSpaceOrEqualsSign() {
        let info = AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: [.builtIn, .unknown],
            fullSubDeviceTransports: [.builtIn, nil, .continuityCapture]
        )
        XCTAssertFalse(info.logDescription.contains(" "))
        XCTAssertFalse(info.logDescription.contains("="))
    }

    func testUnreadTransport() {
        XCTAssertEqual(AudioDeviceTransportInfo.logDescription(nil), "unread")
        XCTAssertEqual(
            AudioDeviceTransportInfo.logDescription(AudioDeviceTransportInfo(transport: .builtIn)),
            "builtIn"
        )
    }

    func testEveryTransportHasADistinctName() {
        let transports: [AudioDeviceTransport] = [
            .builtIn, .aggregate, .virtual, .pci, .usb, .fireWire, .bluetooth,
            .bluetoothLE, .hdmi, .displayPort, .airPlay, .avb, .thunderbolt,
            .continuityCapture, .unknown
        ]
        let names = transports.map(\.logName)
        XCTAssertEqual(Set(names).count, transports.count)
        XCTAssertFalse(names.contains(where: { $0.contains(" ") }))
    }
}
