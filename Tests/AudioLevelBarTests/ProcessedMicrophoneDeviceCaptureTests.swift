import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// The processed microphone's IOProc capture, through a fake HAL that never
/// reaches coreaudiod: its release one call at a time against the quiet
/// window's generation, the storage its IOProc reads, and what it does
/// after a failed or refused start.
final class ProcessedMicrophoneDeviceCaptureTests: XCTestCase {
    private let timeout: TimeInterval = 5
    private let microphone: AudioDeviceID = 41

    override func tearDown() {
        HALLifecycleLog.observer = nil
        super.tearDown()
    }

    func testAReleaseUnderAWindowStopsBeforeTheCallItHoldsBackAndKeepsTheRest() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        startCapture(capture, generation: generation)
        let started = hal.calls.count
        let target = microphone
        hal.onCall = { call in
            if call == .stop(target) {
                // The window arms while AudioDeviceStop is in coreaudiod.
                generation.advance()
            }
        }

        let interrupted = expectation(description: "release interrupted")
        capture.release(session: UUID(), holdToken: generation.current) { interrupted.fulfill() }
        wait(for: [interrupted], timeout: timeout)

        XCTAssertEqual(
            Array(hal.calls.dropFirst(started)).filter { !$0.isListenerCall },
            [.stop(microphone)],
            "the IOProc is not destroyed inside the window"
        )
        XCTAssertNotNil(capture.liveContext, "the storage the IOProc reads stays while the IOProc exists")

        // The release after the window destroys what is left, without a
        // second stop.
        hal.onCall = nil
        let secondRelease = hal.calls.count
        capture.release(session: UUID(), holdToken: generation.current) { XCTFail("not interrupted") }
        capture.queue.sync {}
        XCTAssertEqual(Array(hal.calls.dropFirst(secondRelease)), [.destroyIOProc(microphone)])
    }

    func testTheStorageTheIOProcReadsOutlivesItsDestroyByTheReleaseDelay() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        startCapture(capture, generation: generation)
        weak var context = capture.liveContext
        XCTAssertNotNil(context)

        let destroyedAt = Date()
        capture.release(session: UUID(), holdToken: generation.current) { XCTFail("not interrupted") }
        capture.queue.sync {}
        XCTAssertTrue(hal.calls.contains(.destroyIOProc(microphone)))
        XCTAssertNotNil(context, "an IO cycle still finishing may read it right after the destroy")

        waitUntil("the context is released", timeout: timeout) { context == nil }
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(destroyedAt),
            ProcessedMicrophoneDeviceCapture.contextReleaseDelay,
            "not before the release delay"
        )
    }

    func testTheStorageIsKeptWhenTheDestroyDidNotConfirmTheIOProcIsGone() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.setStatus(kAudioHardwareUnspecifiedError, for: .destroyIOProc)
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        startCapture(capture, generation: generation)
        weak var context = capture.liveContext

        capture.release(session: UUID(), holdToken: generation.current) { XCTFail("not interrupted") }
        capture.queue.sync {}
        let settled = expectation(description: "past the release delay")
        capture.queue.asyncAfter(deadline: .now() + ProcessedMicrophoneDeviceCapture.contextReleaseDelay + 0.2) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: timeout)

        XCTAssertNotNil(context, "kept for the life of the process")
    }

    func testAFailedStartThatReportsRunningIsStoppedBeforeItsIOProcIsDestroyed() {
        let lines = LineRecorder(prefix: "processed-microphone-capture-ioproc stop ")
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.startStatus = kAudioHardwareUnspecifiedError
        hal.isRunningRead = (noErr, 1)
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        let session = prepareCapture(capture, generation: generation)

        let outcome = capture.queue.sync { capture.startIO(session: session, holdToken: generation.current) }

        guard case .failed(kAudioHardwareUnspecifiedError)? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(
            hal.calls.filter { !$0.isListenerCall || $0 == .readIsRunning(microphone) },
            [
                .createIOProc(microphone),
                .start(microphone),
                .readIsRunning(microphone),
                .stop(microphone),
                .destroyIOProc(microphone)
            ]
        )
        XCTAssertEqual(lines.values.count, 1)
        XCTAssertTrue(lines.values.first?.contains("reason=failed-start") == true)
    }

    func testAFailedStartThatDoesNotReportRunningIsDestroyedWithoutAStop() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        hal.startStatus = kAudioHardwareUnspecifiedError
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        let session = prepareCapture(capture, generation: generation)

        _ = capture.queue.sync { capture.startIO(session: session, holdToken: generation.current) }

        XCTAssertEqual(
            hal.calls.filter { !$0.isListenerCall || $0 == .readIsRunning(microphone) },
            [.createIOProc(microphone), .start(microphone), .readIsRunning(microphone), .destroyIOProc(microphone)]
        )
    }

    func testForgetAfterAServiceRestartMakesNoHALCall() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        startCapture(capture, generation: generation)
        let started = hal.calls
        weak var context = capture.liveContext

        capture.forgetAfterServiceRestart()
        capture.queue.sync {}
        XCTAssertEqual(hal.calls, started, "no stop, destroy or listener removal")

        capture.release(session: UUID(), holdToken: generation.current) { XCTFail("nothing to interrupt") }
        capture.queue.sync {}
        XCTAssertEqual(hal.calls, started, "a later release has nothing left to release")
        XCTAssertNotNil(context, "nothing confirmed the IO thread let go of it")
    }

    func testARefusalAtStartIOWithAWindowArmedKeepsTheIOProc() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        let session = prepareCapture(capture, generation: generation)
        let prepared = hal.calls
        let token = generation.current
        let target = microphone
        // The input became a Bluetooth device, and a window armed, while the
        // publisher started on the main thread.
        hal.setTransportInfo(AudioDeviceTransportInfo(transport: .bluetooth), for: microphone)
        hal.onRead = { read in
            if read == .transportInfo(target) {
                generation.advance()
            }
        }

        let outcome = capture.queue.sync { capture.startIO(session: session, holdToken: token) }

        guard case .interrupted? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(hal.calls, prepared, "neither started nor released inside the window")

        // After the window the release removes the listeners and destroys
        // the IOProc, which never started.
        hal.onRead = nil
        capture.release(session: UUID(), holdToken: generation.current) { XCTFail("not interrupted") }
        capture.queue.sync {}
        XCTAssertEqual(
            Array(hal.calls.dropFirst(prepared.count)).filter { !$0.isListenerCall },
            [.destroyIOProc(microphone)]
        )
        XCTAssertTrue(hal.listenerSelectors(on: microphone).isEmpty)
    }

    func testARefusalAtStartIOWithoutAWindowReleasesTheIOProcBeforeReporting() {
        let generation = LifecycleHoldGeneration()
        let hal = FakeHALLifecycleCalls()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        let session = prepareCapture(capture, generation: generation)
        hal.setTransportInfo(AudioDeviceTransportInfo(transport: .bluetooth), for: microphone)

        let outcome = capture.queue.sync { capture.startIO(session: session, holdToken: generation.current) }

        guard case .refused(.bluetooth)? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(microphone), .destroyIOProc(microphone)])
    }

    // MARK: Helpers

    /// Begins a session and prepares the capture on its queue.
    @discardableResult
    private func prepareCapture(
        _ capture: ProcessedMicrophoneDeviceCapture,
        generation: LifecycleHoldGeneration
    ) -> UUID {
        let session = UUID()
        capture.begin(session: session)
        let token = generation.current
        let microphone = microphone
        let outcome = capture.queue.sync {
            capture.prepare(
                deviceID: microphone,
                session: session,
                gainScalar: ProcessedMicrophoneAtomicFloat(1),
                webRTCLevel: nil,
                holdToken: token,
                onInvalidated: {}
            )
        }
        guard case .prepared? = outcome else {
            XCTFail("not prepared: \(String(describing: outcome))")
            return session
        }
        return session
    }

    private func startCapture(_ capture: ProcessedMicrophoneDeviceCapture, generation: LifecycleHoldGeneration) {
        let session = prepareCapture(capture, generation: generation)
        let token = generation.current
        let outcome = capture.queue.sync { capture.startIO(session: session, holdToken: token) }
        guard case .started? = outcome else {
            return XCTFail("not started: \(String(describing: outcome))")
        }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), description)
    }
}

/// hal-lifecycle lines with a prefix, as they were written.
final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    init(prefix: String) {
        HALLifecycleLog.observer = { [weak self] line in
            guard line.hasPrefix(prefix) else {
                return
            }
            self?.append(line)
        }
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    private func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
}
