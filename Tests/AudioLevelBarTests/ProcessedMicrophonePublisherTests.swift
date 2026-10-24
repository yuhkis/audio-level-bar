import AVFoundation
import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// The processed microphone's publisher, an IOProc on the output it is bound
/// to, through a fake HAL that never reaches coreaudiod: it is created and
/// started on that one device, reads an output that is not built-in again
/// before the create and before the start, keeps what a quiet window holds
/// back, and renders the ring into every channel, resampled when the rates
/// differ, or silence once its gate is closed.
final class ProcessedMicrophonePublisherTests: XCTestCase {
    private let output: AudioDeviceID = 600
    private let microphone: AudioDeviceID = 41

    override func tearDown() {
        HALLifecycleLog.observer = nil
        super.tearDown()
    }

    func testThePublisherIsAnIOProcCreatedAndStartedOnTheBoundOutputAlone() throws {
        let lines = LineRecorder(prefix: "processed-microphone-publisher-ioproc ")
        let hal = FakeHALLifecycleCalls()
        var reads: [FakeHALLifecycleCalls.Read] = []
        hal.onRead = { reads.append($0) }
        let generation = LifecycleHoldGeneration()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)

        let outcome = try startPublisher(capture, generation: generation, output: builtInOutput)

        guard case .started? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(output), .start(output)])
        XCTAssertFalse(reads.contains(.defaultOutputDeviceID), "the default output is not followed or read")
        XCTAssertFalse(reads.contains(.transportInfo(output)), "a built-in output is not read again")
        let gen = generation.current
        XCTAssertEqual(
            lines.values,
            [
                "processed-microphone-publisher-ioproc create-begin id=\(output) transport=builtIn gen=\(gen)",
                "processed-microphone-publisher-ioproc create id=\(output) transport=builtIn status=0 gen=\(gen)",
                "processed-microphone-publisher-ioproc start-begin id=\(output) transport=builtIn gen=\(gen)",
                "processed-microphone-publisher-ioproc start id=\(output) transport=builtIn status=0 gen=\(gen)"
            ]
        )
        XCTAssertEqual(
            Set(hal.listenerSelectors(on: output)),
            [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreamConfiguration]
        )
    }

    func testAnOutputThatIsNotBuiltInIsReadBeforeTheCreateAndAgainBeforeTheStart() throws {
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(AudioDeviceTransportInfo(transport: .usb), for: output)
        var timeline: [String] = []
        hal.onRead = { read in
            if read == .transportInfo(600) {
                timeline.append("read")
            }
        }
        hal.onCall = { call in
            if !call.isListenerCall {
                timeline.append("\(call)")
            }
        }
        let generation = LifecycleHoldGeneration()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)

        let outcome = try startPublisher(capture, generation: generation, output: usbOutput)

        guard case .started? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(timeline, ["read", "createIOProc(600)", "read", "start(600)"])
    }

    func testAnOutputThatBecameBluetoothBeforeTheCreateIsRefusedWithNothingCreated() throws {
        let lines = LineRecorder(prefix: "processed-microphone-publisher-ioproc ")
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(AudioDeviceTransportInfo(transport: .bluetooth), for: output)
        let generation = LifecycleHoldGeneration()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)

        let outcome = try startPublisher(capture, generation: generation, output: usbOutput)

        guard case .outputUnavailable(output)? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(hal.lifecycleCalls, [])
        XCTAssertEqual(lines.values, ["processed-microphone-publisher-ioproc refuse id=\(output) transport=bluetooth status=0 gen=\(generation.current)"])
    }

    func testAnOutputThatGainsBluetoothOnceItsListenersAreInPlaceIsReleasedUnstarted() throws {
        let hal = FakeHALLifecycleCalls()
        hal.setTransportInfo(AudioDeviceTransportInfo(transport: .usb), for: output)
        let target = output
        hal.onCall = { call in
            if call == .createIOProc(target) {
                hal.setTransportInfo(AudioDeviceTransportInfo(transport: .bluetooth), for: target)
            }
        }
        let generation = LifecycleHoldGeneration()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)

        let outcome = try startPublisher(capture, generation: generation, output: usbOutput)

        guard case .outputUnavailable(output)? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(output), .destroyIOProc(output)])
    }

    func testAWindowArmedDuringTheCreateKeepsTheIOProcUnstartedForTheReleaseAfterIt() throws {
        let lines = LineRecorder(prefix: "processed-microphone-publisher-ioproc ")
        let hal = FakeHALLifecycleCalls()
        let generation = LifecycleHoldGeneration()
        let target = output
        hal.onCall = { call in
            if call == .createIOProc(target) {
                generation.advance()
            }
        }
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        let issued = generation.current

        let outcome = try startPublisher(capture, generation: generation, output: builtInOutput)

        guard case .interrupted? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(output)], "nothing is started inside the window")
        XCTAssertEqual(lines.values.last, "processed-microphone-publisher-ioproc interrupt id=\(output) transport=builtIn status=0 gen=\(issued)")

        hal.onCall = nil
        capture.release(session: UUID(), holdToken: generation.current) { XCTFail("not interrupted") }
        capture.queue.sync {}
        XCTAssertEqual(hal.lifecycleCalls, [.createIOProc(output), .destroyIOProc(output)])
    }

    func testAnOutputWithNoUsableFormatCreatesNothing() throws {
        let hal = FakeHALLifecycleCalls()
        hal.outputStreamFormatRead = nil
        let generation = LifecycleHoldGeneration()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)

        let outcome = try startPublisher(capture, generation: generation, output: builtInOutput)

        guard case .outputUnavailable(output)? = outcome else {
            return XCTFail("\(String(describing: outcome))")
        }
        XCTAssertEqual(hal.lifecycleCalls, [])
    }

    func testAReleaseStopsTheCaptureBeforeThePublisherAndClosesThePublisherGateAtOnce() throws {
        let hal = FakeHALLifecycleCalls()
        let generation = LifecycleHoldGeneration()
        let capture = ProcessedMicrophoneDeviceCapture(halCalls: hal, holdGeneration: generation)
        let session = UUID()
        capture.begin(session: session)
        let token = generation.current
        let microphone = microphone
        let prepared = capture.queue.sync {
            capture.prepare(
                deviceID: microphone,
                session: session,
                gainScalar: ProcessedMicrophoneAtomicFloat(1),
                webRTCLevel: nil,
                holdToken: token,
                onInvalidated: {}
            )
        }
        guard case let .prepared(value)? = prepared else {
            return XCTFail("\(String(describing: prepared))")
        }
        let output = builtInOutput
        let publisher = capture.queue.sync {
            capture.startPublisher(
                output: output,
                ringBuffer: value.ringBuffer,
                inputSampleRate: value.monoFormat.sampleRate,
                session: session,
                holdToken: token,
                onInvalidated: {}
            )
        }
        guard case .started? = publisher else {
            return XCTFail("\(String(describing: publisher))")
        }
        let started = capture.queue.sync { capture.startIO(session: session, holdToken: token) }
        guard case .started? = started else {
            return XCTFail("\(String(describing: started))")
        }
        XCTAssertEqual(
            hal.lifecycleCalls,
            [.createIOProc(microphone), .createIOProc(self.output), .start(self.output), .start(microphone)],
            "the publisher starts before the capture that writes its ring"
        )
        let context = try XCTUnwrap(capture.livePublisherContext)

        // Held on the queue, so the release has only been issued.
        let hold = DispatchSemaphore(value: 0)
        capture.queue.async { hold.wait() }
        let released = hal.lifecycleCalls.count
        capture.release(session: UUID(), holdToken: generation.current) { XCTFail("not interrupted") }
        XCTAssertFalse(context.close(), "the gate was closed before the release reached the queue")
        hold.signal()
        capture.queue.sync {}

        XCTAssertEqual(
            Array(hal.lifecycleCalls.dropFirst(released)),
            [.stop(microphone), .destroyIOProc(microphone), .stop(self.output), .destroyIOProc(self.output)]
        )
    }

    func testTheRingIsRenderedIntoEveryChannelUntilTheGateCloses() throws {
        let ring = try XCTUnwrap(ProcessedMicrophoneRingBuffer(format: Self.monoFormat, duration: 0.25))
        let context = try XCTUnwrap(
            ProcessedMicrophonePublisherContext(
                ringBuffer: ring,
                inputSampleRate: 48_000,
                outputSampleRate: 48_000,
                maximumFrames: 4_096
            )
        )
        XCTAssertFalse(context.converts)
        write(0.5, frames: 4_096, into: ring)

        let rendered = render(context, frames: 256, channels: 2)
        XCTAssertEqual(rendered.count, 512)
        XCTAssertTrue(rendered.allSatisfy { abs($0 - 0.5) < 0.0001 }, "both channels carry the mono signal")

        context.close()
        XCTAssertTrue(render(context, frames: 256, channels: 2).allSatisfy { $0 == 0 }, "silence once closed")
    }

    func testARingAtAnotherRateIsResampledToTheOutputsRate() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let ring = try XCTUnwrap(ProcessedMicrophoneRingBuffer(format: format, duration: 0.25))
        let context = try XCTUnwrap(
            ProcessedMicrophonePublisherContext(
                ringBuffer: ring,
                inputSampleRate: 44_100,
                outputSampleRate: 48_000,
                maximumFrames: 4_096
            )
        )
        XCTAssertTrue(context.converts)
        write(0.5, frames: 8_192, into: ring)

        // The converter's filter starts from silence; later cycles carry the
        // steady signal.
        _ = render(context, frames: 512, channels: 1)
        let rendered = render(context, frames: 512, channels: 1)
        XCTAssertEqual(rendered.count, 512)
        XCTAssertTrue(rendered.allSatisfy { abs($0 - 0.5) < 0.01 }, "\(rendered.prefix(8))")
    }

    func testAListedOutputWhoseTransportWasNotReadIsWaitedForRatherThanRefused() {
        let hal = FakeHALLifecycleCalls()
        let headset: AudioDeviceID = 70
        let usbOutput: AudioDeviceID = 80
        hal.currentDefaultOutputID = headset
        hal.setTransportInfo(AudioDeviceTransportInfo(transport: .bluetooth), for: headset)
        func listed(usbTransport: AudioDeviceTransport?) -> [AudioDevice] {
            [
                AudioDevice(id: headset, name: "Headset", uid: "headset", inputChannelCount: 1, outputChannelCount: 2, transport: .bluetooth),
                AudioDevice(id: usbOutput, name: "USB", uid: "usb", inputChannelCount: 0, outputChannelCount: 2, transport: usbTransport)
            ]
        }

        guard case .refused(.outputsNotRead, _, _) = PublisherOutputReading.read(hal, listedOutputs: listed(usbTransport: nil)) else {
            return XCTFail("an unread transport is a read to wait out")
        }
        guard case .refused(.noNonBluetoothOutput, _, _) = PublisherOutputReading.read(hal, listedOutputs: listed(usbTransport: .unknown)) else {
            return XCTFail("an unclassified transport is refused")
        }
        XCTAssertEqual(listed(usbTransport: nil)[1].transport, .unknown, "the picker still shows an icon for it")
    }

    // MARK: Helpers

    private static let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private var builtInOutput: PublisherOutput {
        PublisherOutput(deviceID: output, transport: "builtIn", info: AudioDeviceTransportInfo(transport: .builtIn))
    }

    private var usbOutput: PublisherOutput {
        PublisherOutput(deviceID: output, transport: "usb", info: AudioDeviceTransportInfo(transport: .usb))
    }

    /// Begins a session and starts the publisher on the queue.
    private func startPublisher(
        _ capture: ProcessedMicrophoneDeviceCapture,
        generation: LifecycleHoldGeneration,
        output: PublisherOutput
    ) throws -> ProcessedMicrophoneDeviceCapture.PublisherStartOutcome? {
        let session = UUID()
        capture.begin(session: session)
        let token = generation.current
        let ring = try XCTUnwrap(ProcessedMicrophoneRingBuffer(format: Self.monoFormat, duration: 0.25))
        return capture.queue.sync {
            capture.startPublisher(
                output: output,
                ringBuffer: ring,
                inputSampleRate: 48_000,
                session: session,
                holdToken: token,
                onInvalidated: {}
            )
        }
    }

    private func write(_ value: Float, frames: Int, into ring: ProcessedMicrophoneRingBuffer) {
        let samples = [Float](repeating: value, count: frames)
        samples.withUnsafeBufferPointer { buffer in
            ring.noteProducerBurst(frameCount: frames)
            ring.processAndWrite(buffer.baseAddress!, frameCount: frames, gainScalar: 1)
        }
    }

    /// One IO cycle into a single interleaved output buffer.
    private func render(_ context: ProcessedMicrophonePublisherContext, frames: Int, channels: Int) -> [Float] {
        var samples = [Float](repeating: -1, count: frames * channels)
        samples.withUnsafeMutableBufferPointer { buffer in
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(list.unsafeMutablePointer) }
            list[0] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(buffer.baseAddress)
            )
            context.render(list.unsafeMutablePointer)
        }
        return samples
    }
}
