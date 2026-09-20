import XCTest
@testable import AudioLevelBarCore

final class PublisherOutputPolicyTests: XCTestCase {
    private let speakers: UInt32 = 60
    private let otherBuiltIn: UInt32 = 61
    private let headset: UInt32 = 70
    private let leHeadset: UInt32 = 71
    private let usb: UInt32 = 80
    private let multiOutput: UInt32 = 90

    private let builtInInfo = AudioDeviceTransportInfo(transport: .builtIn)
    private let bluetoothInfo = AudioDeviceTransportInfo(transport: .bluetooth)
    private let usbInfo = AudioDeviceTransportInfo(transport: .usb)

    private func listed(
        _ deviceID: UInt32,
        _ transport: AudioDeviceTransport,
        outputChannels: Bool = true
    ) -> ListedOutputDevice {
        ListedOutputDevice(deviceID: deviceID, transport: transport, hasOutputChannels: outputChannels)
    }

    private func survey(
        _ devices: [ListedOutputDevice]?,
        default defaultOutputID: UInt32,
        _ defaultOutput: AudioDeviceTransportInfo?
    ) -> PublisherOutputSurvey {
        PublisherOutputSurvey(
            listed: devices,
            defaultOutputID: defaultOutputID,
            defaultOutput: defaultOutput
        )
    }

    private func choose(_ survey: PublisherOutputSurvey) -> PublisherOutputChoice {
        PublisherOutputPolicy.choose(survey)
    }

    // MARK: Choice

    func testPublisherOutputPrefersBuiltInOverBluetoothDefault() {
        let devices = [listed(speakers, .builtIn), listed(headset, .bluetooth), listed(leHeadset, .bluetoothLE)]

        XCTAssertEqual(choose(survey(devices, default: headset, bluetoothInfo)), .device(speakers, builtInInfo))
        XCTAssertEqual(
            choose(survey(devices, default: leHeadset, AudioDeviceTransportInfo(transport: .bluetoothLE))),
            .device(speakers, builtInInfo)
        )
        XCTAssertEqual(
            choose(survey(devices + [listed(usb, .usb)], default: usb, usbInfo)),
            .device(speakers, builtInInfo),
            "a built-in output is preferred even to a wired default, so the choice does not follow the default"
        )
    }

    func testAnAggregateDefaultOutputWhoseActiveSubDevicesWereNotReadIsNotChosen() {
        let devices = [listed(multiOutput, .aggregate), listed(headset, .bluetooth)]
        let unreadActive = AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: nil,
            fullSubDeviceTransports: [.usb]
        )

        XCTAssertFalse(
            PublisherOutputPolicy.isEligible(
                PublisherOutputCandidate(deviceID: multiOutput, info: unreadActive, hasOutputChannels: true)
            ),
            "it would be stale in the survey it was chosen from"
        )
        XCTAssertEqual(choose(survey(devices, default: multiOutput, unreadActive)), .refused(.noNonBluetoothOutput))
        XCTAssertTrue(PublisherOutputPolicy.boundOutputIsStale(
            deviceID: multiOutput,
            survey: survey(devices, default: multiOutput, unreadActive)
        ))
        let readActive = AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: [.usb],
            fullSubDeviceTransports: [.usb]
        )
        XCTAssertEqual(choose(survey(devices, default: multiOutput, readActive)), .device(multiOutput, readActive))
    }

    func testPublisherOutputPrefersTheDefaultAmongSeveralBuiltInOutputs() {
        let devices = [listed(otherBuiltIn, .builtIn), listed(speakers, .builtIn), listed(headset, .bluetooth)]

        XCTAssertEqual(choose(survey(devices, default: otherBuiltIn, builtInInfo)), .device(otherBuiltIn, builtInInfo))
        XCTAssertEqual(
            choose(survey(devices, default: headset, bluetoothInfo)),
            .device(speakers, builtInInfo),
            "otherwise the lowest ID, whatever order the list is in"
        )
    }

    func testPublisherOutputUsesNonBluetoothDefaultWhenNoBuiltIn() {
        XCTAssertEqual(
            choose(survey([listed(usb, .usb), listed(headset, .bluetooth)], default: usb, usbInfo)),
            .device(usb, usbInfo)
        )
        let wiredAggregate = AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: [.usb, .hdmi],
            fullSubDeviceTransports: [.usb, .hdmi]
        )
        XCTAssertEqual(
            choose(survey([listed(multiOutput, .aggregate)], default: multiOutput, wiredAggregate)),
            .device(multiOutput, wiredAggregate)
        )
    }

    func testPublisherOutputRefusedWhenOnlyBluetoothOutputsExist() {
        let devices = [listed(headset, .bluetooth), listed(leHeadset, .bluetoothLE)]

        XCTAssertEqual(choose(survey(devices, default: headset, bluetoothInfo)), .refused(.noNonBluetoothOutput))
        XCTAssertEqual(choose(survey(devices, default: 0, nil)), .refused(.noNonBluetoothOutput))
        XCTAssertEqual(choose(survey([], default: 0, nil)), .refused(.noNonBluetoothOutput))
    }

    func testPublisherOutputRefusedForAggregateWithBluetoothMember() {
        let withHeadset = AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb, .bluetooth])
        XCTAssertEqual(
            choose(survey([listed(multiOutput, .aggregate), listed(headset, .bluetooth)], default: multiOutput, withHeadset)),
            .refused(.noNonBluetoothOutput)
        )
        let builtInTransportWithHeadset = AudioDeviceTransportInfo(transport: .usb, activeSubDeviceTransports: [.bluetoothLE])
        XCTAssertEqual(
            choose(survey([listed(usb, .usb)], default: usb, builtInTransportWithHeadset)),
            .refused(.noNonBluetoothOutput),
            "a sub-device list that names Bluetooth rules the device out whatever its own transport"
        )
        let absentHeadset = AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: [.usb],
            fullSubDeviceTransports: [.usb, nil]
        )
        let inactiveHeadset = AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: [.usb],
            fullSubDeviceTransports: [.usb, .bluetooth]
        )
        for info in [absentHeadset, inactiveHeadset] {
            XCTAssertEqual(
                choose(survey([listed(multiOutput, .aggregate)], default: multiOutput, info)),
                .refused(.noNonBluetoothOutput),
                "a member that is not active, or not resolved, rules the aggregate out: \(info.logDescription)"
            )
        }
    }

    func testAnOutputThatCannotBeVerifiedIsNotUsed() {
        XCTAssertEqual(
            choose(survey([listed(usb, .unknown)], default: usb, AudioDeviceTransportInfo(transport: .unknown))),
            .refused(.noNonBluetoothOutput),
            "an unknown transport could wrap a Bluetooth link"
        )
        XCTAssertEqual(
            choose(survey([listed(multiOutput, .aggregate)], default: multiOutput, AudioDeviceTransportInfo(transport: .aggregate))),
            .refused(.noNonBluetoothOutput),
            "an aggregate whose sub-devices cannot be listed"
        )
        XCTAssertEqual(
            choose(survey(
                [listed(multiOutput, .aggregate)],
                default: multiOutput,
                AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb, .aggregate])
            )),
            .refused(.noNonBluetoothOutput),
            "an aggregate whose full composition was not read"
        )
        XCTAssertEqual(
            choose(survey([listed(usb, .usb, outputChannels: false)], default: usb, usbInfo)),
            .refused(.noNonBluetoothOutput),
            "a device without output channels"
        )
        XCTAssertEqual(
            choose(survey([listed(speakers, .builtIn, outputChannels: false), listed(headset, .bluetooth)], default: headset, bluetoothInfo)),
            .refused(.noNonBluetoothOutput),
            "a built-in device without output channels is not an output"
        )
    }

    func testUnreadDevicesWaitRatherThanRefuse() {
        XCTAssertEqual(choose(survey(nil, default: headset, bluetoothInfo)), .refused(.outputsNotRead))
        XCTAssertEqual(choose(survey([listed(headset, .bluetooth)], default: headset, nil)), .refused(.outputsNotRead))
        XCTAssertEqual(
            choose(survey(nil, default: usb, usbInfo)),
            .device(usb, usbInfo),
            "an eligible default output does not need the list"
        )
        XCTAssertEqual(
            choose(survey([listed(speakers, .builtIn), listed(headset, .bluetooth)], default: headset, nil)),
            .device(speakers, builtInInfo),
            "a built-in output does not need the default output's transport"
        )
    }

    func testAListedTransportThatWasNotReadWaitsWhereAnUnclassifiedOneRefuses() {
        let unread = ListedOutputDevice(deviceID: usb, transport: nil, hasOutputChannels: true)
        XCTAssertEqual(
            choose(survey([listed(headset, .bluetooth), unread], default: headset, bluetoothInfo)),
            .refused(.outputsNotRead),
            "a device whose transport read failed could be an output to use: the read is waited out, not latched"
        )
        XCTAssertEqual(
            choose(survey([listed(headset, .bluetooth), listed(usb, .unknown)], default: headset, bluetoothInfo)),
            .refused(.noNonBluetoothOutput),
            "a transport that was read and is not classified rules the device out"
        )
        XCTAssertEqual(
            choose(survey(
                [listed(headset, .bluetooth), ListedOutputDevice(deviceID: usb, transport: nil, hasOutputChannels: false)],
                default: headset,
                bluetoothInfo
            )),
            .refused(.noNonBluetoothOutput),
            "a device without output channels could not be used whatever its transport"
        )
        XCTAssertEqual(
            choose(survey([ListedOutputDevice(deviceID: usb, transport: nil, hasOutputChannels: true)], default: usb, usbInfo)),
            .device(usb, usbInfo),
            "the default output's own transport is read separately"
        )
        XCTAssertFalse(
            PublisherOutputPolicy.boundOutputIsStale(
                deviceID: usb,
                survey: survey([listed(speakers, .builtIn), unread], default: speakers, builtInInfo)
            ),
            "an unread transport gives no staleness verdict"
        )
    }

    // MARK: Staleness

    func testBoundBuiltInIsNotStaleWhenTheDefaultOutputMovesToAHeadset() {
        let devices = [listed(speakers, .builtIn), listed(headset, .bluetooth)]
        XCTAssertFalse(PublisherOutputPolicy.boundOutputIsStale(
            deviceID: speakers,
            survey: survey(devices, default: headset, bluetoothInfo)
        ))
        XCTAssertFalse(PublisherOutputPolicy.boundOutputIsStale(
            deviceID: usb,
            survey: survey([listed(usb, .usb), listed(headset, .bluetooth)], default: headset, bluetoothInfo)
        ), "a wired output that is no longer the default still renders nothing anyone hears")
    }

    /// Whether the mode matters is `ProcessedMicrophoneEngineStaleness`'s; see
    /// its tests.
    func testBoundOutputIsStaleOnceItGainsBluetooth() {
        let devices = [listed(multiOutput, .aggregate)]
        let wired = AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb], fullSubDeviceTransports: [.usb])
        let withHeadset = AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb, .bluetooth])
        let withInactiveHeadset = AudioDeviceTransportInfo(
            transport: .aggregate,
            activeSubDeviceTransports: [.usb],
            fullSubDeviceTransports: [.usb, .bluetooth]
        )
        XCTAssertTrue(
            PublisherOutputPolicy.boundOutputIsStale(deviceID: multiOutput, survey: survey(devices, default: multiOutput, withInactiveHeadset)),
            "a Bluetooth member that is not active"
        )

        XCTAssertFalse(PublisherOutputPolicy.boundOutputIsStale(deviceID: multiOutput, survey: survey(devices, default: multiOutput, wired)))
        XCTAssertTrue(PublisherOutputPolicy.boundOutputIsStale(deviceID: multiOutput, survey: survey(devices, default: multiOutput, withHeadset)))
        XCTAssertTrue(
            PublisherOutputPolicy.boundOutputIsStale(deviceID: headset, survey: survey([listed(headset, .bluetooth)], default: speakers, builtInInfo)),
            "a device the list reports as Bluetooth"
        )
    }

    func testAnUncachedRefusalIsNotLatchedAgainstABuiltInOutputThePollChose() {
        XCTAssertFalse(
            PublisherOutputPolicy.uncachedRefusalMayLatch(pollChoice: .device(speakers, builtInInfo)),
            "a built-in output neither becomes Bluetooth nor goes away; the read failed"
        )
        XCTAssertTrue(PublisherOutputPolicy.uncachedRefusalMayLatch(pollChoice: .device(usb, usbInfo)))
        XCTAssertTrue(PublisherOutputPolicy.uncachedRefusalMayLatch(pollChoice: .refused(.noNonBluetoothOutput)))
    }

    func testANonBuiltInOutputIsReadAgainBeforeTheEngineStarts() {
        XCTAssertFalse(PublisherOutputPolicy.needsReadBeforeStart(builtInInfo))
        XCTAssertTrue(PublisherOutputPolicy.needsReadBeforeStart(usbInfo))

        let wired = AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb], fullSubDeviceTransports: [.usb])
        let withHeadset = AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb, .bluetooth])
        let unreadMembers = AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: nil)
        XCTAssertTrue(PublisherOutputPolicy.needsReadBeforeStart(wired))
        XCTAssertTrue(PublisherOutputPolicy.isStillEligibleBeforeStart(deviceID: multiOutput, current: wired))
        XCTAssertFalse(PublisherOutputPolicy.isStillEligibleBeforeStart(deviceID: multiOutput, current: withHeadset))
        XCTAssertFalse(PublisherOutputPolicy.isStillEligibleBeforeStart(deviceID: multiOutput, current: unreadMembers))
        XCTAssertFalse(PublisherOutputPolicy.isStillEligibleBeforeStart(deviceID: multiOutput, current: nil))
    }

    func testBoundOutputIsStaleOnceItIsNoLongerListed() {
        XCTAssertTrue(PublisherOutputPolicy.boundOutputIsStale(
            deviceID: usb,
            survey: survey([listed(speakers, .builtIn)], default: speakers, builtInInfo)
        ))
        XCTAssertFalse(
            PublisherOutputPolicy.boundOutputIsStale(deviceID: usb, survey: survey([listed(speakers, .builtIn)], default: usb, usbInfo)),
            "the default output counts as listed"
        )
    }

    func testABoundAggregateThatIsNoLongerTheDefaultCannotBeVerifiedAndIsRebuilt() {
        XCTAssertTrue(PublisherOutputPolicy.boundOutputIsStale(
            deviceID: multiOutput,
            survey: survey([listed(multiOutput, .aggregate), listed(speakers, .builtIn)], default: speakers, builtInInfo)
        ))
    }

    func testNoStaleVerdictWithoutADeviceListOrATransport() {
        XCTAssertFalse(PublisherOutputPolicy.boundOutputIsStale(deviceID: usb, survey: survey(nil, default: headset, bluetoothInfo)))
        XCTAssertFalse(PublisherOutputPolicy.boundOutputIsStale(deviceID: usb, survey: survey([listed(usb, .usb)], default: usb, nil)))
    }

    /// A rebuild that chose the device it rebuilt from, and found it stale
    /// again, would restart the engines on every evaluation.
    func testAChoiceIsNeverStaleInTheSurveyItWasMadeFrom() {
        let transports: [AudioDeviceTransport] = [.builtIn, .usb, .bluetooth, .aggregate, .unknown]
        let defaultInfos: [AudioDeviceTransportInfo?] = [
            nil,
            builtInInfo,
            usbInfo,
            bluetoothInfo,
            AudioDeviceTransportInfo(transport: .aggregate),
            AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb]),
            AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb], fullSubDeviceTransports: [.usb]),
            AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: nil, fullSubDeviceTransports: [.usb]),
            AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [], fullSubDeviceTransports: [.usb]),
            AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb], fullSubDeviceTransports: [.usb, nil]),
            AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb], fullSubDeviceTransports: [.usb, .bluetooth]),
            AudioDeviceTransportInfo(transport: .aggregate, activeSubDeviceTransports: [.usb, .bluetooth]),
            AudioDeviceTransportInfo(transport: .unknown)
        ]
        var checked = 0
        for first in transports {
            for second in transports {
                for channels in [false, true] {
                    let devicesVariants: [[ListedOutputDevice]?] = [
                        nil,
                        [listed(speakers, first, outputChannels: channels), listed(usb, second)]
                    ]
                    for devices in devicesVariants {
                        for defaultID in [0, speakers, usb, headset] {
                            for defaultInfo in defaultInfos {
                                let current = survey(devices, default: defaultID, defaultID == 0 ? nil : defaultInfo)
                                guard case let .device(chosen, _) = choose(current) else {
                                    continue
                                }
                                checked += 1
                                XCTAssertFalse(
                                    PublisherOutputPolicy.boundOutputIsStale(deviceID: chosen, survey: current),
                                    "\(current) chose \(chosen)"
                                )
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
