import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// How the published device's in-use read is interpreted, and the order of
/// its Core Audio calls through a fake that never reaches coreaudiod. Every
/// destroy of the published aggregate device is refused while it reads as in
/// use, and a publication stops before its next lifecycle call once the
/// quiet window's generation has advanced.
final class PublicProcessedMicrophoneDeviceTests: XCTestCase {
    private let staleDevice: AudioObjectID = 900
    private let published = FakeHALLifecycleCalls.publishedAggregateID
    private let publishedTap = FakeHALLifecycleCalls.publishedTapID

    override func tearDown() {
        HALLifecycleLog.observer = nil
        super.tearDown()
    }

    func testARunningDeviceIsInUse() {
        XCTAssertTrue(PublicProcessedMicrophoneDevice.readsAsRunningSomewhere(status: noErr, value: 1))
        XCTAssertFalse(PublicProcessedMicrophoneDevice.readsAsRunningSomewhere(status: noErr, value: 0))
    }

    func testIsRunningSomewhereReadFailureRefusesDestroy() {
        for status in [
            kAudioHardwareUnspecifiedError,
            kAudioHardwareNotRunningError,
            kAudioHardwareUnknownPropertyError,
            kAudioHardwareBadDeviceError,
            kAudioHardwareNotReadyError
        ] {
            XCTAssertTrue(
                PublicProcessedMicrophoneDevice.readsAsRunningSomewhere(status: status, value: 0),
                "a read that failed with \(status) counts as in use"
            )
        }
    }

    func testADeviceThatIsAlreadyGoneIsNotInUse() {
        XCTAssertFalse(
            PublicProcessedMicrophoneDevice.readsAsRunningSomewhere(status: kAudioHardwareBadObjectError, value: 0)
        )
    }

    // MARK: An earlier run's device

    func testAnEarlierRunsDeviceInUseIsWatchedAndReadUntilItsRemovalCompletes() throws {
        let hal = FakeHALLifecycleCalls()
        hal.listedDevices = [(staleDevice, PublicProcessedMicrophoneDevice.aggregateDeviceUID)]
        hal.isRunningSomewhereRead = (noErr, 1)
        let device = PublicProcessedMicrophoneDevice(halCalls: hal, holdGeneration: LifecycleHoldGeneration())

        XCTAssertThrowsError(try device.removeStalePublishedDevice()) { error in
            guard case .publishedDeviceInUse? = error as? PublicProcessedMicrophoneDeviceError else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(hal.lifecycleCalls, [], "nothing is destroyed under a consumer")
        XCTAssertEqual(
            hal.listenerSelectors(on: staleDevice),
            [kAudioDevicePropertyDeviceIsRunningSomewhere],
            "the refused device is watched"
        )
        XCTAssertTrue(device.isMonitoringInUse)
        XCTAssertTrue(device.isInUse, "the refused device itself is read, not an unknown ID")

        // The consumer lets go.
        var reported: [Bool] = []
        device.onInUseChanged = { reported.append($0) }
        hal.isRunningSomewhereRead = (noErr, 0)
        hal.fireListener(deviceID: staleDevice, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        XCTAssertEqual(reported, [false])
        XCTAssertFalse(device.isInUse)

        let before = hal.calls.count
        XCTAssertTrue(try device.removeStalePublishedDevice())
        XCTAssertEqual(
            Array(hal.calls.dropFirst(before)),
            [
                .readIsRunningSomewhere(staleDevice),
                .destroyAggregate(staleDevice),
                .removePropertyListener(staleDevice)
            ],
            "in use is read immediately before the destroy, and the watch ends once the device is gone"
        )
        XCTAssertFalse(device.isMonitoringInUse)
    }

    func testAnEarlierRunsDeviceThatLeftTheListIsNoLongerWatched() {
        let hal = FakeHALLifecycleCalls()
        hal.listedDevices = [(staleDevice, PublicProcessedMicrophoneDevice.aggregateDeviceUID)]
        hal.isRunningSomewhereRead = (noErr, 1)
        let device = PublicProcessedMicrophoneDevice(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        XCTAssertThrowsError(try device.removeStalePublishedDevice())
        XCTAssertTrue(device.isMonitoringInUse)

        hal.listedDevices = []
        XCTAssertEqual(try? device.removeStalePublishedDevice(), false, "nothing was destroyed")
        XCTAssertEqual(hal.lifecycleCalls, [])
        XCTAssertTrue(hal.listenerSelectors(on: staleDevice).isEmpty)
        XCTAssertFalse(device.isMonitoringInUse)
        XCTAssertFalse(device.isInUse)
    }

    func testAnEarlierRunsDeviceIsNotSearchedForWhenTheDeviceListCannotBeRead() {
        let hal = FakeHALLifecycleCalls()
        hal.listedDevices = [(staleDevice, PublicProcessedMicrophoneDevice.aggregateDeviceUID)]
        hal.deviceListStatus = kAudioHardwareNotRunningError
        let device = PublicProcessedMicrophoneDevice(halCalls: hal, holdGeneration: LifecycleHoldGeneration())

        XCTAssertThrowsError(try device.removeStalePublishedDevice()) { error in
            guard case .cleanupFailed? = error as? PublicProcessedMicrophoneDeviceError else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(hal.calls, [], "a failed list read is not an absent device")
    }

    // MARK: The publication

    func testPublicationIsValidatedThroughTheSeam() throws {
        let hal = FakeHALLifecycleCalls()
        let device = PublicProcessedMicrophoneDevice(halCalls: hal, holdGeneration: LifecycleHoldGeneration())

        let publication = try device.start()
        XCTAssertEqual(publication.deviceID, published)
        XCTAssertEqual(publication.tapID, publishedTap)
        XCTAssertTrue(device.isPublished)

        hal.inputStreamCountRead = (noErr, 0)
        XCTAssertFalse(device.isPublished, "an aggregate device without input streams is not a publication")
        hal.inputStreamCountRead = (noErr, 1)
        hal.deviceListStatus = kAudioHardwareUnspecifiedError
        XCTAssertFalse(device.isPublished, "nor one the device list cannot confirm")
        hal.deviceListStatus = noErr
        hal.listedDevices = []
        XCTAssertFalse(device.isPublished, "nor one no longer listed under its UID")
    }

    func testAPublicationWithoutInputStreamsIsRolledBackBeforeAnyIO() {
        let hal = FakeHALLifecycleCalls()
        hal.inputStreamCountRead = (noErr, 0)
        let device = PublicProcessedMicrophoneDevice(halCalls: hal, holdGeneration: LifecycleHoldGeneration())

        XCTAssertThrowsError(try device.start()) { error in
            guard case .aggregateHasNoInputStreams? = error as? PublicProcessedMicrophoneDeviceError else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createProcessTap, .createAggregate, .destroyAggregate(published), .destroyProcessTap(publishedTap)],
            "no permission probe IOProc, and the tap goes only after its aggregate device"
        )
    }

    func testWithdrawalReadsInUseThenDestroysThenRemovesTheListenerThenTheTap() throws {
        let hal = FakeHALLifecycleCalls()
        let device = PublicProcessedMicrophoneDevice(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        try device.start()
        XCTAssertEqual(hal.listenerSelectors(on: published), [kAudioDevicePropertyDeviceIsRunningSomewhere])
        let before = hal.calls.count

        try device.stop()

        XCTAssertEqual(
            Array(hal.calls.dropFirst(before)),
            [
                .readIsRunningSomewhere(published),
                .destroyAggregate(published),
                .removePropertyListener(published),
                .destroyProcessTap(publishedTap)
            ]
        )
        XCTAssertFalse(device.holdsPublication)
        XCTAssertFalse(device.isMonitoringInUse)
    }

    func testWithdrawalWhileInUseTouchesNothingAndKeepsTheListener() throws {
        let hal = FakeHALLifecycleCalls()
        let device = PublicProcessedMicrophoneDevice(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        try device.start()
        let before = hal.calls.count

        hal.isRunningSomewhereRead = (kAudioHardwareNotRunningError, 0)
        XCTAssertThrowsError(try device.stop()) { error in
            guard case .publishedDeviceInUse? = error as? PublicProcessedMicrophoneDeviceError else {
                return XCTFail("\(error)")
            }
        }

        XCTAssertEqual(
            Array(hal.calls.dropFirst(before)),
            [.readIsRunningSomewhere(published)],
            "a failed in-use read refuses the destroy"
        )
        XCTAssertTrue(device.holdsPublication)
        XCTAssertEqual(hal.listenerSelectors(on: published), [kAudioDevicePropertyDeviceIsRunningSomewhere])

        // Released at the end of the test, once nothing holds it.
        hal.isRunningSomewhereRead = (noErr, 0)
        try device.stop()
    }

    func testForgetAfterAServiceRestartMakesNoHALCall() throws {
        let hal = FakeHALLifecycleCalls()
        let device = PublicProcessedMicrophoneDevice(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        try device.start()
        let before = hal.calls.count

        device.forgetAfterServiceRestart()
        XCTAssertEqual(hal.calls.count, before)
        XCTAssertFalse(device.holdsPublication)
        XCTAssertFalse(device.isInUse, "a forgotten publication reads nothing")

        // The published UID is still listed under the old ID: the next
        // withdrawal finds it by UID and reads it before destroying it.
        try device.stop()
        XCTAssertEqual(
            Array(hal.calls.dropFirst(before)),
            [.readIsRunningSomewhere(published), .destroyAggregate(published)],
            "no listener removal and no tap destroy under IDs the restart may have reissued"
        )
    }

    // MARK: A quiet window arming during the publication

    /// A listener advances the generation while `call` waits in coreaudiod.
    private struct InterruptionPoint {
        let call: FakeHALLifecycleCalls.Call
        /// The calls the publication has made by then, that one included.
        let made: [FakeHALLifecycleCalls.Call]
        /// The object and the held-back call its `interrupt` line names.
        let interrupt: String
        /// What the rollback after the window calls, reads included.
        let rollback: [FakeHALLifecycleCalls.Call]
    }

    private var interruptionPoints: [InterruptionPoint] {
        let aggregate = published
        let tap = publishedTap
        let withdrawal: [FakeHALLifecycleCalls.Call] = [
            .readIsRunningSomewhere(aggregate), .destroyAggregate(aggregate), .destroyProcessTap(tap)
        ]
        return [
            InterruptionPoint(
                call: .createProcessTap,
                made: [.createProcessTap],
                interrupt: "processed-microphone-aggregate interrupt id=0 transport=- status=0 gen=0 reason=before-create tap-uid=fake-tap",
                rollback: [.destroyProcessTap(tap)]
            ),
            InterruptionPoint(
                call: .createAggregate,
                made: [.createProcessTap, .createAggregate],
                interrupt: "processed-microphone-probe-ioproc interrupt id=\(aggregate) transport=- status=0 gen=0 reason=before-create",
                rollback: withdrawal
            ),
            InterruptionPoint(
                call: .createIOProc(aggregate),
                made: [.createProcessTap, .createAggregate, .createIOProc(aggregate)],
                interrupt: "processed-microphone-probe-ioproc interrupt id=\(aggregate) transport=- status=0 gen=0 reason=before-start",
                rollback: [.destroyIOProc(aggregate)] + withdrawal
            ),
            InterruptionPoint(
                call: .start(aggregate),
                made: [.createProcessTap, .createAggregate, .createIOProc(aggregate), .start(aggregate)],
                interrupt: "processed-microphone-probe-ioproc interrupt id=\(aggregate) transport=- status=0 gen=0 reason=before-stop",
                rollback: [.stop(aggregate), .destroyIOProc(aggregate)] + withdrawal
            ),
            InterruptionPoint(
                call: .stop(aggregate),
                made: [
                    .createProcessTap, .createAggregate, .createIOProc(aggregate), .start(aggregate), .stop(aggregate)
                ],
                interrupt: "processed-microphone-probe-ioproc interrupt id=\(aggregate) transport=- status=0 gen=0 reason=before-destroy",
                rollback: [.destroyIOProc(aggregate)] + withdrawal
            )
        ]
    }

    /// A fake that advances `generation` inside the first call equal to
    /// `call`, and the hal-lifecycle lines written from then on.
    private func makeDevice(
        advancingIn call: FakeHALLifecycleCalls.Call?
    ) -> (hal: FakeHALLifecycleCalls, generation: LifecycleHoldGeneration, device: PublicProcessedMicrophoneDevice, lines: HALLineLog) {
        let hal = FakeHALLifecycleCalls()
        let generation = LifecycleHoldGeneration()
        var advanced = false
        hal.onCall = { made in
            if made == call, !advanced {
                advanced = true
                generation.advance()
            }
        }
        let lines = HALLineLog()
        HALLifecycleLog.observer = { lines.append($0) }
        return (hal, generation, PublicProcessedMicrophoneDevice(halCalls: hal, holdGeneration: generation), lines)
    }

    private func assertInterrupted<T>(
        _ body: @autoclosure () throws -> T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), message, file: file, line: line) { error in
            XCTAssertTrue(error is PublicProcessedMicrophoneDevice.Interrupted, "\(error) \(message)", file: file, line: line)
        }
    }

    func testAPublicationStopsBeforeItsNextCallOnceTheGenerationAdvancesAndRollsNothingBackInsideTheWindow() throws {
        for point in interruptionPoints {
            let (hal, generation, device, lines) = makeDevice(advancingIn: point.call)

            assertInterrupted(try device.start(), "\(point.call)")

            XCTAssertEqual(
                hal.calls,
                point.made,
                "\(point.call): no create or start after the advance, and no stop, destroy or rollback either"
            )
            XCTAssertFalse(device.holdsPublication, "\(point.call): what is kept is not a publication")
            XCTAssertFalse(device.isPublished, "\(point.call)")
            XCTAssertNil(device.publishedDevice, "\(point.call)")
            XCTAssertFalse(device.isMonitoringInUse, "\(point.call): no in-use listener for a device that is not published")
            XCTAssertTrue(device.keepsInterruptedPublication, "\(point.call): it is remembered for the release")

            let interrupts = lines.values.filter { $0.contains(" interrupt ") }
            XCTAssertEqual(interrupts.count, 1, "\(point.call): \(interrupts)")
            XCTAssertTrue(
                interrupts.first?.hasPrefix(point.interrupt) == true,
                "\(point.call): \(interrupts)"
            )
            for line in lines.values where line.contains("-begin ") {
                XCTAssertEqual(
                    AudioStateHarness.field("gen", of: line),
                    "0",
                    "every begin line carries the generation the publication was issued in: \(line)"
                )
            }

            // The owner's release after the window rolls back what was kept,
            // in LifecycleTeardown's order and under the in-use rule.
            let before = hal.calls.count
            try device.stop(holdToken: generation.current)
            XCTAssertEqual(Array(hal.calls.dropFirst(before)), point.rollback, "\(point.call)")
            XCTAssertFalse(device.keepsInterruptedPublication, "\(point.call)")
            XCTAssertTrue(hal.listedDevices.isEmpty, "\(point.call): the half-made device is gone")
        }
    }

    func testAnAdvanceBeforeTheFirstCallCreatesNothingAndKeepsNothing() {
        let (hal, generation, device, lines) = makeDevice(advancingIn: nil)
        hal.onRead = { read in
            // The PID translation that precedes the tap's create waits in
            // coreaudiod while a listener advances the generation.
            if read == .processObjectID {
                generation.advance()
            }
        }

        assertInterrupted(try device.start())

        XCTAssertEqual(hal.calls, [])
        XCTAssertEqual(
            lines.values,
            ["processed-microphone-tap interrupt id=0 transport=- status=0 gen=0 reason=before-create"]
        )
        XCTAssertFalse(device.keepsInterruptedPublication, "nothing was created, so nothing is owed")
    }

    func testAnAdvanceInsideThePublicationsLastCallLeavesItPublished() throws {
        let (hal, generation, device, lines) = makeDevice(advancingIn: .destroyIOProc(published))

        XCTAssertEqual(try device.start().deviceID, published)

        XCTAssertEqual(generation.current, 1)
        XCTAssertTrue(device.isPublished, "no lifecycle call is left to hold back")
        XCTAssertFalse(device.keepsInterruptedPublication)
        XCTAssertEqual(hal.listenerSelectors(on: published), [kAudioDevicePropertyDeviceIsRunningSomewhere])
        XCTAssertFalse(lines.values.contains { $0.contains(" interrupt ") })
        XCTAssertTrue(
            lines.values.allSatisfy { AudioStateHarness.field("gen", of: $0) == "0" },
            "every line carries the generation the publication was issued in: \(lines.values)"
        )
    }

    func testAFailedProbeStartIsNotUnwoundInsideTheWindow() throws {
        let (hal, generation, device, lines) = makeDevice(advancingIn: .start(published))
        // The start waited in coreaudiod long enough for a window to arm,
        // then failed, and the device reports the IO running anyway.
        hal.startStatus = kAudioHardwareUnspecifiedError
        hal.isRunningRead = (noErr, 1)

        assertInterrupted(try device.start(), "a failure while a window arms counts as interrupted")

        XCTAssertEqual(
            hal.calls,
            [
                .createProcessTap, .createAggregate, .createIOProc(published), .start(published),
                .readIsRunning(published)
            ],
            "the rollback reads, and stops before its first stop or destroy"
        )
        XCTAssertEqual(
            lines.values.last,
            "processed-microphone-probe-ioproc interrupt id=\(published) transport=- status=0 gen=0 reason=before-stop aggregate-uid=\(PublicProcessedMicrophoneDevice.aggregateDeviceUID)"
        )
        XCTAssertTrue(device.keepsInterruptedPublication)

        let before = hal.calls.count
        try device.stop(holdToken: generation.current)
        XCTAssertEqual(
            Array(hal.calls.dropFirst(before)),
            [
                .stop(published), .destroyIOProc(published),
                .readIsRunningSomewhere(published), .destroyAggregate(published), .destroyProcessTap(publishedTap)
            ],
            "IO that read running after the failed start is stopped before its IOProc is destroyed"
        )
        XCTAssertTrue(
            lines.values.contains {
                $0.hasPrefix("processed-microphone-probe-ioproc stop-begin ") && $0.contains("gen=1 reason=failed-start")
            },
            "\(lines.values)"
        )
    }

    func testTheRollbackNeverDestroysTheKeptDeviceWhileAProcessHasItOpen() throws {
        let (hal, generation, device, _) = makeDevice(advancingIn: .start(published))
        assertInterrupted(try device.start())
        XCTAssertFalse(device.isInUse, "the probe's own IO is not a consumer")
        XCTAssertFalse(
            hal.calls.contains(.readIsRunningSomewhere(published)),
            "and the device is not read while it could only read as running"
        )
        // A consuming app opened the half-made device during the window.
        hal.isRunningSomewhereRead = (noErr, 1)
        let before = hal.calls.count

        XCTAssertThrowsError(try device.stop(holdToken: generation.current)) { error in
            guard case .publishedDeviceInUse? = error as? PublicProcessedMicrophoneDeviceError else {
                return XCTFail("\(error)")
            }
        }

        XCTAssertEqual(
            Array(hal.calls.dropFirst(before)),
            [.stop(published), .destroyIOProc(published), .readIsRunningSomewhere(published)],
            "the probe goes, and in use is read immediately before a destroy that is then not made"
        )
        XCTAssertFalse(device.keepsInterruptedPublication, "what is left is the owner's owed teardown now")
        XCTAssertTrue(device.isInUse, "with the probe gone, the device itself is read")

        // The app lets go, and the owed teardown completes.
        hal.isRunningSomewhereRead = (noErr, 0)
        try device.stop()
        XCTAssertEqual(
            Array(hal.lifecycleCalls.suffix(2)),
            [.destroyAggregate(published), .destroyProcessTap(publishedTap)]
        )
    }

    func testARollbackAWindowInterruptsKeepsTheRestInOrderForTheNextRelease() throws {
        let (hal, generation, device, lines) = makeDevice(advancingIn: .start(published))
        assertInterrupted(try device.start())
        var advanced = false
        hal.onCall = { call in
            if call == .destroyIOProc(self.published), !advanced {
                advanced = true
                generation.advance()
            }
        }
        let before = hal.calls.count

        assertInterrupted(try device.stop(holdToken: generation.current))

        XCTAssertEqual(
            Array(hal.calls.dropFirst(before)),
            [.stop(published), .destroyIOProc(published)],
            "the aggregate device is neither read nor destroyed inside the window"
        )
        XCTAssertEqual(
            lines.values.last,
            "processed-microphone-aggregate interrupt-stop id=\(published) transport=- status=0 gen=1 reason=before-destroy aggregate-uid=\(PublicProcessedMicrophoneDevice.aggregateDeviceUID)"
        )
        XCTAssertTrue(device.keepsInterruptedPublication)

        let beforeRelease = hal.calls.count
        try device.stop(holdToken: generation.current)
        XCTAssertEqual(
            Array(hal.calls.dropFirst(beforeRelease)),
            [.readIsRunningSomewhere(published), .destroyAggregate(published), .destroyProcessTap(publishedTap)],
            "the tap goes only after its aggregate device, and nothing is called twice"
        )
    }

    func testTheNextPublicationReleasesWhatAnInterruptedOneKeptBeforeItCreatesAnything() throws {
        let (hal, _, device, _) = makeDevice(advancingIn: .createIOProc(published))
        assertInterrupted(try device.start())
        let before = hal.lifecycleCalls.count

        XCTAssertEqual(try device.start().deviceID, published)

        XCTAssertEqual(
            Array(hal.lifecycleCalls.dropFirst(before)),
            [
                .destroyIOProc(published), .destroyAggregate(published), .destroyProcessTap(publishedTap),
                .createProcessTap, .createAggregate,
                .createIOProc(published), .start(published), .stop(published), .destroyIOProc(published)
            ]
        )
        XCTAssertTrue(device.isPublished)
        XCTAssertFalse(device.keepsInterruptedPublication)
    }

    func testAServiceRestartForgetsWhatAnInterruptedPublicationKeptWithoutAHALCall() throws {
        let (hal, _, device, lines) = makeDevice(advancingIn: .start(published))
        assertInterrupted(try device.start())
        let before = hal.calls.count

        device.forgetAfterServiceRestart()

        XCTAssertEqual(hal.calls.count, before, "the probe is neither stopped nor destroyed under a reissued ID")
        XCTAssertFalse(device.keepsInterruptedPublication)
        XCTAssertEqual(
            lines.values.suffix(3).map { $0.components(separatedBy: " id=").first },
            [
                "processed-microphone-probe-ioproc forget",
                "processed-microphone-aggregate forget",
                "processed-microphone-tap forget"
            ]
        )
    }

    func testQuitReleasesWhatAnInterruptedPublicationKeptWhateverTheWindow() throws {
        let (hal, generation, device, lines) = makeDevice(advancingIn: .start(published))
        assertInterrupted(try device.start())
        generation.advance()
        let before = hal.calls.count
        let linesBefore = lines.values.count

        try device.stop(reason: HALLifecycleLog.quitReason)

        XCTAssertEqual(
            Array(hal.calls.dropFirst(before)),
            [
                .stop(published), .destroyIOProc(published),
                .readIsRunningSomewhere(published), .destroyAggregate(published), .destroyProcessTap(publishedTap)
            ]
        )
        for line in lines.values.dropFirst(linesBefore) {
            XCTAssertEqual(AudioStateHarness.field("gen", of: line), "-", line)
            XCTAssertEqual(AudioStateHarness.field("reason", of: line), "quit", line)
        }
    }
}
