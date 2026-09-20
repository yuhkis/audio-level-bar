import XCTest
@testable import AudioLevelBarCore

final class ProcessedMicrophoneSourcePolicyTests: XCTestCase {
    private func info(
        _ transport: AudioDeviceTransport,
        _ subDevices: [AudioDeviceTransport]? = nil
    ) -> AudioDeviceTransportInfo {
        AudioDeviceTransportInfo(transport: transport, activeSubDeviceTransports: subDevices)
    }

    private func decide(
        apple: Bool = false,
        inputID: UInt32 = 42,
        input: AudioDeviceTransportInfo?,
        output: AudioDeviceTransportInfo?,
        bluetoothPresent: Bool? = false
    ) -> ProcessedMicrophoneSourceDecision {
        ProcessedMicrophoneSourcePolicy.decide(
            usesVoiceProcessing: apple,
            inputDeviceID: inputID,
            input: input,
            output: output,
            bluetoothDevicePresent: bluetoothPresent
        )
    }

    // MARK: Off and WebRTC

    func testDeviceBoundModesAllowBuiltInInputWithBluetoothOutput() {
        XCTAssertEqual(decide(input: info(.builtIn), output: info(.bluetooth)), .allowed)
        XCTAssertEqual(decide(input: info(.usb), output: info(.bluetoothLE)), .allowed)
        XCTAssertEqual(decide(input: info(.builtIn), output: nil), .allowed)
    }

    func testBluetoothInputIsRefused() {
        for apple in [false, true] {
            XCTAssertEqual(
                decide(apple: apple, input: info(.bluetooth), output: info(.builtIn)),
                .refused(.bluetoothInput)
            )
            XCTAssertEqual(
                decide(apple: apple, input: info(.bluetoothLE), output: info(.builtIn)),
                .refused(.bluetoothInput)
            )
        }
    }

    func testAggregateWithBluetoothSubDeviceIsRefused() {
        XCTAssertEqual(
            decide(input: info(.aggregate, [.builtIn, .bluetooth]), output: info(.builtIn)),
            .refused(.bluetoothInput)
        )
    }

    func testAggregateWithoutBluetoothIsAllowed() {
        XCTAssertEqual(
            decide(
                input: AudioDeviceTransportInfo(
                    transport: .aggregate,
                    activeSubDeviceTransports: [.builtIn, .usb],
                    fullSubDeviceTransports: [.builtIn, .usb]
                ),
                output: info(.builtIn)
            ),
            .allowed
        )
    }

    func testAggregateWithAnInactiveBluetoothOrUnresolvedMemberIsRefused() {
        for full: [AudioDeviceTransport?]? in [[.builtIn, .bluetooth], [.builtIn, nil], nil] {
            XCTAssertEqual(
                decide(
                    input: AudioDeviceTransportInfo(
                        transport: .aggregate,
                        activeSubDeviceTransports: [.builtIn],
                        fullSubDeviceTransports: full
                    ),
                    output: info(.builtIn)
                ),
                .refused(.bluetoothInput),
                "\(String(describing: full))"
            )
        }
    }

    func testNoInputAndUnreadTransport() {
        XCTAssertEqual(decide(inputID: 0, input: nil, output: info(.builtIn)), .refused(.noInput))
        XCTAssertEqual(decide(input: nil, output: info(.builtIn)), .refused(.transportNotRead))
    }

    // MARK: Apple voice processing

    func testAppleRefusesBluetoothOutput() {
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: info(.bluetooth)),
            .refused(.bluetoothOutputForVoiceProcessing)
        )
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: info(.bluetoothLE)),
            .refused(.bluetoothOutputForVoiceProcessing)
        )
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: info(.aggregate, [.bluetooth])),
            .refused(.bluetoothOutputForVoiceProcessing)
        )
    }

    func testAppleRefusesUnreadOutput() {
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: nil),
            .refused(.transportNotRead)
        )
    }

    func testAppleAllowsWiredDevices() {
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: info(.builtIn)),
            .allowed
        )
        XCTAssertEqual(
            decide(apple: true, input: info(.usb), output: info(.hdmi)),
            .allowed
        )
    }

    // MARK: Connected Bluetooth devices

    func testAppleRefusedWhileAnyBluetoothAudioDeviceIsPresent() {
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: info(.builtIn), bluetoothPresent: true),
            .refused(.bluetoothDevicePresentForVoiceProcessing),
            "a connected headset that is neither default refuses"
        )
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: info(.bluetooth), bluetoothPresent: true),
            .refused(.bluetoothDevicePresentForVoiceProcessing),
            "the reason stays the same whether or not the headset is a default"
        )
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: nil, bluetoothPresent: true),
            .refused(.bluetoothDevicePresentForVoiceProcessing)
        )
        XCTAssertTrue(ProcessedMicrophoneRefusal.bluetoothDevicePresentForVoiceProcessing.involvesBluetooth)
    }

    func testAppleWaitsWhileWhetherABluetoothDeviceIsConnectedIsUnread() {
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: info(.builtIn), bluetoothPresent: nil),
            .refused(.transportNotRead)
        )
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: info(.bluetooth), bluetoothPresent: nil),
            .refused(.bluetoothOutputForVoiceProcessing),
            "a Bluetooth default output still says so"
        )
    }

    func testDeviceBoundModesIgnoreBluetoothPresence() {
        for present: Bool? in [true, false, nil] {
            XCTAssertEqual(
                decide(input: info(.builtIn), output: info(.bluetooth), bluetoothPresent: present),
                .allowed,
                "\(String(describing: present))"
            )
            XCTAssertEqual(
                decide(input: info(.bluetooth), output: info(.builtIn), bluetoothPresent: present),
                .refused(.bluetoothInput),
                "\(String(describing: present))"
            )
        }
    }

    func testTheInputIsDecidedBeforeTheConnectedBluetoothDevices() {
        XCTAssertEqual(
            decide(apple: true, input: info(.bluetooth), output: info(.builtIn), bluetoothPresent: true),
            .refused(.bluetoothInput)
        )
        XCTAssertEqual(
            decide(apple: true, inputID: 0, input: nil, output: info(.builtIn), bluetoothPresent: true),
            .refused(.noInput)
        )
    }

    func testBluetoothPresenceFromAPoll() {
        XCTAssertEqual(
            ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(bluetoothDeviceIDs: [60], everyTransportRead: false),
            true,
            "a Bluetooth device the poll read is connected, whatever else it could not read"
        )
        XCTAssertEqual(
            ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(bluetoothDeviceIDs: [], everyTransportRead: true),
            false
        )
        XCTAssertNil(
            ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(bluetoothDeviceIDs: [], everyTransportRead: false),
            "a device whose transport was not read could be Bluetooth"
        )
    }

    func testBluetoothPresenceFromAnUncachedList() {
        XCTAssertEqual(
            ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(listedTransports: [.builtIn, .bluetoothLE]),
            true
        )
        XCTAssertEqual(
            ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(listedTransports: [.builtIn, .aggregate, .usb]),
            false
        )
        XCTAssertNil(ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(listedTransports: nil))
        XCTAssertNil(
            ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(listedTransports: [.builtIn, nil]),
            "a listed device whose transport was not read could be Bluetooth"
        )
        XCTAssertEqual(
            ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(listedTransports: [nil, .bluetooth]),
            true,
            "a Bluetooth device the same read found decides it"
        )
    }

    // MARK: Publisher output

    private func decide(
        apple: Bool = false,
        input: AudioDeviceTransportInfo?,
        output: AudioDeviceTransportInfo?,
        publisherOutput: PublisherOutputChoice
    ) -> ProcessedMicrophoneSourceDecision {
        ProcessedMicrophoneSourcePolicy.decide(
            usesVoiceProcessing: apple,
            inputDeviceID: 42,
            input: input,
            output: output,
            bluetoothDevicePresent: false,
            publisherOutput: publisherOutput
        )
    }

    func testABoundPublisherOutputAllowsABluetoothDefaultOutputInDeviceBoundModes() {
        XCTAssertEqual(
            decide(input: info(.builtIn), output: info(.bluetooth), publisherOutput: .device(60, info(.builtIn))),
            .allowed
        )
    }

    func testEveryModeRefusesWithoutAnOutputThePublisherMayBeBoundTo() {
        for apple in [false, true] {
            XCTAssertEqual(
                decide(
                    apple: apple,
                    input: info(.builtIn),
                    output: info(.usb),
                    publisherOutput: .refused(.noNonBluetoothOutput)
                ),
                .refused(.noNonBluetoothOutput),
                "apple \(apple)"
            )
        }
    }

    func testUnreadOutputsWaitLikeAnUnreadTransport() {
        XCTAssertEqual(
            decide(input: info(.builtIn), output: info(.bluetooth), publisherOutput: .refused(.outputsNotRead)),
            .refused(.transportNotRead)
        )
    }

    func testTheInputAndTheVoiceProcessingOutputAreDecidedFirst() {
        XCTAssertEqual(
            decide(input: info(.bluetooth), output: info(.builtIn), publisherOutput: .refused(.noNonBluetoothOutput)),
            .refused(.bluetoothInput)
        )
        XCTAssertEqual(
            decide(apple: true, input: info(.builtIn), output: info(.bluetooth), publisherOutput: .refused(.noNonBluetoothOutput)),
            .refused(.bluetoothOutputForVoiceProcessing)
        )
    }

    func testRefusalReportsWhetherBluetoothIsInvolved() {
        XCTAssertTrue(ProcessedMicrophoneRefusal.bluetoothInput.involvesBluetooth)
        XCTAssertTrue(ProcessedMicrophoneRefusal.bluetoothOutputForVoiceProcessing.involvesBluetooth)
        XCTAssertTrue(ProcessedMicrophoneRefusal.noNonBluetoothOutput.involvesBluetooth)
        XCTAssertTrue(VoiceProcessingDeviceCheck.refused(.noNonBluetoothOutput).concernsOutput)
        XCTAssertFalse(ProcessedMicrophoneRefusal.noInput.involvesBluetooth)
        XCTAssertFalse(ProcessedMicrophoneRefusal.transportNotRead.involvesBluetooth)
    }
}

final class ProcessedMicrophonePlanTests: XCTestCase {
    private typealias Conditions = ProcessedMicrophonePlan.Conditions

    private func conditions(
        enabled: Bool = true,
        published: Bool = true,
        inUse: Bool = true,
        processingWanted: Bool? = nil,
        engineRunning: Bool = false,
        engineIsStale: Bool = false,
        publishing: Bool = false,
        pendingTeardown: Bool = false,
        decision: ProcessedMicrophoneSourceDecision = .allowed,
        holding: Bool = false,
        startsHeld: Bool = false,
        outputRetry: PublisherOutputRetry.Gate = .open
    ) -> Conditions {
        Conditions(
            enabled: enabled,
            published: published,
            inUse: inUse,
            processingWanted: processingWanted ?? inUse,
            engineRunning: engineRunning,
            engineIsStale: engineIsStale,
            publishing: publishing,
            pendingTeardown: pendingTeardown,
            decision: decision,
            holding: holding,
            startsHeld: startsHeld || holding,
            outputRetry: outputRetry
        )
    }

    private let decisions: [ProcessedMicrophoneSourceDecision] = [
        .allowed,
        .refused(.noInput),
        .refused(.transportNotRead),
        .refused(.bluetoothInput),
        .refused(.bluetoothOutputForVoiceProcessing),
        .refused(.bluetoothDevicePresentForVoiceProcessing)
    ]

    private let outputRetries: [PublisherOutputRetry.Gate] = [.open, .spaced, .exhausted]

    /// Every combination of conditions, for the invariants.
    private var everyCondition: [Conditions] {
        var result: [Conditions] = []
        let flags = [false, true]
        for enabled in flags {
            for published in flags {
                for inUse in flags {
                    for wanted in flags {
                        for running in flags {
                            for stale in flags {
                                for publishing in flags {
                                    for teardown in flags {
                                        for holding in flags {
                                            for startsHeld in flags {
                                                for decision in decisions {
                                                    for outputRetry in outputRetries {
                                                        result.append(Conditions(
                                                            enabled: enabled,
                                                            published: published,
                                                            inUse: inUse,
                                                            processingWanted: wanted,
                                                            engineRunning: running,
                                                            engineIsStale: stale,
                                                            publishing: publishing,
                                                            pendingTeardown: teardown,
                                                            decision: decision,
                                                            holding: holding,
                                                            startsHeld: startsHeld,
                                                            outputRetry: outputRetry
                                                        ))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: Invariants

    func testNeverTearsDownWhileInUse() {
        for condition in everyCondition where condition.inUse {
            XCTAssertNotEqual(
                ProcessedMicrophonePlan.next(condition),
                .completeTeardown,
                "\(condition)"
            )
        }
    }

    func testNeverActsWhileHolding() {
        for condition in everyCondition where condition.holding {
            XCTAssertEqual(ProcessedMicrophonePlan.next(condition), .none, "\(condition)")
        }
    }

    func testRefusalNeverTearsDownOrStartsAnything() {
        for condition in everyCondition where condition.enabled && condition.decision != .allowed {
            let action = ProcessedMicrophonePlan.next(condition)
            XCTAssertTrue(
                action == .none || action == .stopProcessingKeepPublication,
                "\(condition) -> \(action)"
            )
        }
    }

    /// Engines whose output retries ended are the exception: the start that
    /// ended them never started its publisher, so they render nothing, and
    /// nothing is issued for them until the user retries or the output
    /// changes.
    func testNeverKeepsEnginesRunningWithoutPublication() {
        for condition in everyCondition
        where !condition.holding && condition.engineRunning && !condition.published
            && condition.outputRetry != .exhausted {
            let action = ProcessedMicrophonePlan.next(condition)
            XCTAssertTrue(
                action == .stopProcessingKeepPublication || action == .completeTeardown,
                "\(condition) -> \(action)"
            )
        }
    }

    // MARK: Cases

    func testRunningAppleEngineStopsAfterTheWindowWhenABluetoothDeviceAppears() {
        let appeared = ProcessedMicrophoneSourceDecision.refused(.bluetoothDevicePresentForVoiceProcessing)
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(engineRunning: true, decision: appeared, holding: true)),
            .none,
            "the window armed for the arriving device holds the stop"
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(engineRunning: true, decision: appeared, startsHeld: true)),
            .stopProcessingKeepPublication,
            "a stops-only release stops it"
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(engineRunning: true, decision: appeared)),
            .stopProcessingKeepPublication,
            "so does a full release"
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(decision: appeared)),
            .none,
            "and nothing starts again while the device is connected"
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(published: false, inUse: false, decision: appeared)),
            .none,
            "nor is anything published"
        )
    }

    func testInUseWithRefusedDecisionAndRunningEngineStopsProcessingOnly() {
        for refusal in [
            ProcessedMicrophoneRefusal.bluetoothInput,
            .bluetoothOutputForVoiceProcessing,
            .bluetoothDevicePresentForVoiceProcessing
        ] {
            XCTAssertEqual(
                ProcessedMicrophonePlan.next(conditions(
                    inUse: true,
                    engineRunning: true,
                    decision: .refused(refusal)
                )),
                .stopProcessingKeepPublication
            )
        }
    }

    func testRefusedWithoutPublicationDoesNothing() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                published: false,
                inUse: false,
                decision: .refused(.bluetoothInput)
            )),
            .none
        )
    }

    func testRefusedWhilePublishedWithEnginesStoppedDoesNothing() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                inUse: true,
                decision: .refused(.bluetoothInput)
            )),
            .none
        )
    }

    func testPendingTeardownCompletesOnceIdleAndReleased() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                enabled: false,
                inUse: false,
                pendingTeardown: true
            )),
            .completeTeardown
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                enabled: false,
                inUse: false,
                engineRunning: true,
                pendingTeardown: true
            )),
            .completeTeardown
        )
    }

    func testPendingTeardownWaitsForConsumerAndStopsEnginesMeanwhile() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                enabled: false,
                inUse: true,
                engineRunning: true,
                pendingTeardown: true
            )),
            .stopProcessingKeepPublication
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                enabled: false,
                inUse: true,
                pendingTeardown: true
            )),
            .none
        )
    }

    func testPendingTeardownWaitsForTheQuietWindow() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                enabled: false,
                inUse: false,
                pendingTeardown: true,
                holding: true
            )),
            .none
        )
    }

    func testDisabledWithoutOwedTeardownLeavesPublicationAlone() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(enabled: false, inUse: false)),
            .none
        )
    }

    func testStartsPipelineWhenAllowedAndNotPublished() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(published: false, inUse: false)),
            .startPipeline
        )
    }

    func testDoesNotRestartPipelineWhilePublishing() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(published: false, inUse: false, publishing: true)),
            .none
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(published: true, inUse: true, publishing: true)),
            .none
        )
    }

    func testStartsProcessingWhenConsumerOpensThePublishedDevice() {
        XCTAssertEqual(ProcessedMicrophonePlan.next(conditions(inUse: true)), .startProcessing)
        XCTAssertEqual(ProcessedMicrophonePlan.next(conditions(inUse: false)), .none)
    }

    func testStopsProcessingOnceIdle() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(inUse: false, engineRunning: true)),
            .stopProcessingKeepPublication
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                inUse: false,
                processingWanted: true,
                engineRunning: true
            )),
            .none
        )
    }

    func testRestartsStaleEnginesOnlyWhileWanted() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(engineRunning: true, engineIsStale: true)),
            .restartProcessing
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                inUse: false,
                engineRunning: true,
                engineIsStale: true
            )),
            .stopProcessingKeepPublication
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(engineRunning: true)),
            .none
        )
    }

    func testStopsEnginesWhenHaltedWithoutTeardown() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(enabled: false, engineRunning: true)),
            .stopProcessingKeepPublication
        )
    }

    // MARK: Output retries

    func testOutputRetriesThatEndedIssueNothingAtAll() {
        for condition in everyCondition where condition.outputRetry == .exhausted {
            XCTAssertEqual(ProcessedMicrophonePlan.next(condition), .none, "\(condition)")
        }
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(enabled: false, engineRunning: true, outputRetry: .exhausted)),
            .none,
            "not even the stop a halted state would issue"
        )
    }

    func testASpacedOutputRetryHoldsStartsAsAStopsOnlyReleaseDoes() {
        for condition in everyCondition where condition.outputRetry == .spaced {
            var stopsOnly = condition
            stopsOnly.outputRetry = .open
            stopsOnly.startsHeld = true
            XCTAssertEqual(ProcessedMicrophonePlan.next(condition), ProcessedMicrophonePlan.next(stopsOnly), "\(condition)")
        }
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(engineRunning: true, engineIsStale: true, outputRetry: .spaced)),
            .stopProcessingKeepPublication,
            "what the failed start left is released, and the start waits for the spacing"
        )
        XCTAssertEqual(ProcessedMicrophonePlan.next(conditions(outputRetry: .spaced)), .none)
        XCTAssertEqual(ProcessedMicrophonePlan.next(conditions(outputRetry: .open)), .startProcessing)
    }

    // MARK: The app's own picker

    private func pick(
        engaged: Bool = true,
        _ transport: AudioDeviceTransport?,
        changeMayBeUnderWay: Bool = false,
        bluetoothDevicePresent: Bool? = false
    ) -> ProcessedMicrophonePlan.DefaultPick {
        ProcessedMicrophonePlan.beforeDefaultWrite(
            voiceProcessingEngaged: engaged,
            pickedTransport: transport,
            changeMayBeUnderWay: changeMayBeUnderWay,
            bluetoothDevicePresent: bluetoothDevicePresent
        )
    }

    func testPickingADeviceThatCouldInvolveBluetoothStopsVoiceProcessingBeforeTheDefaultWrite() {
        for transport: AudioDeviceTransport? in [.bluetooth, .bluetoothLE, .aggregate, .unknown, nil] {
            XCTAssertEqual(
                pick(transport),
                .stopVoiceProcessingThenWrite,
                "a Bluetooth device, an aggregate's sub-devices, an unclassified transport and an unlisted device: \(String(describing: transport))"
            )
        }
    }

    func testAPickThatCouldInvolveBluetoothIsRefusedWhileAChangeMayBeUnderWay() {
        for transport: AudioDeviceTransport? in [.bluetooth, .bluetoothLE, .aggregate, .unknown, nil] {
            XCTAssertEqual(pick(transport, changeMayBeUnderWay: true), .refuse, "\(String(describing: transport))")
            XCTAssertEqual(
                pick(transport, bluetoothDevicePresent: true),
                .refuse,
                "a connected Bluetooth device keeps the engines only while its window holds: \(String(describing: transport))"
            )
            XCTAssertEqual(pick(transport, bluetoothDevicePresent: nil), .refuse, "\(String(describing: transport))")
        }
    }

    func testPickingAWiredDeviceWritesWithoutStoppingVoiceProcessing() {
        let known: [AudioDeviceTransport] = [
            .builtIn, .virtual, .pci, .usb, .fireWire, .hdmi, .displayPort, .airPlay, .avb, .thunderbolt,
            .continuityCapture
        ]
        for transport in known {
            XCTAssertEqual(pick(transport), .write, "\(transport)")
            XCTAssertEqual(
                pick(transport, changeMayBeUnderWay: true, bluetoothDevicePresent: true),
                .write,
                "the evaluation after the window rebuilds for it: \(transport)"
            )
        }
    }

    func testNothingIsStoppedOrRefusedWithoutVoiceProcessingEngaged() {
        for transport: AudioDeviceTransport? in [.bluetooth, .aggregate, nil, .builtIn] {
            for changeMayBeUnderWay in [false, true] {
                for present: Bool? in [false, true, nil] {
                    XCTAssertEqual(
                        pick(engaged: false, transport, changeMayBeUnderWay: changeMayBeUnderWay, bluetoothDevicePresent: present),
                        .write,
                        "\(String(describing: transport)) \(changeMayBeUnderWay) \(String(describing: present))"
                    )
                }
            }
        }
    }

    // MARK: Starts held

    func testStartsHeldPlanNeverStartsRestartsOrPublishes() {
        let admitted: [ProcessedMicrophonePlan.Action] = [.none, .stopProcessingKeepPublication, .completeTeardown]
        for condition in everyCondition where condition.startsHeld {
            let action = ProcessedMicrophonePlan.next(condition)
            XCTAssertTrue(admitted.contains(action), "\(condition) -> \(action)")
        }

        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(published: false, inUse: false, startsHeld: true)),
            .none,
            "the pipeline, and with it publication, waits"
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(inUse: true, startsHeld: true)),
            .none,
            "processing does not start for a consumer yet"
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(engineRunning: true, engineIsStale: true, startsHeld: true)),
            .stopProcessingKeepPublication,
            "a restart stops now and starts once starts are admitted"
        )
    }

    func testStartsHeldPlanStillCompletesOwedTeardownWhenIdle() {
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                enabled: false,
                inUse: false,
                pendingTeardown: true,
                startsHeld: true
            )),
            .completeTeardown
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                enabled: false,
                inUse: true,
                engineRunning: true,
                pendingTeardown: true,
                startsHeld: true
            )),
            .stopProcessingKeepPublication,
            "a consumer still holds the device, so only the engines stop"
        )
        XCTAssertEqual(
            ProcessedMicrophonePlan.next(conditions(
                engineRunning: true,
                decision: .refused(.bluetoothInput),
                startsHeld: true
            )),
            .stopProcessingKeepPublication
        )
    }

    func testStartsHeldPlanKeepsEveryStopTheUnheldPlanWouldIssue() {
        for condition in everyCondition where condition.startsHeld && !condition.holding {
            var unheldCondition = condition
            unheldCondition.startsHeld = false
            let held = ProcessedMicrophonePlan.next(condition)
            switch ProcessedMicrophonePlan.next(unheldCondition) {
            case .none:
                XCTAssertEqual(held, .none, "\(condition)")
            case .stopProcessingKeepPublication, .restartProcessing:
                XCTAssertEqual(held, .stopProcessingKeepPublication, "\(condition)")
            case .completeTeardown:
                XCTAssertEqual(held, .completeTeardown, "\(condition)")
            case .startPipeline, .startProcessing:
                XCTAssertEqual(held, .none, "\(condition)")
            }
        }
    }
}
