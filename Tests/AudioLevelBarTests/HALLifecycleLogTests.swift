import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// The hal-lifecycle line format, and that every HAL lifecycle call the
/// meters make is written between a begin line and a result line that carry
/// the quiet window's generation. Nothing here reaches coreaudiod.
final class HALLifecycleLogTests: XCTestCase {
    private let timeout: TimeInterval = 5
    private let microphone: AudioDeviceID = 41

    override func tearDown() {
        HALLifecycleLog.observer = nil
        super.tearDown()
    }

    // MARK: Format

    func testBeginLineCarriesGeneration() {
        XCTAssertEqual(
            HALLifecycleLog.line(
                .microphoneIOProc,
                .startBegin,
                id: 41,
                transport: "builtIn",
                generation: 7
            ),
            "microphone-ioproc start-begin id=41 transport=builtIn gen=7"
        )
    }

    func testResultLineCarriesStatusThenGenerationThenReasonAndOutput() {
        XCTAssertEqual(
            HALLifecycleLog.line(
                .systemOutputIOProc,
                .stop,
                id: 400,
                transport: "usb",
                status: kAudioHardwareBadDeviceError,
                generation: 12,
                reason: HALLifecycleLog.unconfirmedStartReason,
                output: 500
            ),
            "system-output-ioproc stop id=400 transport=usb status=\(kAudioHardwareBadDeviceError) gen=12 reason=failed-start output=500"
        )
    }

    func testTheAppsOwnAggregateAndTapUIDsComeLast() {
        XCTAssertEqual(
            HALLifecycleLog.line(
                .systemOutputAggregate,
                .create,
                id: 400,
                transport: "builtIn",
                generation: 4,
                output: 500,
                aggregateUID: "io.github.yuhkis.audio-level-bar.tap.A",
                tapUID: "B"
            ),
            "system-output-aggregate create id=400 transport=builtIn status=0 gen=4 output=500 aggregate-uid=io.github.yuhkis.audio-level-bar.tap.A tap-uid=B"
        )
    }

    func testWorkTheWindowDoesNotHoldIsLoggedWithADash() {
        XCTAssertEqual(
            HALLifecycleLog.line(
                .processedMicrophoneTap,
                .destroyBegin,
                id: 300,
                generation: nil,
                reason: HALLifecycleLog.quitReason
            ),
            "processed-microphone-tap destroy-begin id=300 transport=- gen=- reason=quit"
        )
    }

    func testOnlyHALCallsHaveABeginOperation() {
        XCTAssertEqual(HALLifecycleLog.Operation.create.begin, .createBegin)
        XCTAssertEqual(HALLifecycleLog.Operation.prepare.begin, .prepareBegin)
        XCTAssertEqual(HALLifecycleLog.Operation.start.begin, .startBegin)
        XCTAssertEqual(HALLifecycleLog.Operation.stop.begin, .stopBegin)
        XCTAssertEqual(HALLifecycleLog.Operation.destroy.begin, .destroyBegin)
        for operation: HALLifecycleLog.Operation in [
            .refuse, .openUnverified, .interrupt, .interruptStop, .stall, .forget, .invalidate, .giveUp,
            .createBegin, .prepareBegin, .startBegin, .stopBegin, .destroyBegin
        ] {
            XCTAssertNil(operation.begin, "\(operation)")
        }
    }

    // MARK: Lines around the calls

    func testEveryMicrophoneMeterCallIsBetweenItsBeginAndResultLines() {
        let generation = generation(at: 3)
        let hal = observedFake()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let started = expectation(description: "started")
        meter.onEvent = { event in
            if event == .started(self.microphone) {
                started.fulfill()
            }
        }
        meter.start(deviceID: microphone)
        wait(for: [started], timeout: timeout)
        let stopped = expectation(description: "stopped")
        meter.stop { _ in stopped.fulfill() }
        wait(for: [stopped], timeout: timeout)

        XCTAssertEqual(hal.lifecycleCalls.count, 4)
        assertEveryCallIsBracketed(hal, generation: "3")
    }

    func testEverySystemOutputMeterCallIsBetweenItsBeginAndResultLines() {
        let generation = generation(at: 5)
        let hal = observedFake()
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: generation)
        let started = expectation(description: "started")
        meter.onStarted = { started.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [started], timeout: timeout)
        meter.stop()
        meter.lifecycleQueue.sync {}

        XCTAssertEqual(hal.lifecycleCalls.count, 8)
        assertEveryCallIsBracketed(hal, generation: "5")
    }

    func testSystemOutputLinesNameTheTapAndAggregateTheMeterCreated() {
        let hal = observedFake()
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        let started = expectation(description: "started")
        meter.onStarted = { started.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [started], timeout: timeout)
        meter.stop()
        meter.lifecycleQueue.sync {}

        let lines = hal.timeline.compactMap(\.lineText)
        let tapCreate = lines.first { $0.hasPrefix("system-output-tap create-begin ") }
        let tapUID = tapCreate.flatMap { Self.field("tap-uid", of: $0) }
        XCTAssertNotNil(tapUID)
        let aggregateCreate = lines.first { $0.hasPrefix("system-output-aggregate create-begin ") }
        let aggregateUID = aggregateCreate.flatMap { Self.field("aggregate-uid", of: $0) }
        XCTAssertTrue(aggregateUID?.hasPrefix("io.github.yuhkis.audio-level-bar.tap.") == true)

        // Every line of the aggregate device and of the IOProc on it names the
        // aggregate device, and every line of the build names the tap: by
        // its description's UUID on the create's own lines, and by the UID
        // the HAL reports for it after that.
        let named = lines.filter { $0.hasPrefix("system-output-") }
        XCTAssertEqual(named.count, 16)
        for line in named where !line.hasPrefix("system-output-tap ") {
            XCTAssertEqual(Self.field("aggregate-uid", of: line), aggregateUID, line)
        }
        for line in named {
            let expected = line.hasPrefix("system-output-tap create") ? tapUID : "fake-tap"
            XCTAssertEqual(Self.field("tap-uid", of: line), expected, line)
        }
        XCTAssertTrue(named.contains { $0.hasPrefix("system-output-ioproc start ") })
    }

    func testAFailedAggregateCreateLeavesItsUIDOffEveryLineAfterIt() {
        let hal = observedFake()
        hal.setStatus(kAudioHardwareUnspecifiedError, for: .createAggregate)
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        let failed = expectation(description: "failed")
        meter.onError = { _ in failed.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [failed], timeout: timeout)

        let lines = hal.timeline.compactMap(\.lineText)
        guard
            let createIndex = lines.firstIndex(where: { $0.hasPrefix("system-output-aggregate create ") }),
            let attempted = Self.field("aggregate-uid", of: lines[createIndex])
        else {
            return XCTFail("the failed create names the UID it attempted: \(lines)")
        }
        let after = lines.dropFirst(createIndex + 1)
        XCTAssertTrue(after.contains { $0.hasPrefix("system-output-tap destroy ") })
        XCTAssertFalse(after.contains { $0.contains("aggregate-uid=") }, "\(after)")

        hal.setStatus(noErr, for: .createAggregate)
        meter.onError = nil
        let started = expectation(description: "started")
        meter.onStarted = { started.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [started], timeout: timeout)
        let nextTapCreate = hal.timeline.compactMap(\.lineText).last { $0.hasPrefix("system-output-tap create-begin ") }
        XCTAssertNotNil(nextTapCreate)
        XCTAssertNil(nextTapCreate.flatMap { Self.field("aggregate-uid", of: $0) })
        XCTAssertFalse(hal.timeline.compactMap(\.lineText).contains { $0.contains("aggregate-uid=\(attempted) ") && !$0.hasPrefix("system-output-aggregate create") })
    }

    func testAFailedTapCreateLeavesItsUIDOffEveryLineAfterIt() {
        let hal = observedFake()
        hal.setStatus(kAudioHardwareUnspecifiedError, for: .createProcessTap)
        let meter = SystemOutputMeter(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        let failed = expectation(description: "failed")
        meter.onError = { _ in failed.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [failed], timeout: timeout)
        meter.stop()
        meter.lifecycleQueue.sync {}

        let lines = hal.timeline.compactMap(\.lineText)
        guard let createIndex = lines.firstIndex(where: { $0.hasPrefix("system-output-tap create ") }) else {
            return XCTFail("\(lines)")
        }
        XCTAssertFalse(lines.dropFirst(createIndex + 1).contains { $0.contains("tap-uid=") })
    }

    func testTheReleaseAndAdvanceLinesCarryTheirFields() {
        var lines: [String] = []
        HALLifecycleLog.observer = { lines.append($0) }
        HALLifecycleLog.quietWindowRelease(
            .stopsOnly,
            generation: 9,
            snapshotAge: 0.25,
            writesOutstanding: 1,
            pollInFlight: true
        )
        HALLifecycleLog.quietWindowRelease(
            .full,
            generation: 9,
            snapshotAge: nil,
            writesOutstanding: 0,
            pollInFlight: false
        )
        HALLifecycleLog.quietWindowAdvance(source: "hal-notification", generation: 10)

        XCTAssertEqual(lines, [
            "quiet-window release mode=stops-only gen=9 snapshot-age=0.25 writes-outstanding=1 poll-in-flight=true",
            "quiet-window release mode=full gen=9 snapshot-age=- writes-outstanding=0 poll-in-flight=false",
            "quiet-window advance source=hal-notification gen=10"
        ])
    }

    func testMicrophoneLinesNameNoUID() {
        let hal = observedFake()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: LifecycleHoldGeneration())
        let started = expectation(description: "started")
        meter.onEvent = { event in
            if event == .started(self.microphone) {
                started.fulfill()
            }
        }
        meter.start(deviceID: microphone)
        wait(for: [started], timeout: timeout)

        XCTAssertFalse(hal.timeline.compactMap(\.lineText).contains { $0.contains("uid=") })
    }

    func testQuitWritesItsCallsWithoutAGeneration() {
        let generation = generation(at: 2)
        let hal = observedFake()
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let started = expectation(description: "started")
        meter.onEvent = { event in
            if event == .started(self.microphone) {
                started.fulfill()
            }
        }
        meter.start(deviceID: microphone)
        wait(for: [started], timeout: timeout)
        let before = hal.timeline.count

        let stops = LifecycleStopGroup()
        meter.stopAtQuit(in: stops)
        XCTAssertTrue(stops.wait(idleTimeout: timeout, ceiling: timeout).completed)

        let quitLines = hal.timeline.dropFirst(before).compactMap(\.lineText)
        XCTAssertEqual(quitLines, [
            "microphone-ioproc stop-begin id=41 transport=builtIn gen=- reason=quit",
            "microphone-ioproc stop id=41 transport=builtIn status=0 gen=- reason=quit",
            "microphone-ioproc destroy-begin id=41 transport=builtIn gen=- reason=quit",
            "microphone-ioproc destroy id=41 transport=builtIn status=0 gen=- reason=quit"
        ])
    }

    func testAStartInterruptedAfterCreateWritesNoBeginForTheStartItHeldBack() {
        let generation = generation(at: 1)
        let hal = observedFake()
        hal.onCall = { call in
            if case .createIOProc = call {
                generation.advance()
            }
        }
        let meter = MicrophoneMeter(halCalls: hal, holdGeneration: generation)
        let interrupted = expectation(description: "interrupted")
        meter.onEvent = { event in
            if event == .interrupted(self.microphone) {
                interrupted.fulfill()
            }
        }
        meter.start(deviceID: microphone)
        wait(for: [interrupted], timeout: timeout)

        XCTAssertEqual(hal.timeline.compactMap(\.lineText), [
            "microphone-ioproc create-begin id=41 transport=builtIn gen=1",
            "microphone-ioproc create id=41 transport=builtIn status=0 gen=1",
            "microphone-ioproc interrupt id=41 transport=builtIn status=0 gen=1"
        ])
    }

    // MARK: Helpers

    private func generation(at value: Int) -> LifecycleHoldGeneration {
        let generation = LifecycleHoldGeneration()
        for _ in 0..<value {
            generation.advance()
        }
        return generation
    }

    private func observedFake() -> FakeHALLifecycleCalls {
        let hal = FakeHALLifecycleCalls()
        HALLifecycleLog.observer = { [hal] line in
            hal.noteLine(line)
        }
        return hal
    }

    /// Every create, start, stop and destroy in the timeline comes
    /// immediately after its begin line and immediately before its result
    /// line, and both carry `generation`.
    private func assertEveryCallIsBracketed(
        _ hal: FakeHALLifecycleCalls,
        generation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let entries = hal.timeline.filter { entry in
            if case let .call(call) = entry {
                return !call.isListenerCall
            }
            return true
        }
        var bracketed = 0
        for (index, entry) in entries.enumerated() {
            guard case let .call(call) = entry else {
                continue
            }
            let operation = Self.operationName(of: call)
            guard
                index > 0,
                index + 1 < entries.count,
                let before = entries[index - 1].lineText,
                let after = entries[index + 1].lineText
            else {
                XCTFail("\(call) is not between two lines", file: file, line: line)
                continue
            }
            XCTAssertTrue(
                before.contains(" \(operation)-begin ") && Self.carries(before, generation: generation),
                "before \(call): \(before)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                after.contains(" \(operation) ") && after.contains(" status=")
                    && Self.carries(after, generation: generation),
                "after \(call): \(after)",
                file: file,
                line: line
            )
            bracketed += 1
        }
        XCTAssertEqual(bracketed, hal.lifecycleCalls.count, file: file, line: line)
    }

    /// The value of `name=` in `line`, or nil.
    private static func field(_ name: String, of line: String) -> String? {
        line.split(separator: " ")
            .first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    /// Whether `line` has the field `gen=<generation>`.
    private static func carries(_ line: String, generation: String) -> Bool {
        line.split(separator: " ").contains { $0 == "gen=\(generation)" }
    }

    private static func operationName(of call: FakeHALLifecycleCalls.Call) -> String {
        switch call {
        case .createIOProc, .createProcessTap, .createAggregate:
            return "create"
        case .start:
            return "start"
        case .stop:
            return "stop"
        case .destroyIOProc, .destroyAggregate, .destroyProcessTap:
            return "destroy"
        case .addPropertyListener, .removePropertyListener, .readIsRunning, .readIsRunningSomewhere:
            return "-"
        }
    }
}

private extension FakeHALLifecycleCalls.TimelineEntry {
    var lineText: String? {
        if case let .line(text) = self {
            return text
        }
        return nil
    }
}
