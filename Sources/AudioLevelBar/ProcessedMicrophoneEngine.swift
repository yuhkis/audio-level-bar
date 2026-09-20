import AVFoundation
import AudioLevelBarCore
import CoreAudio
import Darwin
import Foundation
import WebRTCNoiseSuppression

enum ProcessedMicrophoneEngineError: LocalizedError {
    case unsupportedInputFormat
    case operationFailed(String, String)
    /// An AVFAudio call raised an Objective-C exception, caught by
    /// `ObjCExceptionShim`: the step, and the exception's name and reason.
    /// AVFAudio raises this way when a device is being rebound or
    /// reconfigured under the engine, so a start treats it as a change under
    /// way rather than as a failure of its mode.
    case engineRaised(String, String)
    /// The capture re-read the input device's transport immediately before
    /// opening it, and did not open it.
    case inputRefused(InputOpenRefusal)
    /// Apple voice processing re-read the default input and output, and they
    /// were no longer the devices the start was decided on, or now involve
    /// Bluetooth. Reported only for the read made before anything is built;
    /// a default that moves once the start has built something asks for a
    /// restart instead (`RestartReason.sourceChanged`). Nothing was started.
    case voiceProcessingSourceChanged(VoiceProcessingDeviceCheck)
    /// The output the start rendered to, the publisher engine's or the one
    /// Apple voice processing opens, read no usable hardware format, as a
    /// device being reconfigured or removed does, or the publisher's output
    /// was no longer eligible when read again before its start. The ID is
    /// that output. Nothing was started.
    case outputUnavailable(AudioDeviceID)
    /// The read made immediately before the publisher engine is built found
    /// no output it may be bound to. Nothing was started.
    case publisherOutputRefused(PublisherOutputRefusal)

    var errorDescription: String? {
        switch self {
        case .unsupportedInputFormat:
            return localized("The selected microphone did not provide a Float32 audio format that can be processed.")
        case let .operationFailed(operation, detail), let .engineRaised(operation, detail):
            return localized("%1$@ failed: %2$@", operation, detail)
        case .inputRefused(.bluetooth), .inputRefused(.aggregateWithBluetoothMember):
            return localized("The processed microphone does not start while the default input is a Bluetooth microphone, or an aggregate device that includes a Bluetooth device or a device that is not available, because opening it could switch a headset into call mode and lower playback quality. It starts once another input is the default.")
        case .publisherOutputRefused(.noNonBluetoothOutput):
            return localized("The processed microphone does not start without a built-in or other non-Bluetooth output. It renders its audio, muted, to such an output rather than to a Bluetooth headset. It starts once one is available.")
        // An aggregate member that only the read made as the input was opened
        // could not resolve is a read to try again, like a transport that
        // could not be read, not a Bluetooth refusal.
        case .inputRefused(.noDevice), .inputRefused(.transportNotRead),
             .inputRefused(.aggregateWithUnresolvedMember), .voiceProcessingSourceChanged,
             .outputUnavailable, .publisherOutputRefused(.outputsNotRead):
            return localized("Preparing the processed microphone")
        }
    }
}

/// Captures the microphone, optionally applies Apple's voice processing or
/// WebRTC noise suppression, normalizes the result to mono, applies digital
/// gain, and renders it through a separate non-voice-processing engine.
///
/// With processing off or WebRTC noise suppression, capture is a HAL IOProc
/// bound to the one input device named in the configuration. It never follows
/// the default input by itself, so a Bluetooth headset arriving cannot move it
/// onto the headset's microphone; the owner decides when to capture another
/// device. Apple voice processing needs AVAudioEngine's voice-processing I/O
/// unit, which follows the default input and output itself, so the owner does
/// not start that mode while either of them involves Bluetooth, and the engine
/// reads both defaults again, uncached, immediately before starting it.
///
/// The publisher engine is intentionally separate from the capture. A direct
/// input-to-output connection on the voice-processing engine would feed the
/// microphone uplink into its own echo-cancellation reference. The owner must
/// arrange for the publisher engine's process audio to be captured and muted
/// before calling `start`; otherwise the processed microphone is audible
/// through the output device the publisher is bound to.
///
/// The publisher engine never follows the default output. Immediately before
/// it is built, the output devices and the default output are read uncached on
/// the lifecycle queue, and its output node is bound to the device
/// `PublisherOutputPolicy` chooses: a built-in output, or else a default output
/// known not to involve Bluetooth. With neither, the start is refused.
///
/// While this engine is running, the owner should stop `MicrophoneMeter` and use
/// `onInputLevel` / `onOutputLevel` for metering. Lifecycle methods are expected
/// to be called from the main thread, matching the rest of the app's audio
/// state management. The IOProc capture is created, started, stopped and
/// destroyed on its own lifecycle queue, and `onStarted` or `onError` arrives
/// on the main thread once that has happened.
final class ProcessedMicrophoneEngine {
    struct Configuration: Equatable {
        var processingMode: MicrophoneProcessingMode
        var digitalGainDecibels: Float
        /// The input device to capture. The IOProc capture opens exactly this
        /// device; Apple voice processing follows the default input, and the
        /// owner compares this with the current default input to tell that a
        /// capture has to be rebuilt.
        var inputDeviceID: AudioDeviceID
        /// The default output the start was decided for. Only Apple voice
        /// processing, which opens the default output itself, uses it: the
        /// start checks that the default output is still this device.
        var outputDeviceID: AudioDeviceID

        init(
            processingMode: MicrophoneProcessingMode = .off,
            digitalGainDecibels: Float = 0,
            inputDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown),
            outputDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
        ) {
            self.processingMode = processingMode
            self.digitalGainDecibels = digitalGainDecibels
            self.inputDeviceID = inputDeviceID
            self.outputDeviceID = outputDeviceID
        }
    }

    /// Product-wide digital-gain range shared with the UI-independent core.
    static let supportedDigitalGainRange: ClosedRange<Float> =
        DigitalGain.minimumDecibels...DigitalGain.maximumDecibels

    /// The mono input level before this class's digital gain. Apple voice
    /// processing or WebRTC noise suppression has already been applied.
    var onInputLevel: ((Float, Float) -> Void)?

    /// The final level after digital gain and, for positive gain, limiting.
    var onOutputLevel: ((Float, Float) -> Void)?
    var onStarted: (() -> Void)?
    /// A start that failed or was refused. Everything it built has already
    /// been released, and `isRunning` is false.
    var onError: ((ProcessedMicrophoneEngineError) -> Void)?

    enum RestartReason: Equatable {
        /// A configuration change under an engine, or an invalidated capture:
        /// a change the HAL is still settling.
        case configurationChanged
        /// The publisher's output, this ID, read no usable hardware format,
        /// or was no longer eligible before its start: a change the HAL is
        /// still settling too, which the owner counts, because an output that
        /// keeps reading that way does not settle. Apple voice processing
        /// asks the same when the output its engine opens reads that way.
        case outputUnavailable(AudioDeviceID)
        /// Apple voice processing's start found a default device moved,
        /// immediately before its engine started or while it started: a
        /// change the HAL is still making. What the start built, a started
        /// engine included, stays until the restart releases it after the
        /// window, so nothing is stopped inside that change.
        case sourceChanged
        /// A start under way stopped before its next HAL step, because a
        /// quiet window armed after it was issued or `startMayProceed` said
        /// no. What it created stays until the restart releases it.
        case startInterrupted
        /// A stop left the IOProc capture in place, or the publisher and
        /// voice-processing engines unstopped, because a quiet window armed
        /// after the stop was issued. The engine counts as running again
        /// until the owner stops or rebuilds it after the window.
        case stopInterrupted
    }

    /// Requests a fail-closed restart from the owner, once per start. The
    /// owner decides when: it must stop this engine, validate/recreate the
    /// muted public tap, and only then start it, and it waits for the HAL
    /// quiet window before doing any of that.
    var onNeedsRestart: ((RestartReason) -> Void)?
    /// Asked on the main thread before a start under way starts the publisher
    /// engine: whether the owner still wants this start, outside the quiet
    /// window and from an allowed source. nil lets it proceed.
    var startMayProceed: (() -> Bool)?

    private(set) var configuration = Configuration()
    /// True from `start()` until `stop()` or a failed start, including while
    /// the IOProc capture is still being created and started.
    private(set) var isRunning = false
    /// True once `onStarted` has been delivered for the current start.
    private(set) var hasStarted = false
    /// True once a configuration change or an invalidated capture asked for a
    /// restart the owner has not carried out yet.
    private(set) var needsRestart = false
    /// Apple voice processing's engines are running, or their start is under
    /// way.
    var runsVoiceProcessing: Bool {
        isRunning && configuration.processingMode == .apple
    }
    /// The output device the running publisher engine is bound to, nil while
    /// none is built. The owner rebuilds the engines once the poll shows this
    /// device gone or involving Bluetooth.
    var publisherOutputDeviceID: AudioDeviceID? {
        boundPublisherOutput?.deviceID
    }
    /// The output the running publisher engine was bound to, as read before
    /// it started, for its log lines.
    private var boundPublisherOutput: PublisherOutput?
    /// The input the running Apple voice processing engine started on, as
    /// read before it started, for its log lines.
    private var voiceProcessingInput: (deviceID: AudioDeviceID, transport: String)?
    /// Whether the capture engine held in `captureEngine` had its start
    /// issued. An interrupted start keeps an engine that never started, and
    /// its release writes no stop lines for it.
    private var voiceProcessingEngineStarted = false
    /// Whether the capture engine held in `captureEngine` has its input tap
    /// installed.
    private var voiceProcessingTapInstalled = false
    /// Whether the publisher engine held in `publisherEngine` had its start
    /// issued. A start interrupted before the publisher's start keeps a
    /// publisher that never started, and its release writes no stop lines
    /// for it.
    private var publisherEngineStarted = false
    /// Starts an AVFAudio raise ended in a row, with no start reported in
    /// between.
    private var consecutiveEngineRaises = 0
    /// The raise in a row that is also reported as a failure of the start,
    /// so an engine that keeps raising, which is no device change, is not
    /// rebuilt behind a quiet window forever.
    static let maximumConsecutiveEngineRaises = 4

    private let gainScalar = ProcessedMicrophoneAtomicFloat(1)
    /// The IOProc capture for processing off and WebRTC.
    private let deviceCapture: ProcessedMicrophoneDeviceCapture
    /// The voice-processing capture for Apple voice processing.
    private var captureEngine: (any VoiceProcessingCaptureEngine)?
    private var publisherEngine: (any ProcessedMicrophonePublisherEngine)?
    private var publisherSourceNode: AVAudioSourceNode?
    private var ringBuffer: ProcessedMicrophoneRingBuffer?
    private var tapContext: ProcessedMicrophoneTapContext?
    private var configurationObservers: [NSObjectProtocol] = []
    private var levelTimer: Timer?
    private var lastLevelSequence: Int64 = 0
    private var sessionID = UUID()
    private let holdGeneration: LifecycleHoldGeneration
    /// The quiet-window generation the current start was issued in.
    private var holdToken: UInt64 = 0
    private let halCalls: any HALLifecycleCalls
    /// Makes the publisher's engine. `AVAudioPublisherEngine` in the app; a
    /// test substitutes one that opens no device.
    private let makePublisherEngine: () -> any ProcessedMicrophonePublisherEngine
    /// Makes Apple voice processing's capture engine.
    /// `AVAudioVoiceProcessingEngine` in the app; a test substitutes one that
    /// opens no device.
    private let makeVoiceProcessingEngine: () -> any VoiceProcessingCaptureEngine

    /// Main thread. The engines Quit stopped, with the source nodes attached
    /// to them. Never emptied, so no `-[AVAudioEngine dealloc]` runs during
    /// Quit's teardown or before the process exits.
    ///
    /// A stopped engine's I/O unit keeps its own property listener, and
    /// AVFAudio calls it on its queue with an unretained pointer to the
    /// engine when a default device or a stream format changes. An engine
    /// freed while such a change is under way is messaged after its free.
    /// Quit can tear down within 3 s of a headset's arrival, whose HFP and
    /// A2DP negotiation keeps changing both, and a crash there ends the
    /// process before the publication is withdrawn.
    private static var enginesKeptUntilExit: [AnyObject] = []
    /// Main thread. Engines stopped outside Quit, with their source nodes,
    /// kept for the same reason until an evaluation that admits starts, when
    /// no change can be under way, calls `releaseRetiredEngines()`.
    private var retiredEngines: [AnyObject] = []

    /// Tests only.
    static var enginesKeptUntilExitForTesting: [AnyObject] {
        enginesKeptUntilExit
    }

    /// Tests only.
    var retiredEnginesForTesting: [AnyObject] {
        retiredEngines
    }

    /// Main thread. Frees the engines stopped since the last call. The owner
    /// calls it only from an evaluation that admits starts: the quiet window
    /// is not holding, no generation is unseen and no default-device write is
    /// outstanding, so no device change the app knows of is under way. Never
    /// from an engine's configuration-change observer, which arms the window
    /// first.
    func releaseRetiredEngines() {
        retiredEngines.removeAll()
    }

    /// Keeps `objects` alive past this call: until the process exits at
    /// Quit, and otherwise until `releaseRetiredEngines()`.
    private func retire(_ objects: [AnyObject?], atQuit: Bool = false) {
        let kept = objects.compactMap { $0 }
        if atQuit {
            Self.enginesKeptUntilExit.append(contentsOf: kept)
        } else {
            retiredEngines.append(contentsOf: kept)
        }
    }

    init(
        halCalls: any HALLifecycleCalls,
        holdGeneration: LifecycleHoldGeneration,
        makePublisherEngine: @escaping () -> any ProcessedMicrophonePublisherEngine,
        makeVoiceProcessingEngine: @escaping () -> any VoiceProcessingCaptureEngine
    ) {
        self.halCalls = halCalls
        self.holdGeneration = holdGeneration
        self.makePublisherEngine = makePublisherEngine
        self.makeVoiceProcessingEngine = makeVoiceProcessingEngine
        deviceCapture = ProcessedMicrophoneDeviceCapture(
            halCalls: halCalls,
            holdGeneration: holdGeneration
        )
    }

    deinit {
        stop()
    }

    @discardableResult
    func start(configuration requestedConfiguration: Configuration, holdToken issuedToken: UInt64? = nil) -> Bool {
        configuration = Self.sanitized(requestedConfiguration)
        gainScalar.store(
            DigitalGain.amplitude(decibels: configuration.digitalGainDecibels)
        )
        return start(holdToken: issuedToken)
    }

    /// Starts the capture the configured mode calls for. `true` means the
    /// start was issued; its outcome arrives through `onStarted`,
    /// `onNeedsRestart` or `onError`.
    ///
    /// - Parameter issuedToken: The generation the owner admitted the start
    ///   under; nil takes the current one.
    @discardableResult
    func start(holdToken issuedToken: UInt64? = nil) -> Bool {
        // The release of what an earlier start left is part of this start,
        // and carries its generation.
        let token = issuedToken ?? holdGeneration.current
        guard stop(holdToken: token, loggingAnInterruptionAs: .interrupt) else {
            // A window armed since the owner issued this start, and engines
            // an earlier start left are still held. Nothing is stopped or
            // started inside the window: they count as running with a restart
            // owed, and the owner stops them and starts again after it.
            return false
        }

        let sessionID = UUID()
        self.sessionID = sessionID
        holdToken = token
        guard configuration.processingMode == .apple else {
            startDeviceCapture(sessionID: sessionID, holdToken: holdToken)
            return true
        }
        startVoiceProcessingAfterReadingDevices(sessionID: sessionID, holdToken: holdToken)
        return true
    }

    /// Stops the engines on the main thread, and releases the IOProc capture
    /// on its lifecycle queue.
    ///
    /// Like a start, a stop carries the quiet window's generation its issuer
    /// saw, not the one current when it runs: a listener can advance the
    /// generation on its own queue before the main thread hears of the
    /// change, and a stop that took the live value would pass every check
    /// inside the window that advance belongs to. The capture's release
    /// compares the generation immediately before each of its HAL calls. The
    /// engines' stops compare it here: when it is no longer current, neither
    /// the voice-processing engine nor the publisher is stopped. They stay as
    /// they are, an `interrupt-stop` line is written for each, and this
    /// engine counts as running again with a restart owed
    /// (`RestartReason.stopInterrupted`), so the owner's evaluation after the
    /// window stops them, as it stops what an interrupted start kept.
    ///
    /// - Parameters:
    ///   - reason: `bluetooth-selection` for the stop the app's own picker
    ///     issues before a default write, which the quiet window does not
    ///     hold; the engines' stop lines carry it.
    ///   - issuedToken: The generation the owner's evaluation issued the stop
    ///     in. nil for a stop that is not compared: the picker's, and the one
    ///     deallocation makes, whose lines carry the generation current then.
    /// - Returns: False when the engines' stop was held back. The publisher
    ///   may then still render into the muted tap, so the owner must not
    ///   withdraw the publication.
    @discardableResult
    func stop(reason: String? = nil, holdToken issuedToken: UInt64? = nil) -> Bool {
        stop(reason: reason, holdToken: issuedToken, loggingAnInterruptionAs: .interruptStop)
    }

    /// - Parameter interruption: `interrupt-stop` for a stop the owner issued,
    ///   `interrupt` for the release a start makes of what an earlier start
    ///   left or of what it built itself.
    private func stop(
        reason: String? = nil,
        holdToken issuedToken: UInt64?,
        loggingAnInterruptionAs interruption: HALLifecycleLog.Operation
    ) -> Bool {
        endSession()
        let releaseSession = sessionID
        // The IOProc is stopped and destroyed on the capture's lifecycle
        // queue, and the storage its block reads is released only after that.
        // A quiet window that arms before the queue gets there leaves it in
        // place; this engine then counts as running again, so that the owner
        // releases it after the window.
        deviceCapture.release(
            session: releaseSession,
            holdToken: issuedToken ?? holdGeneration.current
        ) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.deviceCaptureReleaseInterrupted(sessionID: releaseSession)
            }
        }
        return stopEngines(reason: reason, holdToken: issuedToken, loggingAnInterruptionAs: interruption)
    }

    /// The capture's lifecycle queue, for a test to wait for.
    var captureQueue: DispatchQueue {
        deviceCapture.queue
    }

    /// Main thread. Calls `body` on the main thread once the capture's
    /// lifecycle queue has come back from everything issued to it before
    /// this call, whether or not its session is still current. The owner uses
    /// it to tell a release that is waiting in coreaudiod.
    func afterCaptureQueue(_ body: @escaping () -> Void) {
        deviceCapture.queue.async {
            DispatchQueue.main.async(execute: body)
        }
    }

    /// coreaudiod restarted. The IOProc capture is dropped without a HAL call,
    /// and engines that were running owe a restart, which the owner carries
    /// out after the quiet window; `stop()` stops the AVAudioEngines then.
    func noteServiceRestarted() {
        deviceCapture.forgetAfterServiceRestart()
        if isRunning {
            needsRestart = true
        }
    }

    /// Quit only. Stops the engines as `stop()` does, the publisher before
    /// the owner withdraws its muted tap, and releases the IOProc capture on
    /// its lifecycle queue, whatever the quiet window, counted in `stops`.
    func stopAtQuit(in stops: LifecycleStopGroup) {
        endSession()
        deviceCapture.releaseAtQuit(in: stops)
        stopEngines(reason: HALLifecycleLog.quitReason)
        // Engines stopped earlier and not freed yet stay until exit too.
        retire(retiredEngines, atQuit: true)
        retiredEngines.removeAll()
    }

    /// Main thread, Quit only. Closes the IOProc capture's gate, so its IO
    /// thread passes nothing to WebRTC or the ring buffer while the process
    /// exits.
    func closeCaptureGateAtQuit() {
        deviceCapture.closeGateAtQuit()
    }

    private func endSession() {
        levelTimer?.invalidate()
        levelTimer = nil
        lastLevelSequence = 0
        removeConfigurationObservers()
        sessionID = UUID()
    }

    /// Stops the AVAudioEngines synchronously and drops what the session
    /// built. The IOProc capture is released separately.
    ///
    /// - Parameters:
    ///   - reason: `quit` at Quit, or `bluetooth-selection` before the
    ///     picker's default write, for the stop lines.
    ///   - issuedToken: The generation the stop was issued in, compared
    ///     before anything is stopped and carried on the stop lines; see
    ///     `stop(reason:holdToken:)`. Not compared for `reason`s the quiet
    ///     window does not hold.
    ///   - interruption: What a stop held back is logged as.
    /// - Returns: False when the stop was held back and the engines kept.
    @discardableResult
    private func stopEngines(
        reason: String? = nil,
        holdToken issuedToken: UInt64? = nil,
        loggingAnInterruptionAs interruption: HALLifecycleLog.Operation = .interruptStop
    ) -> Bool {
        // Quit's stops and the picker's are not held by the quiet window.
        let unheld = HALLifecycleLog.isUnheldStopReason(reason)
        if
            !unheld,
            let issuedToken,
            !holdGeneration.isCurrent(issuedToken),
            captureEngine != nil || publisherEngine != nil
        {
            keepEnginesWhoseStopWasHeldBack(holdToken: issuedToken, loggingItAs: interruption)
            return false
        }
        // A stop that raises is dropped: the engine is released either way,
        // and nothing more can be done with it. Its line says so.
        let generation = unheld ? nil : issuedToken ?? holdGeneration.current
        if let captureEngine {
            // An engine an interrupted start kept never started: it is still
            // stopped, which releases what prepare() allocated, but no stop
            // lines claim an IO stop.
            let started = voiceProcessingEngineStarted
            if started {
                recordEngine(
                    .processedMicrophoneVoiceProcessingEngine,
                    .stopBegin,
                    engine: captureEngine,
                    expected: voiceProcessingInput,
                    generation: generation,
                    reason: reason
                )
            }
            let stopped = (try? catchingObjCException { captureEngine.stop() }) != nil
            if started {
                recordEngine(
                    .processedMicrophoneVoiceProcessingEngine,
                    .stop,
                    engine: captureEngine,
                    expected: voiceProcessingInput,
                    status: stopped ? noErr : kAudioHardwareUnspecifiedError,
                    generation: generation,
                    reason: reason
                )
            }
            if voiceProcessingTapInstalled {
                _ = try? catchingObjCException { captureEngine.removeTap() }
            }
        }
        // An in-flight tap closure retains its context until process(_:) has
        // returned, so its C processor and scratch storage cannot be freed
        // while the callback is still using them.
        tapContext = nil
        if
            !unheld,
            let issuedToken,
            captureEngine != nil,
            publisherEngine != nil,
            !holdGeneration.isCurrent(issuedToken)
        {
            // Apple voice processing has two engines, and the capture
            // engine's stop above can wait in coreaudiod while a device
            // change begins, which is when a listener advances the
            // generation. The publisher's stop is an IO stop of its own, so it
            // is compared again rather than made inside that window.
            keepPublisherWhoseStopWasHeldBack(holdToken: issuedToken, loggingItAs: interruption)
            return false
        }
        if let publisherEngine {
            // A publisher an interrupted start kept before its start is
            // stopped too, without lines claiming an IO stop.
            let started = publisherEngineStarted
            let expected = boundPublisherOutput.map { (deviceID: $0.deviceID, transport: $0.transport) }
            if started {
                recordEngine(
                    .processedMicrophonePublisherEngine,
                    .stopBegin,
                    publisher: publisherEngine,
                    expected: expected,
                    generation: generation,
                    reason: reason
                )
            }
            let stopped = (try? catchingObjCException { publisherEngine.stop() }) != nil
            if started {
                recordEngine(
                    .processedMicrophonePublisherEngine,
                    .stop,
                    publisher: publisherEngine,
                    expected: expected,
                    status: stopped ? noErr : kAudioHardwareUnspecifiedError,
                    generation: generation,
                    reason: reason
                )
            }
        }
        publisherEngineStarted = false

        // Stopped, not freed: a change may still be under way, and the
        // engines' I/O units still call back into them.
        retire(
            [captureEngine.map { $0 as AnyObject }, publisherEngine.map { $0 as AnyObject }, publisherSourceNode],
            atQuit: reason == HALLifecycleLog.quitReason
        )
        captureEngine = nil
        voiceProcessingEngineStarted = false
        voiceProcessingTapInstalled = false
        publisherEngine = nil
        publisherSourceNode = nil
        boundPublisherOutput = nil
        voiceProcessingInput = nil
        ringBuffer = nil
        isRunning = false
        hasStarted = false
        needsRestart = false
        return true
    }

    /// A quiet window armed after the stop was issued, before its engine
    /// stops were made. Stopping an `AVAudioEngine` is an IO stop on the
    /// device it is bound to, which the window holds like any other, so
    /// neither engine is touched: the capture engine keeps its tap, and the
    /// publisher keeps rendering into the muted tap, as after an interrupted
    /// start (`keepVoiceProcessingStart`). The session has ended, so no level
    /// is reported and no configuration change observed meanwhile. The engine
    /// counts as running with a restart owed, and the owner is told, so its
    /// evaluation after the window stops what is kept here.
    private func keepEnginesWhoseStopWasHeldBack(
        holdToken: UInt64,
        loggingItAs interruption: HALLifecycleLog.Operation
    ) {
        if let captureEngine {
            recordEngine(
                .processedMicrophoneVoiceProcessingEngine,
                interruption,
                engine: captureEngine,
                expected: voiceProcessingInput,
                generation: holdToken
            )
        }
        if let publisherEngine {
            recordEngine(
                .processedMicrophonePublisherEngine,
                interruption,
                publisher: publisherEngine,
                expected: boundPublisherOutput.map { (deviceID: $0.deviceID, transport: $0.transport) },
                generation: holdToken
            )
        }
        isRunning = true
        hasStarted = false
        needsRestart = true
        onNeedsRestart?(.stopInterrupted)
    }

    /// A quiet window armed while the voice-processing engine's stop was on
    /// its way, before the publisher's. The capture engine is stopped and
    /// retired, its tap removed. The publisher is not touched: with nothing
    /// writing to the ring it renders silence into the muted tap, as after an
    /// interrupted start. It stays with its source node, its ring and its
    /// bound output, an `interrupt-stop` line is written for it (`interrupt`
    /// for a stop a start makes), and the engine counts as running with a
    /// restart owed, so the owner's evaluation after the window stops it.
    private func keepPublisherWhoseStopWasHeldBack(
        holdToken: UInt64,
        loggingItAs interruption: HALLifecycleLog.Operation
    ) {
        retire([captureEngine.map { $0 as AnyObject }])
        captureEngine = nil
        voiceProcessingEngineStarted = false
        voiceProcessingTapInstalled = false
        voiceProcessingInput = nil
        if let publisherEngine {
            recordEngine(
                .processedMicrophonePublisherEngine,
                interruption,
                publisher: publisherEngine,
                expected: boundPublisherOutput.map { (deviceID: $0.deviceID, transport: $0.transport) },
                generation: holdToken
            )
        }
        isRunning = true
        hasStarted = false
        needsRestart = true
        onNeedsRestart?(.stopInterrupted)
    }

    func setProcessingMode(_ processingMode: MicrophoneProcessingMode) {
        guard configuration.processingMode != processingMode else {
            return
        }
        configuration.processingMode = processingMode
    }

    func setDigitalGainDecibels(_ decibels: Float) {
        let sanitized = Self.sanitizedGain(decibels)
        configuration.digitalGainDecibels = sanitized
        gainScalar.store(DigitalGain.amplitude(decibels: sanitized))
    }

    // MARK: IOProc capture (processing off and WebRTC)

    private func startDeviceCapture(sessionID: UUID, holdToken: UInt64) {
        isRunning = true
        let deviceCapture = deviceCapture
        let deviceID = configuration.inputDeviceID
        let gainScalar = gainScalar
        let webRTCLevel = Self.webRTCLevel(for: configuration.processingMode)
        deviceCapture.begin(session: sessionID)
        deviceCapture.queue.async { [weak self] in
            guard let result = deviceCapture.prepare(
                deviceID: deviceID,
                session: sessionID,
                gainScalar: gainScalar,
                webRTCLevel: webRTCLevel,
                holdToken: holdToken,
                onInvalidated: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        self?.deviceCaptureInvalidated(sessionID: sessionID)
                    }
                }
            ) else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.deviceCapturePrepared(
                    result,
                    sessionID: sessionID,
                    holdToken: holdToken
                )
            }
        }
    }

    /// The IOProc exists but has not started. The publisher is built here on
    /// the main thread, and the IOProc is then started on the lifecycle queue.
    private func deviceCapturePrepared(
        _ outcome: ProcessedMicrophoneDeviceCapture.PrepareOutcome,
        sessionID: UUID,
        holdToken: UInt64
    ) {
        guard self.sessionID == sessionID else {
            // stop() has already asked the lifecycle queue to release it.
            return
        }

        let prepared: ProcessedMicrophoneDeviceCapture.Prepared
        switch outcome {
        case let .failed(error):
            failDeviceCapture(error, holdToken: holdToken)
            return
        case .interrupted:
            requestRestart(.startInterrupted)
            return
        case let .prepared(value):
            prepared = value
        }

        // The publisher engine opens the output chosen for it. Starting it after a
        // quiet window armed, or once the owner no longer wants this start,
        // would be an IO start while a device is still changing. The IOProc
        // created for it stays, not started, until the owner's restart
        // releases it after the window.
        guard startMayTakeNextStep(holdToken: holdToken) else {
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .interrupt,
                id: configuration.inputDeviceID,
                generation: holdToken
            )
            requestRestart(.startInterrupted)
            return
        }

        let publisher: (engine: any ProcessedMicrophonePublisherEngine, sourceNode: AVAudioSourceNode)
        do {
            publisher = try makePublisher(
                format: prepared.monoFormat,
                ringBuffer: prepared.ringBuffer,
                output: prepared.publisherOutput,
                generation: holdToken,
                mayProceed: { startMayTakeNextStep(holdToken: holdToken) }
            )
        } catch let interrupted as PublisherStartInterrupted {
            // A quiet window armed, or the owner stopped wanting this start,
            // while the publisher was being built. Nothing is stopped inside
            // it: the publisher, prepared or started or neither, and the
            // IOProc created for this start stay until the owner's restart
            // releases them after the window.
            // An AVFAudio call that raised is kept the same way: its device
            // is being rebound, and that change arms the window here.
            publisherEngine = interrupted.engine
            publisherSourceNode = interrupted.sourceNode
            publisherEngineStarted = interrupted.started
            boundPublisherOutput = prepared.publisherOutput
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .interrupt,
                id: configuration.inputDeviceID,
                generation: holdToken,
                reason: interrupted.raised == nil ? nil : HALLifecycleLog.engineRaisedReason
            )
            guard let raised = interrupted.raised else {
                requestRestart(.startInterrupted)
                return
            }
            requestRestart(.configurationChanged)
            countEngineRaise(raised, sessionID: sessionID)
            return
        } catch let ProcessedMicrophoneEngineError.outputUnavailable(outputDeviceID) {
            // The output reads no usable hardware format: a device is being
            // reconfigured or removed. Nothing was started. The IOProc created
            // for this start stays, not started, until the owner's restart
            // releases it after the quiet window this request arms.
            requestRestart(.outputUnavailable(outputDeviceID))
            return
        } catch let error as ProcessedMicrophoneEngineError {
            failPreparedDeviceCapture(error, holdToken: holdToken)
            return
        } catch {
            failPreparedDeviceCapture(
                .operationFailed(
                    localized("Starting the processed microphone"),
                    Self.errorDetail(error)
                ),
                holdToken: holdToken
            )
            return
        }

        publisherEngine = publisher.engine
        publisherSourceNode = publisher.sourceNode
        publisherEngineStarted = true
        boundPublisherOutput = prepared.publisherOutput
        ringBuffer = prepared.ringBuffer
        tapContext = prepared.tapContext
        startLevelTimer(
            sessionID: sessionID,
            ringBuffer: prepared.ringBuffer,
            tapContext: prepared.tapContext
        )
        installConfigurationObservers(voiceProcessingEngine: nil, publisher: publisher.engine)

        let deviceCapture = deviceCapture
        deviceCapture.queue.async { [weak self] in
            guard let outcome = deviceCapture.startIO(
                session: sessionID,
                holdToken: holdToken
            ) else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.deviceCaptureStarted(
                    outcome,
                    sessionID: sessionID,
                    holdToken: holdToken
                )
            }
        }
    }

    private func deviceCaptureStarted(
        _ outcome: ProcessedMicrophoneDeviceCapture.StartOutcome,
        sessionID: UUID,
        holdToken: UInt64
    ) {
        guard self.sessionID == sessionID else {
            return
        }
        switch outcome {
        case .started:
            hasStarted = true
            consecutiveEngineRaises = 0
            onStarted?()
        case .interrupted:
            // The publisher keeps rendering silence into the muted tap until
            // the owner's restart stops it after the window.
            requestRestart(.startInterrupted)
        case let .refused(refusal):
            failReleasedDeviceCapture(.inputRefused(refusal), holdToken: holdToken)
        case let .failed(status):
            failReleasedDeviceCapture(
                .operationFailed(
                    localized("Starting microphone processing"),
                    "Core Audio status \(status)"
                ),
                holdToken: holdToken
            )
        }
    }

    /// A start whose IOProc the capture queue has already released. Failing
    /// it also stops the publisher engine, synchronously, so that happens
    /// only while no quiet window has armed since the start was issued.
    /// Otherwise the publisher keeps rendering silence into the muted tap,
    /// and the owner's restart after the window stops it.
    private func failReleasedDeviceCapture(
        _ error: ProcessedMicrophoneEngineError,
        holdToken: UInt64
    ) {
        guard holdGeneration.isCurrent(holdToken) else {
            requestRestart(.startInterrupted)
            return
        }
        failDeviceCapture(error, holdToken: holdToken)
    }

    /// A start whose publisher build failed, with its IOProc created and not
    /// started. Failing it releases that IOProc, and reports a failure that
    /// turns the processing mode off or halts the feature. The build runs on
    /// the main thread through calls that wait in coreaudiod while a device
    /// changes, which is when a listener advances the generation, and a
    /// build that fails then most likely fails because of that change. So
    /// when a quiet window has armed since the start was issued, nothing is
    /// released inside it and nothing is reported: an `interrupt` line is
    /// written, and the IOProc stays, unstarted, until the owner's restart
    /// releases it after the window and starts again in the same mode. The
    /// publisher a failed build made is already stopped or was never started
    /// (`makePublisher`).
    private func failPreparedDeviceCapture(
        _ error: ProcessedMicrophoneEngineError,
        holdToken: UInt64
    ) {
        guard holdGeneration.isCurrent(holdToken) else {
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .interrupt,
                id: configuration.inputDeviceID,
                generation: holdToken
            )
            requestRestart(.startInterrupted)
            return
        }
        failDeviceCapture(error, holdToken: holdToken)
    }

    /// The capture kept its IOProc because a quiet window armed after the
    /// stop was issued. Unless a newer start or stop took over, the engine
    /// counts as running again with a restart owed, so the owner's evaluation
    /// after the window stops or rebuilds it.
    private func deviceCaptureReleaseInterrupted(sessionID: UUID) {
        guard self.sessionID == sessionID, !isRunning else {
            return
        }
        isRunning = true
        requestRestart(.stopInterrupted)
    }

    /// A listener saw the device die or change its format. The capture has
    /// already stopped passing samples on; the owner rebuilds it.
    private func deviceCaptureInvalidated(sessionID: UUID) {
        guard self.sessionID == sessionID else {
            return
        }
        requestRestart(.configurationChanged)
    }

    /// Whether a start under way may take its next HAL step: no quiet window
    /// has armed since it was issued, and the owner still wants it.
    private func startMayTakeNextStep(holdToken: UInt64) -> Bool {
        holdGeneration.isCurrent(holdToken) && (startMayProceed?() ?? true)
    }

    /// Counts a start an AVFAudio raise ended, whose engines the caller has
    /// kept with a restart requested. The last raise in a row
    /// (`maximumConsecutiveEngineRaises`) is also reported as a failure of
    /// the start, as it was before raises were kept, so the owner turns the
    /// mode off or halts; what the start built still stays until the release
    /// after the window.
    private func countEngineRaise(_ raised: (step: String, detail: String), sessionID: UUID) {
        consecutiveEngineRaises += 1
        guard consecutiveEngineRaises >= Self.maximumConsecutiveEngineRaises else {
            return
        }
        consecutiveEngineRaises = 0
        report(.operationFailed(raised.step, raised.detail), sessionID: sessionID)
    }

    /// Releases whatever the failed start built, then reports it. The release
    /// is part of the start and carries its generation, so it stops before
    /// its next HAL call if a quiet window has armed since the start was
    /// issued. When that holds the engines' stop back, the owner has been
    /// asked for a restart instead, and the failure is not reported.
    private func failDeviceCapture(_ error: ProcessedMicrophoneEngineError, holdToken: UInt64) {
        guard stop(holdToken: holdToken, loggingAnInterruptionAs: .interrupt) else {
            return
        }
        onError?(error)
    }

    // MARK: Voice-processing capture (Apple)

    /// The default devices as the capture queue read them, uncached.
    private struct VoiceProcessingDevices {
        let inputDeviceID: AudioDeviceID
        let outputDeviceID: AudioDeviceID
        let input: AudioDeviceTransportInfo?
        let output: AudioDeviceTransportInfo?
        /// Whether the output device list read in the same turn lists a
        /// Bluetooth or Bluetooth LE device; nil when it could not be read.
        /// A Bluetooth device with no output is not in that list; the owner's
        /// decision from the poll covers it.
        let bluetoothDevicePresent: Bool?
        /// The first Bluetooth device in that list, for the log.
        let bluetoothOutput: AudioDevice?
        /// The output the publisher engine is to be bound to, read in the
        /// same turn.
        let publisherOutput: PublisherOutputReading
    }

    /// Voice Processing I/O opens whatever the default input and output are
    /// when it starts, not a device this class names. The owner decided from
    /// its latest poll, which can be a quarter of a second old plus the
    /// meter's release, so both defaults and their transports, and the output
    /// devices, are read again, uncached, off the main thread. The engine
    /// starts only if the defaults are still the devices the start was
    /// decided on, neither involves Bluetooth, and no Bluetooth output device
    /// is listed.
    private func startVoiceProcessingAfterReadingDevices(sessionID: UUID, holdToken: UInt64) {
        isRunning = true
        let halCalls = halCalls
        deviceCapture.queue.async { [weak self] in
            let inputDeviceID = halCalls.defaultInputDeviceID()
                ?? AudioDeviceID(kAudioObjectUnknown)
            let outputDeviceID = halCalls.defaultOutputDeviceID()
                ?? AudioDeviceID(kAudioObjectUnknown)
            let listedOutputs = halCalls.outputDevices()
            let devices = VoiceProcessingDevices(
                inputDeviceID: inputDeviceID,
                outputDeviceID: outputDeviceID,
                input: halCalls.transportInfo(for: inputDeviceID),
                output: halCalls.transportInfo(for: outputDeviceID),
                bluetoothDevicePresent: ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(
                    listedTransports: listedOutputs?.map(\.readTransport)
                ),
                bluetoothOutput: listedOutputs?.first { InputOpenPolicy.isBluetooth($0.transport) },
                publisherOutput: PublisherOutputReading.read(halCalls, listedOutputs: listedOutputs)
            )
            DispatchQueue.main.async { [weak self] in
                self?.voiceProcessingDevicesRead(
                    devices,
                    sessionID: sessionID,
                    holdToken: holdToken
                )
            }
        }
    }

    private func voiceProcessingDevicesRead(
        _ devices: VoiceProcessingDevices,
        sessionID: UUID,
        holdToken: UInt64
    ) {
        guard self.sessionID == sessionID else {
            return
        }
        guard startMayTakeNextStep(holdToken: holdToken) else {
            HALLifecycleLog.record(
                .processedMicrophoneSource,
                .interrupt,
                id: configuration.inputDeviceID,
                generation: holdToken
            )
            requestRestart(.startInterrupted)
            return
        }

        let check = ProcessedMicrophoneSourcePolicy.checkVoiceProcessingDevices(
            decidedInputDeviceID: configuration.inputDeviceID,
            decidedOutputDeviceID: configuration.outputDeviceID,
            inputDeviceID: devices.inputDeviceID,
            outputDeviceID: devices.outputDeviceID,
            input: devices.input,
            output: devices.output,
            bluetoothDevicePresent: devices.bluetoothDevicePresent
        )
        guard check == .unchanged else {
            let id: AudioDeviceID
            let transport: String
            if check == .refused(.bluetoothDevicePresentForVoiceProcessing), let listed = devices.bluetoothOutput {
                id = listed.id
                transport = listed.transport.logName
            } else if check.concernsOutput {
                id = devices.outputDeviceID
                transport = AudioDeviceTransportInfo.logDescription(devices.output)
            } else {
                id = devices.inputDeviceID
                transport = AudioDeviceTransportInfo.logDescription(devices.input)
            }
            HALLifecycleLog.record(
                .processedMicrophoneSource,
                .refuse,
                id: id,
                transport: transport,
                generation: holdToken
            )
            failDeviceCapture(.voiceProcessingSourceChanged(check), holdToken: holdToken)
            return
        }

        let publisherOutput: PublisherOutput
        switch devices.publisherOutput {
        case let .bound(output):
            publisherOutput = output
        case let .refused(refusal, defaultOutputID, defaultTransport):
            HALLifecycleLog.record(
                .processedMicrophonePublisherEngine,
                .refuse,
                id: defaultOutputID,
                transport: defaultTransport,
                generation: holdToken
            )
            failDeviceCapture(.publisherOutputRefused(refusal), holdToken: holdToken)
            return
        }

        // Set again once the engine runs. A failed start reports through
        // onError with nothing left running.
        isRunning = false
        startVoiceProcessingCapture(
            sessionID: sessionID,
            holdToken: holdToken,
            publisherOutput: publisherOutput,
            input: (
                deviceID: devices.inputDeviceID,
                transport: AudioDeviceTransportInfo.logDescription(devices.input)
            ),
            outputDeviceID: devices.outputDeviceID
        )
    }

    /// A voice-processing start that stopped before its next step, because a
    /// quiet window armed after it was issued or the owner no longer wants
    /// it.
    private struct VoiceProcessingStartInterrupted: Error {}

    /// Builds and starts Apple voice processing's capture engine, and its
    /// publisher, on the main thread.
    ///
    /// Before each step that opens or starts something, the start checks that
    /// no quiet window has armed since it was issued and that the owner still
    /// wants it: before the publisher is built, before the tap is installed
    /// and the engine prepared, and once more after the default devices are
    /// read, immediately before the engine starts. A start stopped there
    /// issues nothing more and releases nothing now; what it built stays until
    /// the owner's restart releases it after the window.
    ///
    /// Voice Processing I/O opens whatever the defaults are when it starts,
    /// so both default devices are read again, uncached, immediately before
    /// the engine starts and immediately after. If either has moved from the
    /// devices the start was decided on, the move is logged and the start
    /// asks for a restart (`RestartReason.sourceChanged`), which arms the
    /// window before anything is released. An output that reads no usable
    /// format asks the same way (`RestartReason.outputUnavailable`). Either
    /// is a change the HAL is still making, so nothing is stopped inside it:
    /// what the start built, a started engine included, is stopped by the
    /// owner's restart after the window, with that release's generation. A
    /// start that fails for another reason is released at once and reported,
    /// unless a window has armed since it was issued; then it is kept for the
    /// release after the window in the same way.
    ///
    /// - Parameters:
    ///   - input: The default input as read before the start, for the
    ///     engine's log lines.
    ///   - outputDeviceID: The default output as read before the start.
    private func startVoiceProcessingCapture(
        sessionID: UUID,
        holdToken: UInt64,
        publisherOutput: PublisherOutput,
        input: (deviceID: AudioDeviceID, transport: String),
        outputDeviceID: AudioDeviceID
    ) {
        let captureEngine = makeVoiceProcessingEngine()
        // What the start got as far as, so that a failed start stops it rather
        // than leaving it to deallocation, and an interrupted one keeps it for
        // the release after the window.
        var tapInstalled = false
        var builtRingBuffer: ProcessedMicrophoneRingBuffer?
        var builtTapContext: ProcessedMicrophoneTapContext?
        var builtPublisher: (engine: any ProcessedMicrophonePublisherEngine, sourceNode: AVAudioSourceNode)?
        var captureStartAttempted = false

        func proceedOrStop() throws {
            guard startMayTakeNextStep(holdToken: holdToken) else {
                throw VoiceProcessingStartInterrupted()
            }
        }

        do {
            let enabling = localized("Enabling Apple voice processing")
            try Self.catchingEngineException(enabling) {
                captureEngine.loadIONodes()
            }

            // Voice processing changes the I/O unit and must be selected while
            // the engine is stopped, before querying either node's format.
            var enableError: Error?
            try Self.catchingEngineException(enabling) {
                do {
                    try captureEngine.enableVoiceProcessing()
                } catch {
                    enableError = error
                }
            }
            if let enableError {
                throw ProcessedMicrophoneEngineError.operationFailed(
                    enabling,
                    Self.errorDetail(enableError)
                )
            }
            // Left to itself the unit follows the default input and output:
            // a headset that connects while it runs and becomes a default
            // would take the engine's IO with it, inside that headset's
            // configuration change and before any release can stop it. It
            // is bound to the devices this start checked, once enabling has
            // replaced the unit and before anything reads a format or
            // prepares it, and both elements are read back. A bind that did
            // not take refuses the start before anything is opened.
            let binding = localized("Selecting the processed microphone input and output devices")
            // Loading the nodes and enabling voice processing can wait in
            // coreaudiod while a device changes, as the calls before the
            // publisher's bind can. A window that armed meanwhile holds the
            // bind and everything after it: the engine, enabled and never
            // prepared, is kept for the release after the window.
            try proceedOrStop()
            var bindError: Error?
            try Self.catchingEngineException(binding) {
                do {
                    try captureEngine.bindDevices(input: input.deviceID, output: outputDeviceID)
                } catch {
                    bindError = error
                }
            }
            if let bindError {
                throw ProcessedMicrophoneEngineError.operationFailed(binding, Self.errorDetail(bindError))
            }
            let bound = try Self.catchingEngineException(binding) {
                (input: captureEngine.boundInputDeviceID, output: captureEngine.boundOutputDeviceID)
            }
            guard bound.input == input.deviceID, bound.output == outputDeviceID else {
                throw ProcessedMicrophoneEngineError.operationFailed(
                    binding,
                    "the input is device \(bound.input), not \(input.deviceID), and the output device \(bound.output), not \(outputDeviceID)"
                )
            }
            let formats = try Self.catchingEngineException(enabling) { () -> (input: AVAudioFormat, output: AVAudioFormat) in
                captureEngine.configureVoiceProcessing()
                return (captureEngine.inputFormat(), captureEngine.outputFormat())
            }
            // The paired unit opens the default output too. An output being
            // reconfigured or removed reads 0 Hz or no channels, and
            // AVAudioEngine raises, rather than failing, when it is prepared
            // or started against that. Nothing has started: the owner waits
            // the change out behind a quiet window.
            guard
                formats.output.sampleRate.isFinite,
                formats.output.sampleRate > 0,
                formats.output.channelCount > 0
            else {
                throw ProcessedMicrophoneEngineError.outputUnavailable(outputDeviceID)
            }
            let inputFormat = formats.input
            guard
                SampleRatePolicy.isUsable(inputFormat.sampleRate),
                inputFormat.channelCount > 0,
                inputFormat.commonFormat == .pcmFormatFloat32,
                !inputFormat.isInterleaved
            else {
                throw ProcessedMicrophoneEngineError.unsupportedInputFormat
            }

            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw ProcessedMicrophoneEngineError.unsupportedInputFormat
            }

            // AVAudioEngine treats the tap's bufferSize as a hint and delivers
            // 100 ms bursts on macOS regardless, so the ring has to hold
            // several bursts rather than the requested tap size.
            guard let ringBuffer = ProcessedMicrophoneRingBuffer(
                format: monoFormat,
                duration: 0.25
            ) else {
                throw ProcessedMicrophoneEngineError.unsupportedInputFormat
            }
            builtRingBuffer = ringBuffer
            let tapContext = try ProcessedMicrophoneTapContext(
                gainScalar: gainScalar,
                ringBuffer: ringBuffer,
                sampleRate: inputFormat.sampleRate,
                webRTCLevel: nil
            )
            builtTapContext = tapContext

            try proceedOrStop()
            let publisher = try makePublisher(
                format: monoFormat,
                ringBuffer: ringBuffer,
                output: publisherOutput,
                generation: holdToken,
                mayProceed: { startMayTakeNextStep(holdToken: holdToken) }
            )
            builtPublisher = publisher

            let starting = localized("Starting microphone processing")
            let tapFrameCount = AVAudioFrameCount(
                min(max(inputFormat.sampleRate * 0.02, 512), 1_024)
            )
            // Starting the publisher can take a while on the main thread.
            try proceedOrStop()
            tapInstalled = true
            // No format: the node's format at the moment of the install is
            // used. A format read before the publisher was built can be stale
            // by now, and AVFAudio raises on a format that no longer matches.
            // The tap context drops a buffer at another rate than the ring's.
            try Self.catchingEngineException(starting) {
                captureEngine.installTap(
                    bufferSize: tapFrameCount,
                    format: nil
                ) { buffer, _ in
                    tapContext.process(buffer)
                }
            }
            try prepareEngine(
                .processedMicrophoneVoiceProcessingEngine,
                step: starting,
                readingBoundDevice: { captureEngine.boundInputDeviceID },
                readingBoundOutput: { captureEngine.boundOutputDeviceID },
                expected: input,
                generation: holdToken
            ) {
                captureEngine.prepare()
            }

            try proceedOrStop()
            let beforeStart = checkVoiceProcessingDefaults(
                decidedInputDeviceID: input.deviceID,
                decidedOutputDeviceID: outputDeviceID,
                generation: holdToken
            )
            guard beforeStart == .unchanged else {
                throw ProcessedMicrophoneEngineError.voiceProcessingSourceChanged(beforeStart)
            }
            // The two reads above block while coreaudiod is busy with a
            // configuration change, and a listener can advance the generation
            // meanwhile without moving either default.
            try proceedOrStop()

            var startError: Error?
            let startFailure: Error?
            captureStartAttempted = true
            recordEngine(
                .processedMicrophoneVoiceProcessingEngine,
                .startBegin,
                engine: captureEngine,
                expected: input,
                generation: holdToken
            )
            do {
                try Self.catchingEngineException(starting) {
                    do {
                        try captureEngine.start()
                    } catch {
                        startError = error
                    }
                }
                startFailure = startError.map {
                    ProcessedMicrophoneEngineError.operationFailed(starting, Self.errorDetail($0)) as Error
                }
            } catch {
                startFailure = error
            }
            recordEngine(
                .processedMicrophoneVoiceProcessingEngine,
                .start,
                engine: captureEngine,
                expected: input,
                status: Self.startStatus(error: startError, failure: startFailure),
                generation: holdToken
            )
            if let startFailure {
                throw startFailure
            }

            // A default that moved while the engine started may already have
            // taken the engine with it.
            let afterStart = checkVoiceProcessingDefaults(
                decidedInputDeviceID: input.deviceID,
                decidedOutputDeviceID: outputDeviceID,
                generation: holdToken
            )
            guard afterStart == .unchanged else {
                throw ProcessedMicrophoneEngineError.voiceProcessingSourceChanged(afterStart)
            }

            self.captureEngine = captureEngine
            voiceProcessingEngineStarted = true
            voiceProcessingTapInstalled = true
            publisherEngine = publisher.engine
            publisherEngineStarted = true
            boundPublisherOutput = publisherOutput
            voiceProcessingInput = input
            publisherSourceNode = publisher.sourceNode
            self.ringBuffer = ringBuffer
            self.tapContext = tapContext
            isRunning = true
            consecutiveEngineRaises = 0
            startLevelTimer(
                sessionID: sessionID,
                ringBuffer: ringBuffer,
                tapContext: tapContext
            )
            installConfigurationObservers(voiceProcessingEngine: captureEngine, publisher: publisher.engine)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionID == sessionID else {
                    return
                }
                self.hasStarted = true
                self.onStarted?()
            }
        } catch {
            var keptPublisher = builtPublisher.map {
                (engine: $0.engine, sourceNode: Optional($0.sourceNode), started: true)
            }
            if let interrupted = error as? PublisherStartInterrupted {
                keptPublisher = (engine: interrupted.engine, sourceNode: interrupted.sourceNode, started: interrupted.started)
            }
            let built = BuiltVoiceProcessingStart(
                captureEngine: captureEngine,
                started: captureStartAttempted,
                tapInstalled: tapInstalled,
                ringBuffer: builtRingBuffer,
                tapContext: builtTapContext,
                publisher: keptPublisher,
                publisherOutput: publisherOutput,
                input: input
            )
            switch error {
            case let ProcessedMicrophoneEngineError.engineRaised(step, detail):
                // An AVFAudio call raised: the binding is changing under the
                // engine, and AVFAudio's own work for that change is under
                // way. Stopping and freeing the engines now would put both
                // inside it.
                keepRaisedVoiceProcessingStart(
                    built,
                    raised: (step: step, detail: detail),
                    holdToken: holdToken,
                    sessionID: sessionID
                )
            case let interrupted as PublisherStartInterrupted:
                if let raised = interrupted.raised {
                    keepRaisedVoiceProcessingStart(built, raised: raised, holdToken: holdToken, sessionID: sessionID)
                } else {
                    keepInterruptedVoiceProcessingStart(built, holdToken: holdToken)
                }
            case is VoiceProcessingStartInterrupted:
                keepInterruptedVoiceProcessingStart(built, holdToken: holdToken)
            case let ProcessedMicrophoneEngineError.outputUnavailable(outputDeviceID):
                // The output read no usable format, as one being reconfigured
                // or removed does. Nothing started, and nothing is released
                // inside that change, as for the IOProc capture: the owner's
                // restart releases it after the window this request arms.
                keepVoiceProcessingStart(built, restart: .outputUnavailable(outputDeviceID))
            case ProcessedMicrophoneEngineError.voiceProcessingSourceChanged:
                // A default moved immediately before or while the engine
                // started, and the move is already logged. Stopping the
                // engines now would put their stops inside that change.
                keepVoiceProcessingStart(built, restart: .sourceChanged)
            default:
                guard holdGeneration.isCurrent(holdToken) else {
                    // A window armed while the start was on its way: its
                    // release would be inside that window.
                    keepInterruptedVoiceProcessingStart(built, holdToken: holdToken)
                    return
                }
                guard releaseFailedVoiceProcessingStart(
                    captureEngine: captureEngine,
                    generation: holdToken,
                    captureStartAttempted: captureStartAttempted,
                    input: input,
                    tapInstalled: tapInstalled,
                    ringBuffer: builtRingBuffer,
                    publisher: builtPublisher,
                    publisherOutput: publisherOutput
                ) else {
                    // A window armed inside the capture engine's stop, and the
                    // publisher is kept for the release after it. Not reported
                    // as a failure, as for a start a window interrupted.
                    return
                }
                report(
                    error as? ProcessedMicrophoneEngineError ?? .operationFailed(
                        localized("Starting the processed microphone"),
                        Self.errorDetail(error)
                    ),
                    sessionID: sessionID
                )
            }
        }
    }

    /// Main thread. Reads both default devices again, uncached, immediately
    /// before or after the voice-processing engine starts, and compares them
    /// by ID with the devices the start was decided on. A moved default is
    /// logged as a `refuse` naming the device it moved to, with
    /// `transport=moved`: a device that has just become the default may still
    /// be reconfiguring, so its transport is not read here.
    private func checkVoiceProcessingDefaults(
        decidedInputDeviceID: AudioDeviceID,
        decidedOutputDeviceID: AudioDeviceID,
        generation: UInt64
    ) -> VoiceProcessingDeviceCheck {
        let inputDeviceID = halCalls.defaultInputDeviceID() ?? AudioDeviceID(kAudioObjectUnknown)
        let outputDeviceID = halCalls.defaultOutputDeviceID() ?? AudioDeviceID(kAudioObjectUnknown)
        let check = VoiceProcessingDeviceCheck.defaults(
            decidedInputDeviceID: decidedInputDeviceID,
            decidedOutputDeviceID: decidedOutputDeviceID,
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID
        )
        if check != .unchanged {
            HALLifecycleLog.record(
                .processedMicrophoneSource,
                .refuse,
                id: check == .inputMoved ? inputDeviceID : outputDeviceID,
                transport: "moved",
                generation: generation
            )
        }
        return check
    }

    /// What an Apple voice processing start got as far as building.
    private struct BuiltVoiceProcessingStart {
        let captureEngine: any VoiceProcessingCaptureEngine
        /// Whether the capture engine's start was issued.
        let started: Bool
        let tapInstalled: Bool
        let ringBuffer: ProcessedMicrophoneRingBuffer?
        let tapContext: ProcessedMicrophoneTapContext?
        /// With whether the publisher's start was issued.
        let publisher: (engine: any ProcessedMicrophonePublisherEngine, sourceNode: AVAudioSourceNode?, started: Bool)?
        let publisherOutput: PublisherOutput
        let input: (deviceID: AudioDeviceID, transport: String)
    }

    /// A quiet window armed, or the owner stopped wanting this start, while
    /// it was on its way. Logged as `interrupt`, and kept for the release
    /// after the window (`keepVoiceProcessingStart`).
    private func keepInterruptedVoiceProcessingStart(_ built: BuiltVoiceProcessingStart, holdToken: UInt64) {
        HALLifecycleLog.record(
            .processedMicrophoneSource,
            .interrupt,
            id: built.input.deviceID,
            generation: holdToken
        )
        keepVoiceProcessingStart(built, restart: .startInterrupted)
    }

    /// An AVFAudio call of the start raised. Logged as `interrupt` with
    /// `reason=engine-raised`, kept for the release after the window, which
    /// the restart this requests arms (`processing-invalidated`), and
    /// counted (`countEngineRaise`).
    private func keepRaisedVoiceProcessingStart(
        _ built: BuiltVoiceProcessingStart,
        raised: (step: String, detail: String),
        holdToken: UInt64,
        sessionID: UUID
    ) {
        HALLifecycleLog.record(
            .processedMicrophoneSource,
            .interrupt,
            id: built.input.deviceID,
            generation: holdToken,
            reason: HALLifecycleLog.engineRaisedReason
        )
        keepVoiceProcessingStart(built, restart: .configurationChanged)
        countEngineRaise(raised, sessionID: sessionID)
    }

    /// Keeps what a start that did not complete built, and asks the owner
    /// for a restart. Nothing further is issued, and nothing is stopped now:
    /// the capture engine stays as it is, started or not, with its tap if one
    /// was installed, and the publisher keeps rendering silence into the
    /// muted tap if it was started. No level timer runs and no start is
    /// reported. The engine counts as running with a restart owed, so the
    /// owner stops everything after the window, with stop lines only for an
    /// engine whose start was issued.
    private func keepVoiceProcessingStart(_ built: BuiltVoiceProcessingStart, restart reason: RestartReason) {
        captureEngine = built.captureEngine
        voiceProcessingEngineStarted = built.started
        voiceProcessingTapInstalled = built.tapInstalled
        voiceProcessingInput = built.input
        if let publisher = built.publisher {
            publisherEngine = publisher.engine
            publisherSourceNode = publisher.sourceNode
            publisherEngineStarted = publisher.started
            boundPublisherOutput = built.publisherOutput
        }
        ringBuffer = built.ringBuffer
        // The tap, if installed, reads this until the release removes it.
        tapContext = built.tapContext
        isRunning = true
        requestRestart(reason)
    }

    // MARK: Shared

    /// Builds and starts the publisher engine, bound to `output`.
    ///
    /// Every AVFAudio call goes through `catchingEngineException`, and the
    /// output's hardware format is checked before anything is connected to
    /// it. A device being reconfigured or removed reads 0 Hz or no channels,
    /// and AVAudioEngine raises an exception, rather than failing, when it is
    /// connected or started against that.
    ///
    /// - Throws: `outputUnavailable` for an output with no usable format, and
    ///   `operationFailed` for a failed or raising call, and for an output
    ///   node that could not be bound to `output`. Nothing is left running
    ///   either way, and the engine a failed build made is stopped but not
    ///   freed (`retire`).
    ///
    /// - Parameter mayProceed: Asked immediately before the output is bound,
    ///   before the engine is prepared, before it is started, and before a
    ///   start that failed is stopped: whether no quiet window has armed
    ///   since the start was issued and the owner still wants it. The reads
    ///   before each of those block while coreaudiod is busy with a
    ///   configuration change, and a listener can advance the generation
    ///   meanwhile. When it says no, nothing more is called, nothing is
    ///   stopped, and `PublisherStartInterrupted` hands the engine to the
    ///   caller, which keeps it for the release after the window.
    func makePublisher(
        format: AVAudioFormat,
        ringBuffer: ProcessedMicrophoneRingBuffer,
        output: PublisherOutput,
        generation: UInt64,
        mayProceed: () -> Bool = { true }
    ) throws -> (engine: any ProcessedMicrophonePublisherEngine, sourceNode: AVAudioSourceNode) {
        let engine = makePublisherEngine()
        let progress = PublisherBuildProgress()
        do {
            return try buildPublisher(
                engine,
                format: format,
                ringBuffer: ringBuffer,
                output: output,
                generation: generation,
                mayProceed: mayProceed,
                progress: progress
            )
        } catch let interrupted as PublisherStartInterrupted {
            throw interrupted
        } catch let ProcessedMicrophoneEngineError.engineRaised(step, detail) {
            // AVFAudio raises while a device is rebound under the engine, and
            // its own listener work for that change is then under way:
            // neither stopped nor freed now.
            throw PublisherStartInterrupted(
                engine: engine,
                sourceNode: progress.sourceNode,
                started: progress.startIssued,
                raised: (step: step, detail: detail)
            )
        } catch {
            // The engine keeps the source node it attached.
            retire([engine as AnyObject])
            throw error
        }
    }

    /// A publisher build that stopped before its next step, because a quiet
    /// window armed after the start was issued, the owner no longer wants
    /// it, or an AVFAudio call raised. Nothing was stopped: the caller keeps
    /// `engine`, and the source node attached to it, until the release after
    /// the window stops it, with stop lines only when `started`.
    struct PublisherStartInterrupted: Error {
        let engine: any ProcessedMicrophonePublisherEngine
        let sourceNode: AVAudioSourceNode?
        /// Whether the engine's start was issued.
        let started: Bool
        /// The step whose AVFAudio call raised, and the exception; nil when a
        /// quiet window armed or the owner stopped wanting the start.
        var raised: (step: String, detail: String)?
    }

    /// How far a publisher build got, for a build an AVFAudio raise ended.
    private final class PublisherBuildProgress {
        var sourceNode: AVAudioSourceNode?
        var startIssued = false
    }

    private func buildPublisher(
        _ engine: any ProcessedMicrophonePublisherEngine,
        format: AVAudioFormat,
        ringBuffer: ProcessedMicrophoneRingBuffer,
        output: PublisherOutput,
        generation: UInt64,
        mayProceed: () -> Bool,
        progress: PublisherBuildProgress
    ) throws -> (engine: any ProcessedMicrophonePublisherEngine, sourceNode: AVAudioSourceNode) {
        let operation = localized("Starting processed microphone output")
        let binding = localized("Selecting the processed microphone output device")
        try Self.catchingEngineException(binding) {
            engine.loadOutputNode()
        }
        guard mayProceed() else {
            throw PublisherStartInterrupted(engine: engine, sourceNode: nil, started: false)
        }

        // Bound before anything reads the output's format or connects to it,
        // so the engine never opens the default output and cannot follow it
        // onto a Bluetooth headset. This is AUAudioUnit's device selection for
        // an I/O unit on macOS, reached through the node's auAudioUnit, and
        // the ID read back must be the chosen device.
        var bindError: Error?
        try Self.catchingEngineException(binding) {
            do {
                try engine.bindOutput(to: output.deviceID)
            } catch {
                bindError = error
            }
        }
        if let bindError {
            throw ProcessedMicrophoneEngineError.operationFailed(
                binding,
                Self.errorDetail(bindError)
            )
        }
        let boundDeviceID = try Self.catchingEngineException(binding) {
            engine.boundOutputDeviceID
        }
        guard boundDeviceID == output.deviceID else {
            throw ProcessedMicrophoneEngineError.operationFailed(
                binding,
                "the output is device \(boundDeviceID), not \(output.deviceID)"
            )
        }

        let outputFormat = try Self.catchingEngineException(operation) {
            engine.outputFormat()
        }
        guard
            outputFormat.sampleRate.isFinite,
            outputFormat.sampleRate > 0,
            outputFormat.channelCount > 0
        else {
            throw ProcessedMicrophoneEngineError.outputUnavailable(output.deviceID)
        }

        let sourceNode = try Self.catchingEngineException(operation) {
            AVAudioSourceNode(format: format) {
                isSilence, _, frameCount, outputData in
                let framesRead = ringBuffer.read(
                    into: outputData,
                    frameCount: Int(frameCount)
                )
                isSilence.pointee = ObjCBool(framesRead == 0)
                return noErr
            }
        }
        progress.sourceNode = sourceNode
        let expected = (deviceID: output.deviceID, transport: output.transport)
        try Self.catchingEngineException(operation) {
            engine.attachAndConnect(sourceNode, format: format)
        }
        // The output was read on a lifecycle queue, and the start has hopped
        // to the main thread since. An output other than a built-in one, such
        // as an aggregate default output, can gain a Bluetooth sub-device in
        // between with no default or topology change the window sees. Its
        // transport is read again now, uncached, on the main thread, before
        // the prepare, which can already create the I/O unit's IOProc on it;
        // a built-in output is not read.
        if PublisherOutputPolicy.needsReadBeforeStart(output.info) {
            let current = halCalls.transportInfo(for: output.deviceID)
            guard PublisherOutputPolicy.isStillEligibleBeforeStart(deviceID: output.deviceID, current: current) else {
                HALLifecycleLog.record(
                    .processedMicrophonePublisherEngine,
                    .refuse,
                    id: output.deviceID,
                    transport: AudioDeviceTransportInfo.logDescription(current),
                    generation: generation
                )
                // Nothing was prepared or started, so nothing is left to stop.
                // The owner arms the window and tries again after it.
                throw ProcessedMicrophoneEngineError.outputUnavailable(output.deviceID)
            }
        }

        // The reads above block while coreaudiod is busy with a
        // configuration change, and prepare() can already create the I/O
        // unit's IOProc on the output.
        guard mayProceed() else {
            throw PublisherStartInterrupted(engine: engine, sourceNode: sourceNode, started: false)
        }
        try prepareEngine(
            .processedMicrophonePublisherEngine,
            step: operation,
            readingBoundDevice: { engine.boundOutputDeviceID },
            expected: expected,
            generation: generation
        ) {
            engine.prepare()
        }

        guard mayProceed() else {
            throw PublisherStartInterrupted(engine: engine, sourceNode: sourceNode, started: false)
        }
        recordEngine(
            .processedMicrophonePublisherEngine,
            .startBegin,
            publisher: engine,
            expected: expected,
            generation: generation
        )
        var startError: Error?
        let startFailure: Error?
        progress.startIssued = true
        do {
            try Self.catchingEngineException(operation) {
                do {
                    try engine.start()
                } catch {
                    startError = error
                }
            }
            startFailure = startError.map {
                ProcessedMicrophoneEngineError.operationFailed(operation, Self.errorDetail($0)) as Error
            }
        } catch {
            startFailure = error
        }
        recordEngine(
            .processedMicrophonePublisherEngine,
            .start,
            publisher: engine,
            expected: expected,
            status: Self.startStatus(error: startError, failure: startFailure),
            generation: generation
        )
        if let startFailure {
            if case ProcessedMicrophoneEngineError.engineRaised = startFailure {
                // A start that raised is kept, not stopped: see
                // `makePublisher`.
                throw startFailure
            }
            // A start that failed inside a window armed since it was issued
            // is not stopped inside it either.
            guard mayProceed() else {
                throw PublisherStartInterrupted(engine: engine, sourceNode: sourceNode, started: true)
            }
            recordEngine(
                .processedMicrophonePublisherEngine,
                .stopBegin,
                publisher: engine,
                expected: expected,
                generation: generation
            )
            let stopped = (try? catchingObjCException { engine.stop() }) != nil
            recordEngine(
                .processedMicrophonePublisherEngine,
                .stop,
                publisher: engine,
                expected: expected,
                status: stopped ? noErr : kAudioHardwareUnspecifiedError,
                generation: generation
            )
            throw startFailure
        }
        return (engine, sourceNode)
    }

    /// Runs an engine's `prepare()` between its `prepare-begin` and `prepare`
    /// lines. `prepare()` allocates the I/O unit's resources, and can create
    /// its IOProc on the bound device, so it is bracketed like a start. A call
    /// that raised is logged with `kAudioHardwareUnspecifiedError` and thrown
    /// as a failure of `step`.
    private func prepareEngine(
        _ object: HALLifecycleLog.Object,
        step: String,
        readingBoundDevice: () -> AUAudioObjectID,
        readingBoundOutput: (() -> AUAudioObjectID)? = nil,
        expected: (deviceID: AudioDeviceID, transport: String),
        generation: UInt64,
        _ prepare: () -> Void
    ) throws {
        recordEngine(
            object,
            .prepareBegin,
            readingBoundDevice: readingBoundDevice,
            readingBoundOutput: readingBoundOutput,
            expected: expected,
            status: noErr,
            generation: generation,
            reason: nil
        )
        var failure: Error?
        do {
            try Self.catchingEngineException(step, prepare)
        } catch {
            failure = error
        }
        recordEngine(
            object,
            .prepare,
            readingBoundDevice: readingBoundDevice,
            readingBoundOutput: readingBoundOutput,
            expected: expected,
            status: failure == nil ? noErr : kAudioHardwareUnspecifiedError,
            generation: generation,
            reason: nil
        )
        if let failure {
            throw failure
        }
    }

    /// Writes a hal-lifecycle line for an engine prepare, start or stop, the
    /// begin line immediately before any of them, or a configuration change, with the
    /// device its I/O node is bound to, read back from the node's audio unit
    /// at that moment: the output for the publisher, the input for Apple
    /// voice processing. The transport is the one read before the start while
    /// the ID still matches. A device the framework moved the engine to is
    /// not read: these lines are written on the main thread, in the
    /// configuration-change observer too, which is exactly when a
    /// reconfiguring device may leave coreaudiod slow to answer. Such a line
    /// carries `transport=moved`, or `unbound` when no device was expected,
    /// and its `id=` still names where the engine went.
    private func recordEngine(
        _ object: HALLifecycleLog.Object,
        _ operation: HALLifecycleLog.Operation,
        engine: any VoiceProcessingCaptureEngine,
        expected: (deviceID: AudioDeviceID, transport: String)?,
        status: OSStatus = noErr,
        generation: UInt64?,
        reason: String? = nil
    ) {
        recordEngine(
            object,
            operation,
            readingBoundDevice: { engine.boundInputDeviceID },
            readingBoundOutput: { engine.boundOutputDeviceID },
            expected: expected,
            status: status,
            generation: generation,
            reason: reason
        )
    }

    /// The same for the publisher engine, which reads the output it is bound
    /// to.
    private func recordEngine(
        _ object: HALLifecycleLog.Object,
        _ operation: HALLifecycleLog.Operation,
        publisher: any ProcessedMicrophonePublisherEngine,
        expected: (deviceID: AudioDeviceID, transport: String)?,
        status: OSStatus = noErr,
        generation: UInt64?,
        reason: String? = nil
    ) {
        recordEngine(
            object,
            operation,
            readingBoundDevice: { publisher.boundOutputDeviceID },
            expected: expected,
            status: status,
            generation: generation,
            reason: reason
        )
    }

    /// - Parameter readingBoundOutput: For Apple voice processing, the device
    ///   its unit's output element is bound to, written as `output=`.
    private func recordEngine(
        _ object: HALLifecycleLog.Object,
        _ operation: HALLifecycleLog.Operation,
        readingBoundDevice: () -> AUAudioObjectID,
        readingBoundOutput: (() -> AUAudioObjectID)? = nil,
        expected: (deviceID: AudioDeviceID, transport: String)?,
        status: OSStatus,
        generation: UInt64?,
        reason: String?
    ) {
        let bound = (try? catchingObjCException { () -> AUAudioObjectID in
            readingBoundDevice()
        }) ?? AudioObjectID(kAudioObjectUnknown)
        let boundOutput = readingBoundOutput.map { read in
            (try? catchingObjCException { () -> AUAudioObjectID in
                read()
            }) ?? AudioObjectID(kAudioObjectUnknown)
        }
        let transport: String
        if let expected, bound == expected.deviceID {
            transport = expected.transport
        } else if bound == kAudioObjectUnknown {
            transport = "unread"
        } else {
            transport = expected == nil ? "unbound" : "moved"
        }
        HALLifecycleLog.record(
            object,
            operation,
            id: bound,
            transport: transport,
            status: status,
            generation: generation,
            reason: reason,
            output: boundOutput
        )
    }

    /// The status for an engine's start line: `noErr` for a start that
    /// succeeded, the error's code for one that returned an error, and
    /// `kAudioHardwareUnspecifiedError` for one that raised.
    private static func startStatus(error: Error?, failure: Error?) -> OSStatus {
        guard failure != nil else {
            return noErr
        }
        guard let error else {
            return kAudioHardwareUnspecifiedError
        }
        return OSStatus(truncatingIfNeeded: (error as NSError).code)
    }

    /// Runs AVFAudio calls, turning an Objective-C exception they raise into
    /// `engineRaised` for `operation`.
    @discardableResult
    private static func catchingEngineException<T>(
        _ operation: @autoclosure () -> String,
        _ body: () -> T
    ) throws -> T {
        do {
            return try catchingObjCException(body)
        } catch let exception as CaughtObjCException {
            throw ProcessedMicrophoneEngineError.engineRaised(
                operation(),
                exception.detail
            )
        }
    }

    /// Stops what a failed Apple voice processing start got as far as
    /// building, with a stop line for each engine whose start was issued. A
    /// stop that raises is dropped: the engines are released either way.
    ///
    /// The caller has compared the generation before the capture engine's
    /// stop. That stop can wait in coreaudiod while a device change begins,
    /// so the generation is compared again before the publisher's: when a
    /// window has armed meanwhile, the publisher is not stopped. It is kept,
    /// rendering silence into the muted tap, with an `interrupt` line, and a
    /// restart is asked for, so the owner stops it after the window.
    ///
    /// - Returns: False when the publisher was kept that way. The failure is
    ///   then not reported, as for a start a window interrupted.
    private func releaseFailedVoiceProcessingStart(
        captureEngine: any VoiceProcessingCaptureEngine,
        generation: UInt64,
        captureStartAttempted: Bool,
        input: (deviceID: AudioDeviceID, transport: String),
        tapInstalled: Bool,
        ringBuffer: ProcessedMicrophoneRingBuffer?,
        publisher: (engine: any ProcessedMicrophonePublisherEngine, sourceNode: AVAudioSourceNode)?,
        publisherOutput: PublisherOutput
    ) -> Bool {
        // Stopped, not freed, as `stopEngines` does.
        defer {
            retire([captureEngine as AnyObject])
        }
        if captureStartAttempted {
            recordEngine(
                .processedMicrophoneVoiceProcessingEngine,
                .stopBegin,
                engine: captureEngine,
                expected: input,
                generation: generation
            )
        }
        let captureStopped = (try? catchingObjCException { captureEngine.stop() }) != nil
        if captureStartAttempted {
            recordEngine(
                .processedMicrophoneVoiceProcessingEngine,
                .stop,
                engine: captureEngine,
                expected: input,
                status: captureStopped ? noErr : kAudioHardwareUnspecifiedError,
                generation: generation
            )
        }
        if tapInstalled {
            _ = try? catchingObjCException { captureEngine.removeTap() }
        }
        guard let publisher else {
            return true
        }
        let expected = (deviceID: publisherOutput.deviceID, transport: publisherOutput.transport)
        guard holdGeneration.isCurrent(generation) else {
            recordEngine(
                .processedMicrophonePublisherEngine,
                .interrupt,
                publisher: publisher.engine,
                expected: expected,
                generation: generation
            )
            publisherEngine = publisher.engine
            publisherSourceNode = publisher.sourceNode
            publisherEngineStarted = true
            boundPublisherOutput = publisherOutput
            self.ringBuffer = ringBuffer
            isRunning = true
            requestRestart(.startInterrupted)
            return false
        }
        recordEngine(
            .processedMicrophonePublisherEngine,
            .stopBegin,
            publisher: publisher.engine,
            expected: expected,
            generation: generation
        )
        let publisherStopped = (try? catchingObjCException { publisher.engine.stop() }) != nil
        recordEngine(
            .processedMicrophonePublisherEngine,
            .stop,
            publisher: publisher.engine,
            expected: expected,
            status: publisherStopped ? noErr : kAudioHardwareUnspecifiedError,
            generation: generation
        )
        retire([publisher.engine as AnyObject, publisher.sourceNode])
        return true
    }

    /// Observes a configuration change of the voice-processing capture
    /// engine, if there is one, and of the publisher engine, in that order.
    private func installConfigurationObservers(
        voiceProcessingEngine: (any VoiceProcessingCaptureEngine)?,
        publisher: any ProcessedMicrophonePublisherEngine
    ) {
        var observers: [NSObjectProtocol] = []
        if let voiceProcessingEngine {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: voiceProcessingEngine.notificationObject,
                    queue: .main
                ) { [weak self, weak engine = voiceProcessingEngine] _ in
                    guard let self else {
                        return
                    }
                    if let engine {
                        // The framework has stopped this engine, and may
                        // already have moved it; the line shows the device it
                        // is bound to.
                        recordEngine(
                            .processedMicrophoneVoiceProcessingEngine,
                            .invalidate,
                            engine: engine,
                            expected: voiceProcessingInput,
                            generation: holdGeneration.current
                        )
                    }
                    requestRestart(.configurationChanged)
                }
            )
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: publisher.notificationObject,
                queue: .main
            ) { [weak self, weak publisher] _ in
                guard let self else {
                    return
                }
                if let publisher {
                    recordEngine(
                        .processedMicrophonePublisherEngine,
                        .invalidate,
                        publisher: publisher,
                        expected: boundPublisherOutput.map { (deviceID: $0.deviceID, transport: $0.transport) },
                        generation: holdGeneration.current
                    )
                }
                requestRestart(.configurationChanged)
            }
        )
        configurationObservers = observers
    }

    private func startLevelTimer(
        sessionID: UUID,
        ringBuffer: ProcessedMicrophoneRingBuffer,
        tapContext: ProcessedMicrophoneTapContext
    ) {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.sessionID == sessionID else {
                return
            }

            if let status = tapContext.consumeWebRTCErrorStatus() {
                self.onError?(
                    .operationFailed(
                        localized("WebRTC noise suppression processing"),
                        "Audio Processing status \(status)"
                    )
                )
                return
            }

            if tapContext.consumeFormatMismatch() {
                // The capture engine's input was rebound to another rate
                // under its tap: a configuration change, which the owner
                // waits out before rebuilding.
                self.requestRestart(.configurationChanged)
                return
            }

            guard let update = ringBuffer.latestLevels(
                after: self.lastLevelSequence
            ) else {
                return
            }

            self.lastLevelSequence = update.sequence
            self.onInputLevel?(
                update.levels.inputRMSDecibels,
                update.levels.inputPeakDecibels
            )
            self.onOutputLevel?(
                update.levels.outputRMSDecibels,
                update.levels.outputPeakDecibels
            )
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func removeConfigurationObservers() {
        for observer in configurationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObservers.removeAll()
    }

    /// A configuration change can invalidate the capture device, the output
    /// route, or the public muted tap. Nothing is stopped here, inside the
    /// change: AVAudioEngine has already stopped the engine whose
    /// configuration changed, and stopping or restarting the other one now is
    /// exactly the kind of IO change a device that is still reconfiguring must
    /// not see. The owner restarts both, fail-closed, once the HAL has
    /// settled. An interrupted start asks the same way.
    private func requestRestart(_ reason: RestartReason) {
        guard isRunning, !needsRestart else {
            return
        }
        needsRestart = true
        onNeedsRestart?(reason)
    }

    private func report(
        _ error: ProcessedMicrophoneEngineError,
        sessionID: UUID
    ) {
        DispatchQueue.main.async { [weak self] in
            guard self?.sessionID == sessionID else {
                return
            }
            self?.onError?(error)
        }
    }

    private static func sanitized(_ configuration: Configuration) -> Configuration {
        Configuration(
            processingMode: configuration.processingMode,
            digitalGainDecibels: sanitizedGain(
                configuration.digitalGainDecibels
            ),
            inputDeviceID: configuration.inputDeviceID,
            outputDeviceID: configuration.outputDeviceID
        )
    }

    private static func webRTCLevel(
        for processingMode: MicrophoneProcessingMode
    ) -> Int32? {
        switch processingMode {
        case .webRTCLow:
            return 0
        case .webRTCModerate:
            return 1
        case .webRTCHigh:
            return 2
        case .off, .apple:
            return nil
        }
    }

    private static func errorDetail(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }

    private static func sanitizedGain(_ decibels: Float) -> Float {
        DigitalGain.clampedDecibels(decibels)
    }
}

/// The `AVAudioEngine` calls the publisher makes, so that a test can build a
/// publisher without opening an output device. `AVAudioPublisherEngine` is
/// the production conformance; each requirement is the one call it names,
/// and the caller wraps every one in `catchingObjCException`.
protocol ProcessedMicrophonePublisherEngine: AnyObject {
    /// `outputNode`, which instantiates the engine's output unit.
    func loadOutputNode()
    /// `outputNode.auAudioUnit.setDeviceID(_:)`.
    func bindOutput(to deviceID: AudioDeviceID) throws
    /// `outputNode.auAudioUnit.deviceID`.
    var boundOutputDeviceID: AudioDeviceID { get }
    /// `outputNode.outputFormat(forBus: 0)`.
    func outputFormat() -> AVAudioFormat
    /// `attach(_:)`, then `connect(_:to: mainMixerNode, format:)`.
    func attachAndConnect(_ sourceNode: AVAudioSourceNode, format: AVAudioFormat)
    /// `prepare()`.
    func prepare()
    /// `start()`.
    func start() throws
    /// `stop()`.
    func stop()
    /// The object `AVAudioEngineConfigurationChange` is posted for.
    var notificationObject: AnyObject { get }
}

/// The publisher engine the app runs.
final class AVAudioPublisherEngine: ProcessedMicrophonePublisherEngine {
    private let engine = AVAudioEngine()

    func loadOutputNode() {
        _ = engine.outputNode
    }

    func bindOutput(to deviceID: AudioDeviceID) throws {
        try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
    }

    var boundOutputDeviceID: AudioDeviceID {
        engine.outputNode.auAudioUnit.deviceID
    }

    func outputFormat() -> AVAudioFormat {
        engine.outputNode.outputFormat(forBus: 0)
    }

    func attachAndConnect(_ sourceNode: AVAudioSourceNode, format: AVAudioFormat) {
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    var notificationObject: AnyObject {
        engine
    }
}

/// The `AVAudioEngine` calls Apple voice processing's capture makes, so that a
/// test can run a voice-processing start without opening a device.
/// `AVAudioVoiceProcessingEngine` is the production conformance; each
/// requirement is the call it names, and the caller wraps every one in
/// `catchingObjCException`.
protocol VoiceProcessingCaptureEngine: AnyObject {
    /// `inputNode`, then `outputNode`. Both I/O nodes are loaded before voice
    /// processing is enabled, so that AVAudioEngine configures them as one
    /// paired Voice Processing I/O unit on macOS.
    func loadIONodes()
    /// `inputNode.setVoiceProcessingEnabled(true)`.
    func enableVoiceProcessing() throws
    /// Binds the Voice Processing I/O unit to `input` and `output`:
    /// `kAudioOutputUnitProperty_CurrentDevice` on the input node's audio
    /// unit, in global scope, element 1 for the input and element 0 for the
    /// output. Called once voice processing is enabled, which replaces the
    /// unit, and before either node's format is read or the engine is
    /// prepared. Throws an `NSError` in `NSOSStatusErrorDomain` when a set
    /// fails or the unit is unavailable.
    func bindDevices(input: AudioDeviceID, output: AudioDeviceID) throws
    /// Voice processing not bypassed, AGC off, the input not muted, and no
    /// advanced ducking of other audio.
    func configureVoiceProcessing()
    /// `inputNode.outputFormat(forBus: 0)`: what the voice-processed input
    /// delivers.
    func inputFormat() -> AVAudioFormat
    /// `outputNode.outputFormat(forBus: 0)`: the hardware format of the
    /// output the paired unit opens.
    func outputFormat() -> AVAudioFormat
    /// `inputNode.installTap(onBus: 0, bufferSize:format:block:)`; a nil
    /// format takes the node's format at the install.
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    )
    /// `prepare()`.
    func prepare()
    /// `start()`.
    func start() throws
    /// `stop()`.
    func stop()
    /// `inputNode.removeTap(onBus: 0)`.
    func removeTap()
    /// The device the unit's input element (1) is bound to, read back from
    /// `kAudioOutputUnitProperty_CurrentDevice`; `kAudioObjectUnknown` when
    /// it cannot be read.
    var boundInputDeviceID: AudioDeviceID { get }
    /// The same for the output element (0).
    var boundOutputDeviceID: AudioDeviceID { get }
    /// The object `AVAudioEngineConfigurationChange` is posted for.
    var notificationObject: AnyObject { get }
}

/// The voice-processing capture engine the app runs.
final class AVAudioVoiceProcessingEngine: VoiceProcessingCaptureEngine {
    private let engine = AVAudioEngine()

    func loadIONodes() {
        _ = engine.inputNode
        _ = engine.outputNode
    }

    func enableVoiceProcessing() throws {
        try engine.inputNode.setVoiceProcessingEnabled(true)
    }

    func configureVoiceProcessing() {
        let inputNode = engine.inputNode
        inputNode.isVoiceProcessingBypassed = false
        // Digital gain is explicit in the processed microphone; do not stack
        // Apple's automatic gain control on top of it.
        inputNode.isVoiceProcessingAGCEnabled = false
        inputNode.isVoiceProcessingInputMuted = false
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
    }

    func inputFormat() -> AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func outputFormat() -> AVAudioFormat {
        engine.outputNode.outputFormat(forBus: 0)
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    /// The Voice Processing I/O unit's elements: 1 is its input, 0 its
    /// output.
    private static let inputElement: AudioUnitElement = 1
    private static let outputElement: AudioUnitElement = 0

    func bindDevices(input: AudioDeviceID, output: AudioDeviceID) throws {
        guard let unit = engine.inputNode.audioUnit else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_Uninitialized))
        }
        for (element, deviceID) in [(Self.inputElement, input), (Self.outputElement, output)] {
            var value = deviceID
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                element,
                &value,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
    }

    var boundInputDeviceID: AudioDeviceID {
        Self.currentDevice(of: engine.inputNode.audioUnit, element: Self.inputElement)
    }

    var boundOutputDeviceID: AudioDeviceID {
        Self.currentDevice(of: engine.inputNode.audioUnit, element: Self.outputElement)
    }

    private static func currentDevice(of unit: AudioUnit?, element: AudioUnitElement) -> AudioDeviceID {
        guard let unit else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            element,
            &deviceID,
            &size
        )
        return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
    }

    var notificationObject: AnyObject {
        engine
    }
}

/// The output device the publisher engine is bound to.
struct PublisherOutput {
    let deviceID: AudioDeviceID
    /// Its transport class, for the log.
    let transport: String
    /// Its transport and active sub-devices as the read that chose it saw
    /// them.
    let info: AudioDeviceTransportInfo
}

/// The publisher engine's output, chosen from the output devices and the
/// default output read uncached immediately before the engine is built.
enum PublisherOutputReading {
    case bound(PublisherOutput)
    /// With the default output's ID and transport class, for the log.
    case refused(PublisherOutputRefusal, defaultOutputID: AudioDeviceID, defaultTransport: String)

    /// HAL reads, so a lifecycle queue runs this, never the main thread.
    static func read(_ halCalls: any HALLifecycleCalls) -> PublisherOutputReading {
        read(halCalls, listedOutputs: halCalls.outputDevices())
    }

    /// The same, with the output devices already read uncached in the same
    /// turn; nil when that list could not be read.
    static func read(
        _ halCalls: any HALLifecycleCalls,
        listedOutputs: [AudioDevice]?
    ) -> PublisherOutputReading {
        let defaultOutputID = halCalls.defaultOutputDeviceID()
            ?? AudioDeviceID(kAudioObjectUnknown)
        let defaultOutput = defaultOutputID == kAudioObjectUnknown
            ? nil
            : halCalls.transportInfo(for: defaultOutputID)
        let listed = listedOutputs?.map { device in
            ListedOutputDevice(
                deviceID: device.id,
                transport: device.readTransport,
                hasOutputChannels: device.hasOutput
            )
        }
        let survey = PublisherOutputSurvey(
            listed: listed,
            defaultOutputID: defaultOutputID,
            defaultOutput: defaultOutput
        )
        switch PublisherOutputPolicy.choose(survey) {
        case let .device(deviceID, info):
            return .bound(PublisherOutput(deviceID: deviceID, transport: info.logDescription, info: info))
        case let .refused(refusal):
            return .refused(
                refusal,
                defaultOutputID: defaultOutputID,
                defaultTransport: AudioDeviceTransportInfo.logDescription(defaultOutput)
            )
        }
    }
}

/// The HAL side of the IOProc capture: one input device, one IOProc, and the
/// listeners that invalidate it.
///
/// Everything that touches the HAL runs on `queue`: the uncached transport
/// re-read of the exact device, the format and buffer-size reads, and
/// creating, starting, stopping and destroying the IOProc and its listeners.
/// `AudioDeviceStart` can wait in coreaudiod for an unbounded time, and a wait
/// there costs this queue and nothing else. The listeners never call a HAL
/// lifecycle function; they close the capture's gate and tell the owner,
/// which decides a restart.
final class ProcessedMicrophoneDeviceCapture {
    struct Prepared {
        let monoFormat: AVAudioFormat
        let ringBuffer: ProcessedMicrophoneRingBuffer
        let tapContext: ProcessedMicrophoneTapContext
        /// The output the publisher engine is to be bound to, read in the
        /// same turn as the input.
        let publisherOutput: PublisherOutput
    }

    enum PrepareOutcome {
        case prepared(Prepared)
        /// Nothing was created, or it was released before reporting.
        case failed(ProcessedMicrophoneEngineError)
        /// A quiet window armed after the start was issued. Nothing new was
        /// created; what an earlier start left and this one could not release
        /// yet stays until the engine releases it after the window.
        case interrupted
    }

    enum StartOutcome {
        case started
        /// The IOProc was released before reporting.
        case failed(OSStatus)
        /// The transport re-read immediately before the start ruled the
        /// device out. The IOProc, never started, was released before
        /// reporting.
        case refused(InputOpenRefusal)
        /// A quiet window armed after the start was issued. The IOProc stays,
        /// not started, until the engine releases it after the window; this
        /// covers a refusal or a failed start that found the window armed.
        case interrupted
    }

    /// The scratch storage the IOProc copies channel 0 into holds at least
    /// this many frames, and at most `maximumScratchFrames`, whatever the
    /// device reports as its largest IO buffer. A larger buffer is truncated
    /// rather than written past the storage.
    private static let minimumScratchFrames = 4_096
    private static let maximumScratchFrames = 65_536

    private static let invalidatingProperties: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    ]

    let queue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.processed-microphone.capture.lifecycle",
        qos: .userInitiated
    )
    private let listenerQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.processed-microphone.capture.listener",
        qos: .userInitiated
    )
    private let halCalls: any HALLifecycleCalls
    private let holdGeneration: LifecycleHoldGeneration
    private let sessionLock = NSLock()
    private var session = UUID()
    /// Guarded by `sessionLock`. The context of the IOProc last created,
    /// reachable from the main thread at Quit. Internal so a test can watch
    /// when it is released.
    private(set) weak var liveContext: ProcessedMicrophoneCaptureContext?

    /// What one session created on one device.
    private struct Resources {
        let session: UUID
        let deviceID: AudioDeviceID
        /// The transport class as last read, for the log lines.
        var transport: String
        /// Whether the sub-device lists are listened to.
        var watchesSubDeviceLists = false
        /// What a listener added later reports an invalidation to.
        var onInvalidated: (() -> Void)?
        /// Read by the IOProc block without being retained, so it has to
        /// outlive the IOProc: it is released on `queue` a moment after
        /// `AudioDeviceDestroyIOProcID` has returned.
        let context: ProcessedMicrophoneCaptureContext
        let ioProcID: AudioDeviceIOProcID
        var listenerBlock: AudioObjectPropertyListenerBlock?
        var listenedProperties: [AudioObjectPropertyAddress] = []
        var ioProc: LifecycleTeardown.IOProc = .created
    }

    /// What became of a release of the resources.
    private enum Release: Equatable {
        case released
        /// A quiet window armed after the release was issued. What it had
        /// not yet stopped or destroyed stays in `resources`.
        case interrupted
    }

    /// How long the context outlives `AudioDeviceDestroyIOProcID`, so that an
    /// IO cycle still finishing on the HAL IO thread never reads freed
    /// memory, whatever status the destroy returned.
    static let contextReleaseDelay: TimeInterval = 0.5

    /// Queue-confined.
    private var resources: Resources?

    init(halCalls: any HALLifecycleCalls, holdGeneration: LifecycleHoldGeneration) {
        self.halCalls = halCalls
        self.holdGeneration = holdGeneration
    }

    /// Main thread. Only `newSession` may create and start from now on.
    func begin(session newSession: UUID) {
        sessionLock.lock()
        session = newSession
        sessionLock.unlock()
    }

    /// Main thread. Ends the current session and releases its IOProc on the
    /// lifecycle queue. A start already queued behind this cannot bring it
    /// back up.
    ///
    /// Like a start, the release takes the quiet window's generation when it
    /// is issued and compares it immediately before each HAL call. If a
    /// window armed before a call, what is not yet stopped or destroyed
    /// stays, its gate closed so nothing more reaches the processing path,
    /// and `onInterrupted` runs on the queue so the engine can have it
    /// released after the window. A newer start or release takes over.
    func release(
        session releaseSession: UUID,
        holdToken: UInt64,
        onInterrupted: @escaping () -> Void
    ) {
        begin(session: releaseSession)
        queue.async { [self] in
            guard isCurrent(releaseSession), resources != nil else {
                return
            }
            if stopResources(holdToken: holdToken) == .interrupted {
                onInterrupted()
            }
        }
    }

    /// Main thread. coreaudiod restarted: the IOProc and its listeners went
    /// with the old server. Ends the session and drops them on the lifecycle
    /// queue without a HAL call. The context the IOProc block read is kept
    /// for the life of the process, because nothing confirmed that the IO
    /// thread has let go of it.
    func forgetAfterServiceRestart() {
        begin(session: UUID())
        queue.async { [self] in
            guard let current = resources else {
                return
            }
            resources = nil
            current.context.close()
            _ = Unmanaged.passRetained(current.context)
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .forget,
                id: current.deviceID,
                transport: current.transport,
                generation: holdGeneration.current
            )
        }
    }

    /// The label of the capture's release in Quit's `LifecycleStopGroup`.
    static let quitStopLabel = "processed-capture"

    /// Main thread, Quit only. Closes the current context's gate.
    func closeGateAtQuit() {
        sessionLock.lock()
        let context = liveContext
        sessionLock.unlock()
        context?.close()
    }

    /// Main thread, Quit only. Releases the IOProc on the lifecycle queue,
    /// whatever the quiet window, counted in `stops`, reporting progress
    /// before each HAL call.
    func releaseAtQuit(in stops: LifecycleStopGroup) {
        begin(session: UUID())
        stops.run(label: Self.quitStopLabel, on: queue) { [self] progress in
            stopResources(holdToken: nil, reason: HALLifecycleLog.quitReason, progress: progress)
        }
    }

    private func isCurrent(_ candidate: UUID) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return session == candidate
    }

    /// Runs only on `queue`. Creates the IOProc and its listeners without
    /// starting it. nil when the session was superseded, with anything it
    /// built already released.
    func prepare(
        deviceID: AudioDeviceID,
        session: UUID,
        gainScalar: ProcessedMicrophoneAtomicFloat,
        webRTCLevel: Int32?,
        holdToken: UInt64,
        onInvalidated: @escaping () -> Void
    ) -> PrepareOutcome? {
        // A newer session releases whatever is left when its turn comes.
        guard isCurrent(session) else {
            return nil
        }
        guard holdGeneration.isCurrent(holdToken) else {
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .interrupt,
                id: deviceID,
                generation: holdToken
            )
            return .interrupted
        }
        guard
            stopResources(holdToken: holdToken, loggingAnInterruptionAs: .interrupt) == .released
        else {
            return .interrupted
        }

        // Read the exact device again, uncached, immediately before opening
        // it. The poll that chose it may be a quarter of a second old, and an
        // aggregate's active sub-devices can change while its ID stays.
        let info = halCalls.transportInfo(for: deviceID)
        let transport = AudioDeviceTransportInfo.logDescription(info)
        switch InputOpenPolicy.decide(deviceID: deviceID, info: info) {
        case let .refuse(refusal):
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .refuse,
                id: deviceID,
                transport: transport,
                generation: holdToken
            )
            return .failed(.inputRefused(refusal))
        case let .open(note):
            if note.shouldBeLogged {
                HALLifecycleLog.record(
                    .processedMicrophoneCaptureIOProc,
                    .openUnverified,
                    id: deviceID,
                    transport: transport,
                    generation: holdToken
                )
            }
        }

        // The output the publisher engine will be bound to, read uncached in
        // the same turn and before anything is created: without an output it
        // may render to, nothing is.
        let publisherOutput: PublisherOutput
        switch PublisherOutputReading.read(halCalls) {
        case let .bound(output):
            publisherOutput = output
        case let .refused(refusal, defaultOutputID, defaultTransport):
            HALLifecycleLog.record(
                .processedMicrophonePublisherEngine,
                .refuse,
                id: defaultOutputID,
                transport: defaultTransport,
                generation: holdToken
            )
            return .failed(.publisherOutputRefused(refusal))
        }

        guard
            let format = halCalls.inputStreamFormat(for: deviceID),
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            return .failed(.unsupportedInputFormat)
        }
        let scratchFrames = min(
            max(
                halCalls.maximumBufferFrameSize(for: deviceID) ?? 0,
                Self.minimumScratchFrames
            ),
            Self.maximumScratchFrames
        )

        // An IOProc delivers one device buffer per call, far shorter than the
        // ring, which holds several of them.
        guard let ringBuffer = ProcessedMicrophoneRingBuffer(
            format: monoFormat,
            duration: 0.25
        ) else {
            return .failed(.unsupportedInputFormat)
        }
        let tapContext: ProcessedMicrophoneTapContext
        do {
            tapContext = try ProcessedMicrophoneTapContext(
                gainScalar: gainScalar,
                ringBuffer: ringBuffer,
                sampleRate: format.sampleRate,
                webRTCLevel: webRTCLevel
            )
        } catch let error as ProcessedMicrophoneEngineError {
            return .failed(error)
        } catch {
            return .failed(
                .operationFailed(
                    localized("Preparing WebRTC noise suppression"),
                    error.localizedDescription
                )
            )
        }
        let context = ProcessedMicrophoneCaptureContext(
            sampleFormat: format.sampleFormat,
            scratchFrames: scratchFrames,
            tapContext: tapContext
        )
        guard isCurrent(session) else {
            return nil
        }
        guard holdGeneration.isCurrent(holdToken) else {
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .interrupt,
                id: deviceID,
                transport: transport,
                generation: holdToken
            )
            return .interrupted
        }

        HALLifecycleLog.begin(
            .processedMicrophoneCaptureIOProc,
            .create,
            id: deviceID,
            transport: transport,
            generation: holdToken
        )
        // A nil queue runs the block on the HAL IO thread. It copies channel 0
        // into storage allocated above, with no allocation, lock or dispatch,
        // and without retaining the context, and hands it to the processing
        // path on that same thread. In WebRTC mode that path runs noise
        // suppression there too: APM's ProcessStream takes an internal mutex,
        // which no other thread takes while the IOProc is live, and costs CPU
        // time that grows with the sample rate.
        let (createStatus, newIOProcID) = halCalls.createIOProc(
            deviceID: deviceID,
            queue: nil
        ) { [unowned(unsafe) context] _, inputData, _, _, _ in
            context.consume(inputData)
        }
        HALLifecycleLog.record(
            .processedMicrophoneCaptureIOProc,
            .create,
            id: deviceID,
            transport: transport,
            status: createStatus,
            generation: holdToken
        )
        guard createStatus == noErr, let newIOProcID else {
            let status = createStatus == noErr ? kAudioHardwareUnspecifiedError : createStatus
            return .failed(
                .operationFailed(
                    localized("Creating the processed microphone capture IOProc"),
                    "Core Audio status \(status)"
                )
            )
        }
        resources = Resources(
            session: session,
            deviceID: deviceID,
            transport: transport,
            context: context,
            ioProcID: newIOProcID
        )
        sessionLock.lock()
        liveContext = context
        sessionLock.unlock()
        let watchesSubDeviceLists = AggregateMembershipPolicy.watchesSubDeviceLists(info)
        addListeners(
            deviceID: deviceID,
            properties: Self.invalidatingProperties + (watchesSubDeviceLists ? SubDeviceListProperty.addresses : []),
            transport: transport,
            context: context,
            holdToken: holdToken,
            onInvalidated: onInvalidated
        )
        resources?.watchesSubDeviceLists = watchesSubDeviceLists

        guard isCurrent(session) else {
            // The newer start or release is queued behind this one and
            // releases it, after its own generation check.
            return nil
        }
        return .prepared(
            Prepared(
                monoFormat: monoFormat,
                ringBuffer: ringBuffer,
                tapContext: tapContext,
                publisherOutput: publisherOutput
            )
        )
    }

    /// Runs only on `queue`. Starts the IOProc `prepare` created for this
    /// session. nil when the session was superseded; an IOProc that started
    /// meanwhile is released rather than left running.
    func startIO(session: UUID, holdToken: UInt64) -> StartOutcome? {
        guard
            isCurrent(session),
            let current = resources,
            current.session == session
        else {
            return nil
        }

        // Read the exact device again immediately before starting it, with
        // its listeners in place since `prepare`. The publisher start on the
        // main thread came in between, and an aggregate's sub-devices can
        // change while its ID stays; a change after this read reaches a
        // listener.
        let info = halCalls.transportInfo(for: current.deviceID)
        let transport = AudioDeviceTransportInfo.logDescription(info)
        resources?.transport = transport
        switch InputOpenSequence.afterListeners(
            deviceID: current.deviceID,
            secondInfo: info,
            generationCurrent: holdGeneration.isCurrent(holdToken)
        ) {
        case let .refuseAndRelease(refusal):
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .refuse,
                id: current.deviceID,
                transport: transport,
                generation: holdToken
            )
            guard isCurrent(session) else {
                return nil
            }
            // Released here rather than from the main thread, where a window
            // may have armed by the time the refusal arrives. If one armed
            // since the read, the IOProc, never started, is destroyed only
            // after the window, by the owner's restart.
            guard
                stopResources(holdToken: holdToken, loggingAnInterruptionAs: .interrupt) == .released
            else {
                return .interrupted
            }
            return .refused(refusal)
        case let .interrupt(refusal):
            if refusal != nil {
                HALLifecycleLog.record(
                    .processedMicrophoneCaptureIOProc,
                    .refuse,
                    id: current.deviceID,
                    transport: transport,
                    generation: holdToken
                )
            }
            guard isCurrent(session) else {
                return nil
            }
            // The IOProc, never started, is destroyed only after the window,
            // by the owner's restart.
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .interrupt,
                id: current.deviceID,
                transport: transport,
                generation: holdToken
            )
            return .interrupted
        case .start:
            break
        }
        guard isCurrent(session) else {
            return nil
        }
        if !current.watchesSubDeviceLists, AggregateMembershipPolicy.watchesSubDeviceLists(info) {
            addListeners(
                deviceID: current.deviceID,
                properties: SubDeviceListProperty.addresses,
                transport: transport,
                context: current.context,
                holdToken: holdToken,
                // `prepare` set both; the block already added is reused.
                onInvalidated: current.onInvalidated ?? {}
            )
            resources?.watchesSubDeviceLists = true
        }

        resources?.ioProc = .startUnconfirmed
        HALLifecycleLog.begin(
            .processedMicrophoneCaptureIOProc,
            .start,
            id: current.deviceID,
            transport: transport,
            generation: holdToken
        )
        let status = halCalls.start(deviceID: current.deviceID, ioProcID: current.ioProcID)
        HALLifecycleLog.record(
            .processedMicrophoneCaptureIOProc,
            .start,
            id: current.deviceID,
            transport: transport,
            status: status,
            generation: holdToken
        )
        guard status == noErr else {
            guard
                stopResources(holdToken: holdToken, loggingAnInterruptionAs: .interrupt) == .released
            else {
                // The start waited long enough for a window to arm. What it
                // created and has not released yet is released after the
                // window, not inside it.
                return .interrupted
            }
            return .failed(status)
        }
        resources?.ioProc = .started

        guard isCurrent(session) else {
            // A stop or another start landed while this one was starting. It
            // is queued behind this one and stops what started here, after
            // its own generation check.
            return nil
        }
        return .started
    }

    /// Runs only on `queue`. Adds one listener block for `properties` to
    /// what the current resources already listen to. A listener that cannot
    /// be added is logged and skipped rather than failing the start: the poll
    /// still notices a default-input change.
    private func addListeners(
        deviceID: AudioDeviceID,
        properties: [AudioObjectPropertyAddress],
        transport: String,
        context: ProcessedMicrophoneCaptureContext,
        holdToken: UInt64,
        onInvalidated: @escaping () -> Void
    ) {
        resources?.onInvalidated = onInvalidated
        let listener: AudioObjectPropertyListenerBlock = resources?.listenerBlock ?? { [weak self, context] count, addresses in
            // Only closes the gate, tells the owner, and for an aggregate's
            // active sub-devices asks the lifecycle queue to read the device
            // again. A change of its full composition only invalidates. Never
            // a HAL call.
            let activeSubDevicesChanged = SubDeviceListProperty.isActiveAmong(count, addresses)
            if context.close() {
                onInvalidated()
            }
            if activeSubDevicesChanged {
                self?.recheckAggregateMembership(of: context)
            }
        }

        var listened = resources?.listenedProperties ?? []
        for property in properties {
            let status = halCalls.addPropertyListener(
                deviceID: deviceID,
                address: property,
                queue: listenerQueue,
                block: listener
            )
            if status == noErr {
                listened.append(property)
            } else {
                HALLifecycleLog.record(
                    .processedMicrophoneCaptureListener,
                    .create,
                    id: deviceID,
                    transport: transport,
                    status: status,
                    generation: holdToken
                )
            }
        }
        resources?.listenerBlock = listener
        resources?.listenedProperties = listened
    }

    /// Listener queue. Has the lifecycle queue read the aggregate the IOProc
    /// captures from again, uncached, after its active sub-devices changed.
    ///
    /// A last resort, and a lifecycle step the quiet window does not hold:
    /// the capture never opens an aggregate that names a Bluetooth member, so
    /// this is reached only when the composition is edited while it is open.
    /// If a Bluetooth device is now active in the aggregate, the IOProc is
    /// stopped and destroyed at once, because a stop of the app's own IO is
    /// safer than letting it carry the headset's microphone through the
    /// headset's configuration change. Nothing is started here; the engine
    /// already has the invalidation, and the owner decides after the window.
    /// The stop is not exempt from the hardware gate's judgement of stops
    /// against the Bluetooth configuration-change requests.
    private func recheckAggregateMembership(of context: ProcessedMicrophoneCaptureContext) {
        queue.async { [self] in
            guard let current = resources, current.context === context else {
                // Already released, or replaced by a newer start.
                return
            }
            let info = halCalls.transportInfo(for: current.deviceID)
            guard AggregateMembershipPolicy.afterActiveSubDevicesChanged(info) == .stopNow else {
                return
            }
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .refuse,
                id: current.deviceID,
                transport: AudioDeviceTransportInfo.logDescription(info),
                generation: nil,
                reason: SubDeviceListProperty.bluetoothJoinedReason
            )
            stopResources(holdToken: nil, reason: SubDeviceListProperty.bluetoothJoinedReason)
        }
    }

    /// Runs only on `queue`. Releases everything the current resources hold,
    /// one HAL call at a time, in `LifecycleTeardown`'s order: the listeners,
    /// the stop, then the IOProc. After a start that did not return `noErr`,
    /// whether the device reports the IO running is read first, and running
    /// IO is stopped before its IOProc is destroyed.
    ///
    /// `holdToken` is the quiet window's generation the release was issued
    /// in, compared immediately before the listener removal and before each
    /// lifecycle call. At a mismatch the release ends there, logs the call it
    /// held back as `interruption`, and keeps what remains, recorded as far as
    /// it got, for the release after the window.
    ///
    /// - Parameters:
    ///   - holdToken: nil for a release the quiet window does not hold.
    ///   - interruption: `interrupt-stop` for a release the engine issued,
    ///     `interrupt` for the release a start makes.
    ///   - reason: Set when the release is exempt from the quiet window, for
    ///     the log.
    ///   - progress: At Quit, told the phase immediately before each HAL call.
    @discardableResult
    private func stopResources(
        holdToken: UInt64?,
        loggingAnInterruptionAs interruption: HALLifecycleLog.Operation = .interruptStop,
        reason: String? = nil,
        progress: LifecycleStopGroup.Progress? = nil
    ) -> Release {
        guard var current = resources else {
            return .released
        }
        current.context.close()

        if let listenerBlock = current.listenerBlock {
            guard holdGeneration.allows(holdToken) else {
                return interruptRelease(of: current, as: interruption, holdToken: holdToken)
            }
            progress?.report(.removeListeners)
            for property in current.listenedProperties {
                halCalls.removePropertyListener(
                    deviceID: current.deviceID,
                    address: property,
                    queue: listenerQueue,
                    block: listenerBlock
                )
            }
            current.listenerBlock = nil
            current.listenedProperties = []
            resources = current
        }

        var teardown = LifecycleTeardown(ioProc: current.ioProc)
        while let step = teardown.nextStep {
            guard !step.isLifecycleCall || holdGeneration.allows(holdToken) else {
                return interruptRelease(of: current, as: interruption, holdToken: holdToken)
            }
            progress?.report(LifecycleStopGroup.Phase(step))
            switch step {
            case .readIsRunning:
                let (status, value) = halCalls.isRunning(current.deviceID)
                teardown.noteIsRunning(status == noErr && value != 0)
            case .stop:
                let stopReason = teardown.stopFollowsUnconfirmedStart
                    ? reason ?? HALLifecycleLog.unconfirmedStartReason
                    : reason
                HALLifecycleLog.begin(
                    .processedMicrophoneCaptureIOProc,
                    .stop,
                    id: current.deviceID,
                    transport: current.transport,
                    generation: holdToken,
                    reason: stopReason
                )
                let stopStatus = halCalls.stop(deviceID: current.deviceID, ioProcID: current.ioProcID)
                HALLifecycleLog.record(
                    .processedMicrophoneCaptureIOProc,
                    .stop,
                    id: current.deviceID,
                    transport: current.transport,
                    status: stopStatus,
                    generation: holdToken,
                    reason: stopReason
                )
                teardown.complete(.stop)
            case .destroyIOProc:
                HALLifecycleLog.begin(
                    .processedMicrophoneCaptureIOProc,
                    .destroy,
                    id: current.deviceID,
                    transport: current.transport,
                    generation: holdToken,
                    reason: reason
                )
                let destroyStatus = halCalls.destroyIOProc(
                    deviceID: current.deviceID,
                    ioProcID: current.ioProcID
                )
                HALLifecycleLog.record(
                    .processedMicrophoneCaptureIOProc,
                    .destroy,
                    id: current.deviceID,
                    transport: current.transport,
                    status: destroyStatus,
                    generation: holdToken,
                    reason: reason
                )
                teardown.complete(.destroyIOProc)
                releaseContext(current.context, afterDestroyReturned: destroyStatus)
            case .destroyAggregate, .destroyProcessTap:
                // The capture holds neither.
                teardown.complete(step)
            }
            current.ioProc = teardown.ioProc
            resources = current
        }
        resources = nil
        return .released
    }

    /// Runs only on `queue`.
    private func interruptRelease(
        of held: Resources,
        as operation: HALLifecycleLog.Operation,
        holdToken: UInt64?
    ) -> Release {
        HALLifecycleLog.record(
            .processedMicrophoneCaptureIOProc,
            operation,
            id: held.deviceID,
            transport: held.transport,
            generation: holdToken
        )
        return .interrupted
    }

    /// Runs only on `queue`, right after `AudioDeviceDestroyIOProcID`
    /// returned `status`.
    ///
    /// The IOProc block reads the context without retaining it. Nothing
    /// documents that the destroy waits for an IO cycle already running on
    /// the HAL IO thread, and a device that vanished answers without having
    /// synchronized with that thread at all. So the context is kept for
    /// `contextReleaseDelay` after the destroy returned, whatever it returned.
    /// For a status other than `noErr`, bad device or bad object, the HAL did
    /// not confirm the IOProc is gone, and the context is kept for the life
    /// of the process.
    private func releaseContext(
        _ context: ProcessedMicrophoneCaptureContext,
        afterDestroyReturned status: OSStatus
    ) {
        guard
            status == noErr
                || status == kAudioHardwareBadDeviceError
                || status == kAudioHardwareBadObjectError
        else {
            _ = Unmanaged.passRetained(context)
            return
        }
        queue.asyncAfter(deadline: .now() + Self.contextReleaseDelay) {
            withExtendedLifetime(context) {}
        }
    }
}

/// What the IOProc block reads on the HAL IO thread: the sample format,
/// preallocated storage for channel 0, and the processing path.
///
/// The block does not retain it. `ProcessedMicrophoneDeviceCapture` owns it
/// and releases it only after the IOProc has been destroyed.
final class ProcessedMicrophoneCaptureContext: @unchecked Sendable {
    private let sampleFormat: PCMSampleFormat
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames: Int
    private let tapContext: ProcessedMicrophoneTapContext
    /// 1 while samples are passed on, 0 once invalidated or released. The IO
    /// thread only reads it.
    private var gate: Int32 = 1

    init(
        sampleFormat: PCMSampleFormat,
        scratchFrames: Int,
        tapContext: ProcessedMicrophoneTapContext
    ) {
        self.sampleFormat = sampleFormat
        self.scratchFrames = scratchFrames
        self.tapContext = tapContext
        scratch = .allocate(capacity: scratchFrames)
        scratch.initialize(repeating: 0, count: scratchFrames)
    }

    deinit {
        scratch.deinitialize(count: scratchFrames)
        scratch.deallocate()
    }

    /// HAL IO thread only.
    func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        guard OSAtomicAdd32Barrier(0, &gate) != 0 else {
            return
        }
        let frameCount = AudioBufferChannelCopy.copyFirstChannel(
            inputData,
            format: sampleFormat,
            into: scratch,
            capacity: scratchFrames
        )
        guard frameCount > 0 else {
            return
        }
        tapContext.process(samples: UnsafePointer(scratch), frameCount: frameCount)
    }

    /// Stops passing samples on. True when this call closed an open gate.
    @discardableResult
    func close() -> Bool {
        OSAtomicCompareAndSwap32Barrier(1, 0, &gate)
    }
}

/// Owns every object and raw allocation touched by the capture callback: the
/// input-node tap for Apple voice processing, which retains this context for
/// the entire callback, including if the engine concurrently removes the tap
/// during shutdown, or the IOProc through `ProcessedMicrophoneCaptureContext`,
/// which keeps it until the IOProc has been destroyed.
final class ProcessedMicrophoneTapContext: @unchecked Sendable {
    private static let scratchCapacity = 1_024

    private let gainScalar: ProcessedMicrophoneAtomicFloat
    private let ringBuffer: ProcessedMicrophoneRingBuffer
    private let webRTCProcessor: OpaquePointer?
    private let webRTCScratch: UnsafeMutablePointer<Float>?
    /// 0 means no error and Int32.min means the first error was consumed by
    /// the main-thread timer. The audio callback only performs a single CAS;
    /// it never allocates, locks, or dispatches error work.
    private var webRTCErrorStatus: Int32 = 0
    /// The rate the ring buffer was made for. Apple voice processing's tap
    /// is installed with no format, so a buffer at another rate can arrive.
    private let sampleRate: Double
    /// 0 until a tap buffer arrives at another rate than `sampleRate`, 1
    /// then, and 2 once the main-thread timer has read it. The tap only
    /// performs a single CAS.
    private var formatMismatch: Int32 = 0

    init(
        gainScalar: ProcessedMicrophoneAtomicFloat,
        ringBuffer: ProcessedMicrophoneRingBuffer,
        sampleRate: Double,
        webRTCLevel: Int32?
    ) throws {
        self.gainScalar = gainScalar
        self.ringBuffer = ringBuffer
        self.sampleRate = sampleRate

        guard let webRTCLevel else {
            webRTCProcessor = nil
            webRTCScratch = nil
            return
        }

        guard let webRTCSampleRate = SampleRatePolicy.webRTCSampleRate(sampleRate) else {
            throw ProcessedMicrophoneEngineError.unsupportedInputFormat
        }
        var errorCString: UnsafePointer<CChar>?
        guard let processor = ALBWebRTCNoiseSuppressorCreate(
            webRTCSampleRate,
            webRTCLevel,
            &errorCString
        ) else {
            let detail = errorCString.map { String(cString: $0) }
                ?? "unknown error"
            throw ProcessedMicrophoneEngineError.operationFailed(
                localized("Preparing WebRTC noise suppression"),
                detail
            )
        }
        webRTCProcessor = processor

        let scratch = UnsafeMutablePointer<Float>.allocate(
            capacity: Self.scratchCapacity
        )
        scratch.initialize(repeating: 0, count: Self.scratchCapacity)
        webRTCScratch = scratch
    }

    deinit {
        if let webRTCProcessor {
            ALBWebRTCNoiseSuppressorDestroy(webRTCProcessor)
        }
        if let webRTCScratch {
            webRTCScratch.deinitialize(count: Self.scratchCapacity)
            webRTCScratch.deallocate()
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate == sampleRate else {
            // The node's format changed after the ring was made for it: the
            // device is being rebound. Nothing at the wrong rate reaches the
            // ring, and the level timer asks for a restart.
            OSAtomicCompareAndSwap32Barrier(0, 1, &formatMismatch)
            return
        }
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return
        }
        process(
            samples: UnsafePointer(channelData[0]),
            frameCount: Int(buffer.frameLength)
        )
    }

    /// Mono Float32 samples from either capture: the AVAudioEngine tap's
    /// thread for Apple voice processing, or the HAL IO thread for the IOProc
    /// capture. Without noise suppression it makes no allocation, lock or
    /// dispatch. With WebRTC noise suppression, which only the IOProc capture
    /// uses, APM's ProcessStream takes an internal mutex that no other thread
    /// takes while the capture runs, and its CPU cost per 10 ms block grows
    /// with the sample rate. A sample that is not finite is written as 0; see
    /// `ProcessedMicrophoneRingBuffer.processAndWrite`.
    func process(samples input: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else {
            return
        }

        let gain = gainScalar.load()

        // The whole tap buffer lands in the ring before the consumer runs
        // again, even when noise suppression writes it in chunks. The consumer
        // sizes its backlog allowance from this, not from the chunk size.
        ringBuffer.noteProducerBurst(frameCount: frameCount)

        guard
            let webRTCProcessor,
            let webRTCScratch
        else {
            ringBuffer.processAndWrite(
                input,
                frameCount: frameCount,
                gainScalar: gain
            )
            return
        }

        var frameOffset = 0
        while frameOffset < frameCount {
            let chunkFrameCount = min(
                Self.scratchCapacity,
                frameCount - frameOffset
            )
            let status = ALBWebRTCNoiseSuppressorProcess(
                webRTCProcessor,
                input.advanced(by: frameOffset),
                webRTCScratch,
                Int32(chunkFrameCount)
            )
            if status != 0 {
                _ = OSAtomicCompareAndSwap32Barrier(
                    0,
                    status,
                    &webRTCErrorStatus
                )
            }
            ringBuffer.processAndWrite(
                UnsafePointer(webRTCScratch),
                frameCount: chunkFrameCount,
                gainScalar: gain
            )
            frameOffset += chunkFrameCount
        }
    }

    /// Returns the first runtime WebRTC error exactly once. This is called by
    /// the existing main-thread level timer, never by an audio callback.
    /// Main thread. Whether a tap buffer arrived at another rate than the
    /// ring's since the session began; true once.
    func consumeFormatMismatch() -> Bool {
        OSAtomicCompareAndSwap32Barrier(1, 2, &formatMismatch)
    }

    func consumeWebRTCErrorStatus() -> Int32? {
        var status = OSAtomicAdd32Barrier(0, &webRTCErrorStatus)
        while status != 0, status != Int32.min {
            if OSAtomicCompareAndSwap32Barrier(
                status,
                Int32.min,
                &webRTCErrorStatus
            ) {
                return status
            }
            status = OSAtomicAdd32Barrier(0, &webRTCErrorStatus)
        }
        return nil
    }
}

struct ProcessedMicrophoneLevels {
    let inputRMSDecibels: Float
    let inputPeakDecibels: Float
    let outputRMSDecibels: Float
    let outputPeakDecibels: Float
}

/// macOS 14-compatible atomic Float storage. OSAtomic's barrier variants are
/// used deliberately here because the Synchronization.Atomic API is only
/// available from macOS 15. There is one control-thread writer and one audio-
/// callback reader.
final class ProcessedMicrophoneAtomicFloat: @unchecked Sendable {
    private var storage: Int32

    init(_ value: Float) {
        storage = Int32(bitPattern: value.bitPattern)
    }

    func load() -> Float {
        let value = OSAtomicAdd32Barrier(0, &storage)
        return Float(bitPattern: UInt32(bitPattern: value))
    }

    func store(_ value: Float) {
        let desired = Int32(bitPattern: value.bitPattern)
        var current = OSAtomicAdd32Barrier(0, &storage)
        while !OSAtomicCompareAndSwap32Barrier(current, desired, &storage) {
            current = OSAtomicAdd32Barrier(0, &storage)
        }
    }
}

/// A seqlock-protected meter snapshot. The audio callback is the only writer;
/// the main-thread timer is the only reader. Odd sequence values mean a write
/// is in progress, so readers never observe a mix of two snapshots.
final class ProcessedMicrophoneLevelStore: @unchecked Sendable {
    private let inputRMS = ProcessedMicrophoneAtomicFloat(-80)
    private let inputPeak = ProcessedMicrophoneAtomicFloat(-80)
    private let outputRMS = ProcessedMicrophoneAtomicFloat(-80)
    private let outputPeak = ProcessedMicrophoneAtomicFloat(-80)
    private var sequence: Int64 = 0

    func store(_ levels: ProcessedMicrophoneLevels) {
        _ = OSAtomicIncrement64Barrier(&sequence)
        inputRMS.store(levels.inputRMSDecibels)
        inputPeak.store(levels.inputPeakDecibels)
        outputRMS.store(levels.outputRMSDecibels)
        outputPeak.store(levels.outputPeakDecibels)
        _ = OSAtomicIncrement64Barrier(&sequence)
    }

    func load(
        after previousSequence: Int64
    ) -> (sequence: Int64, levels: ProcessedMicrophoneLevels)? {
        let firstSequence = OSAtomicAdd64Barrier(0, &sequence)
        guard
            firstSequence.isMultiple(of: 2),
            firstSequence != previousSequence
        else {
            return nil
        }

        let levels = ProcessedMicrophoneLevels(
            inputRMSDecibels: inputRMS.load(),
            inputPeakDecibels: inputPeak.load(),
            outputRMSDecibels: outputRMS.load(),
            outputPeakDecibels: outputPeak.load()
        )
        let secondSequence = OSAtomicAdd64Barrier(0, &sequence)
        guard
            firstSequence == secondSequence,
            secondSequence.isMultiple(of: 2)
        else {
            return nil
        }
        return (secondSequence, levels)
    }
}

/// A single-producer/single-consumer Float32 PCM ring buffer. The input tap is
/// the sole producer and the AVAudioSourceNode render block is the sole
/// consumer. Atomic indices keep both real-time callbacks free of locks and
/// allocations.
final class ProcessedMicrophoneRingBuffer: @unchecked Sendable {
    private static let limiterCeiling: Float = 0.98
    private static let limiterReleaseSeconds: Float = 0.08

    private let capacityFrames: Int
    private let frameMask: Int
    private let storage: UnsafeMutablePointer<Float>
    private var readPosition: Int64 = 0
    private var writePosition: Int64 = 0
    /// Largest tap buffer the producer has delivered in one go. Written only
    /// by the single producer thread; the consumer reads it to size its
    /// backlog allowance.
    private var largestBurstFrames: Int64 = 0
    /// Consumer-thread only. The producer delivers a whole burst at once while
    /// this side drains one render quantum per call, so the backlog reaches
    /// zero at the end of every burst period and any jitter in the next
    /// arrival becomes a gap. Rebuild a small cushion instead of trickling out
    /// fragments.
    private var isPrimed = false
    private let levelStore = ProcessedMicrophoneLevelStore()
    private let limiterReleaseCoefficient: Float
    private var limiterReduction: Float = 1

    /// The largest ring: a quarter of a second at 768 kHz, rounded up to a
    /// power of two. A second line of defence behind `SampleRatePolicy`.
    private static let maximumCapacityFrames = 262_144

    /// nil when the format's sample rate is not one `SampleRatePolicy`
    /// accepts, or `duration` is not a positive finite time.
    init?(format: AVAudioFormat, duration: TimeInterval) {
        guard
            let requestedCapacity = SampleRatePolicy.bufferFrames(
                sampleRate: format.sampleRate,
                duration: duration,
                minimum: 8_192,
                maximum: Self.maximumCapacityFrames
            )
        else {
            return nil
        }
        capacityFrames = Self.nextPowerOfTwo(requestedCapacity)
        frameMask = capacityFrames - 1
        storage = .allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0, count: capacityFrames)
        limiterReleaseCoefficient = exp(
            -1 / (
                Float(format.sampleRate) * Self.limiterReleaseSeconds
            )
        )
    }

    deinit {
        storage.deinitialize(count: capacityFrames)
        storage.deallocate()
    }

    /// Reports the size of one producer delivery, which noise suppression
    /// splits into several `processAndWrite` calls.
    func noteProducerBurst(frameCount: Int) {
        guard Int64(frameCount) > largestBurstFrames else {
            return
        }
        _ = OSAtomicAdd64Barrier(
            Int64(frameCount) - largestBurstFrames,
            &largestBurstFrames
        )
    }

    func processAndWrite(
        _ input: UnsafePointer<Float>,
        frameCount: Int,
        gainScalar: Float
    ) {
        guard frameCount > 0 else {
            return
        }

        let write = OSAtomicAdd64Barrier(0, &writePosition)
        let read = OSAtomicAdd64Barrier(0, &readPosition)
        let availableCapacity = max(
            Int64(0),
            Int64(capacityFrames) - (write - read)
        )
        let writableFrameCount = min(frameCount, Int(availableCapacity))
        let shouldLimit = gainScalar > 1

        if !shouldLimit {
            limiterReduction = 1
        }

        var inputSumOfSquares: Double = 0
        var outputSumOfSquares: Double = 0
        var inputPeak: Float = 0
        var outputPeak: Float = 0

        for frame in 0..<frameCount {
            // Both captures pass through here, and noise suppression's output
            // too. A sample that is not finite would pass straight through
            // the gain, or through the limiter as NaN, into the published
            // device.
            let inputSample = SampleSanitizer.finiteOrZero(input[frame])
            let frameInputPeak = abs(inputSample)
            inputPeak = max(inputPeak, frameInputPeak)
            inputSumOfSquares += Double(inputSample) * Double(inputSample)

            if shouldLimit {
                let boostedPeak = frameInputPeak * gainScalar
                let desiredReduction = boostedPeak > Self.limiterCeiling
                    ? Self.limiterCeiling / boostedPeak
                    : 1

                if desiredReduction < limiterReduction {
                    // Fast attack: prevent the current frame from exceeding
                    // the ceiling. Release is smoothed to avoid block pumping.
                    limiterReduction = desiredReduction
                } else {
                    limiterReduction = desiredReduction
                        + limiterReleaseCoefficient
                            * (limiterReduction - desiredReduction)
                }
            }

            let effectiveGain = gainScalar * limiterReduction
            let storageFrame = (Int(write) + frame) & frameMask
            var outputSample = inputSample * effectiveGain

            if shouldLimit {
                // The envelope already enforces the ceiling; this final clamp
                // only absorbs floating-point rounding at the edge.
                outputSample = min(
                    max(outputSample, -Self.limiterCeiling),
                    Self.limiterCeiling
                )
            }

            if frame < writableFrameCount {
                storage[storageFrame] = outputSample
            }
            let amplitude = abs(outputSample)
            outputPeak = max(outputPeak, amplitude)
            outputSumOfSquares += Double(outputSample) * Double(outputSample)
        }

        if writableFrameCount > 0 {
            // Samples are committed before the barrier-protected write index.
            // The consumer's barrier load therefore cannot observe an index
            // whose corresponding PCM frames are still incomplete.
            _ = OSAtomicAdd64Barrier(
                Int64(writableFrameCount),
                &writePosition
            )
        }

        let sampleCount = Double(frameCount)
        let inputRMS = Float(sqrt(inputSumOfSquares / sampleCount))
        let outputRMS = Float(sqrt(outputSumOfSquares / sampleCount))
        levelStore.store(
            ProcessedMicrophoneLevels(
                inputRMSDecibels: MeterScale.decibels(amplitude: inputRMS),
                inputPeakDecibels: MeterScale.decibels(amplitude: inputPeak),
                outputRMSDecibels: MeterScale.decibels(amplitude: outputRMS),
                outputPeakDecibels: MeterScale.decibels(amplitude: outputPeak)
            )
        )
    }

    func latestLevels(
        after sequence: Int64
    ) -> (sequence: Int64, levels: ProcessedMicrophoneLevels)? {
        levelStore.load(after: sequence)
    }

    @discardableResult
    func read(
        into outputData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in buffers {
            guard let data = buffer.mData else {
                continue
            }
            data.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
        }

        let originalRead = OSAtomicAdd64Barrier(0, &readPosition)
        let write = OSAtomicAdd64Barrier(0, &writePosition)
        let availableFrames = max(Int64(0), write - originalRead)

        // If the two hardware clocks drift or the publisher pauses briefly,
        // discard the oldest backlog on the consumer side so latency does not
        // become sticky.
        //
        // The allowance must cover one whole producer buffer: the input tap
        // delivers 100 ms bursts even when a 20 ms tap size is requested,
        // while this side drains ~10 ms at a time. An allowance set to a fixed
        // fraction of the ring discards most of every burst instead, which
        // reaches consuming apps as audio chopped roughly in half.
        let burstAllowance = OSAtomicAdd64Barrier(0, &largestBurstFrames)
            + Int64(frameCount) * 2
        let maximumBacklog = min(
            Int64(capacityFrames),
            max(Int64(frameCount * 2), burstAllowance)
        )
        let skippedFrames = max(Int64(0), availableFrames - maximumBacklog)
        let read = originalRead + skippedFrames
        let remainingFrames = max(Int64(0), write - read)

        // Enough cushion to absorb jitter in burst arrival, and no more:
        // priming to a whole burst would add its duration to the microphone's
        // latency for nothing, since the backlog already peaks one burst high.
        let primeTarget = min(Int64(frameCount * 4), Int64(capacityFrames))
        if !isPrimed {
            guard remainingFrames >= primeTarget else {
                if skippedFrames > 0 {
                    _ = OSAtomicAdd64Barrier(skippedFrames, &readPosition)
                }
                return 0
            }
            isPrimed = true
        }

        let readableFrameCount = min(frameCount, Int(remainingFrames))
        guard readableFrameCount > 0 else {
            isPrimed = false
            if skippedFrames > 0 {
                _ = OSAtomicAdd64Barrier(skippedFrames, &readPosition)
            }
            return 0
        }
        if readableFrameCount < frameCount {
            isPrimed = false
        }

        if buffers.count == 1, let data = buffers[0].mData {
            let outputChannels = Int(buffers[0].mNumberChannels)
            let output = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<readableFrameCount {
                let storageFrame = (Int(read) + frame) & frameMask
                for channel in 0..<outputChannels {
                    output[frame * outputChannels + channel] = storage[storageFrame]
                }
            }
        } else {
            for buffer in buffers {
                guard let data = buffer.mData else {
                    continue
                }
                let output = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<readableFrameCount {
                    let storageFrame = (Int(read) + frame) & frameMask
                    output[frame] = storage[storageFrame]
                }
            }
        }

        // Reading completes before the barrier-protected index advances, so
        // the producer cannot overwrite a frame still being consumed.
        _ = OSAtomicAdd64Barrier(
            skippedFrames + Int64(readableFrameCount),
            &readPosition
        )
        return readableFrameCount
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value {
            result <<= 1
        }
        return result
    }
}
