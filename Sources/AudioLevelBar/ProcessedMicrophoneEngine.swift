import AVFoundation
import AudioLevelBarCore
import Darwin
import Foundation
import WebRTCNoiseSuppression

enum ProcessedMicrophoneEngineError: LocalizedError {
    case unsupportedInputFormat
    case operationFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedInputFormat:
            return localized("The selected microphone did not provide a Float32 audio format that can be processed.")
        case let .operationFailed(operation, detail):
            return localized("%1$@ failed: %2$@", operation, detail)
        }
    }
}

/// Captures the current default input, optionally applies Apple's voice
/// processing or WebRTC noise suppression, normalizes the result to mono,
/// applies digital gain, and renders it through a separate non-voice-processing
/// engine.
///
/// The publisher engine is intentionally separate from the capture engine. A
/// direct input-to-output connection on the voice-processing engine would feed
/// the microphone uplink into its own echo-cancellation reference. The owner
/// must arrange for the publisher engine's process audio to be captured and
/// muted before calling `start`; otherwise the processed microphone is audible
/// through the current physical output device.
///
/// While this engine is running, the owner should stop `MicrophoneMeter` and use
/// `onInputLevel` / `onOutputLevel` for metering. Lifecycle methods are expected
/// to be called from the main thread, matching the rest of the app's audio
/// state management.
final class ProcessedMicrophoneEngine {
    struct Configuration: Equatable {
        var processingMode: MicrophoneProcessingMode
        var digitalGainDecibels: Float

        init(
            processingMode: MicrophoneProcessingMode = .off,
            digitalGainDecibels: Float = 0
        ) {
            self.processingMode = processingMode
            self.digitalGainDecibels = digitalGainDecibels
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
    var onError: ((ProcessedMicrophoneEngineError) -> Void)?
    /// Requests a fail-closed restart from the owner. The owner must stop this
    /// engine, validate/recreate the muted public tap, and only then start it.
    var onNeedsRestart: (() -> Void)?

    private(set) var configuration = Configuration()
    private(set) var isRunning = false

    private let gainScalar = ProcessedMicrophoneAtomicFloat(1)
    private var captureEngine: AVAudioEngine?
    private var publisherEngine: AVAudioEngine?
    private var publisherSourceNode: AVAudioSourceNode?
    private var ringBuffer: ProcessedMicrophoneRingBuffer?
    private var tapContext: ProcessedMicrophoneTapContext?
    private var configurationObservers: [NSObjectProtocol] = []
    private var scheduledRestartRequest: DispatchWorkItem?
    private var levelTimer: Timer?
    private var lastLevelSequence: Int64 = 0
    private var sessionID = UUID()

    deinit {
        stop()
    }

    @discardableResult
    func start(configuration requestedConfiguration: Configuration) -> Bool {
        configuration = Self.sanitized(requestedConfiguration)
        gainScalar.store(
            DigitalGain.amplitude(decibels: configuration.digitalGainDecibels)
        )
        return start()
    }

    @discardableResult
    func start() -> Bool {
        stop()

        let sessionID = UUID()
        self.sessionID = sessionID
        let captureEngine = AVAudioEngine()
        let inputNode = captureEngine.inputNode

        // Access both I/O nodes before enabling voice processing. AVAudioEngine
        // configures them as a paired Voice Processing I/O unit on macOS.
        _ = captureEngine.outputNode

        do {
            // Voice processing changes the I/O unit and must be selected while
            // the engine is stopped, before querying either node's format.
            let useAppleVoiceProcessing = configuration.processingMode == .apple
            if useAppleVoiceProcessing {
                do {
                    try inputNode.setVoiceProcessingEnabled(true)
                } catch {
                    throw ProcessedMicrophoneEngineError.operationFailed(
                        localized("Enabling Apple voice processing"),
                        Self.errorDetail(error)
                    )
                }
                inputNode.isVoiceProcessingBypassed = false
                // Digital gain is explicit in this class; do not stack Apple's
                // automatic gain control on top of it.
                inputNode.isVoiceProcessingAGCEnabled = false
                inputNode.isVoiceProcessingInputMuted = false
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            }

            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard
                inputFormat.sampleRate > 0,
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
            let ringBuffer = ProcessedMicrophoneRingBuffer(
                format: monoFormat,
                duration: 0.25
            )
            let tapContext = try ProcessedMicrophoneTapContext(
                gainScalar: gainScalar,
                ringBuffer: ringBuffer,
                sampleRate: inputFormat.sampleRate,
                webRTCLevel: Self.webRTCLevel(
                    for: configuration.processingMode
                )
            )
            let publisher = try makePublisher(
                format: monoFormat,
                ringBuffer: ringBuffer
            )

            let tapFrameCount = AVAudioFrameCount(
                min(max(inputFormat.sampleRate * 0.02, 512), 1_024)
            )
            inputNode.installTap(
                onBus: 0,
                bufferSize: tapFrameCount,
                format: inputFormat
            ) { buffer, _ in
                tapContext.process(buffer)
            }

            captureEngine.prepare()
            do {
                try captureEngine.start()
            } catch {
                captureEngine.stop()
                inputNode.removeTap(onBus: 0)
                publisher.engine.stop()
                throw ProcessedMicrophoneEngineError.operationFailed(
                    localized("Starting microphone processing"),
                    Self.errorDetail(error)
                )
            }

            self.captureEngine = captureEngine
            publisherEngine = publisher.engine
            publisherSourceNode = publisher.sourceNode
            self.ringBuffer = ringBuffer
            self.tapContext = tapContext
            isRunning = true
            startLevelTimer(
                sessionID: sessionID,
                ringBuffer: ringBuffer,
                tapContext: tapContext
            )
            installConfigurationObservers(
                captureEngine: captureEngine,
                publisherEngine: publisher.engine
            )

            DispatchQueue.main.async { [weak self] in
                guard self?.sessionID == sessionID else {
                    return
                }
                self?.onStarted?()
            }
            return true
        } catch let error as ProcessedMicrophoneEngineError {
            captureEngine.stop()
            report(error, sessionID: sessionID)
        } catch {
            captureEngine.stop()
            report(
                .operationFailed(
                    localized("Starting the processed microphone"),
                    Self.errorDetail(error)
                ),
                sessionID: sessionID
            )
        }

        return false
    }

    func stop() {
        scheduledRestartRequest?.cancel()
        scheduledRestartRequest = nil
        levelTimer?.invalidate()
        levelTimer = nil
        lastLevelSequence = 0
        removeConfigurationObservers()
        sessionID = UUID()

        if let captureEngine {
            captureEngine.stop()
            captureEngine.inputNode.removeTap(onBus: 0)
        }
        // An in-flight tap closure retains its context until process(_:) has
        // returned, so its C processor and scratch storage cannot be freed
        // while the callback is still using them.
        tapContext = nil
        publisherEngine?.stop()

        captureEngine = nil
        publisherEngine = nil
        publisherSourceNode = nil
        ringBuffer = nil
        isRunning = false
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

    private func makePublisher(
        format: AVAudioFormat,
        ringBuffer: ProcessedMicrophoneRingBuffer
    ) throws -> (engine: AVAudioEngine, sourceNode: AVAudioSourceNode) {
        let engine = AVAudioEngine()
        let sourceNode = AVAudioSourceNode(format: format) {
            isSilence, _, frameCount, outputData in
            let framesRead = ringBuffer.read(
                into: outputData,
                frameCount: Int(frameCount)
            )
            isSilence.pointee = ObjCBool(framesRead == 0)
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        _ = engine.outputNode
        engine.prepare()

        do {
            try engine.start()
        } catch {
            throw ProcessedMicrophoneEngineError.operationFailed(
                localized("Starting processed microphone output"),
                Self.errorDetail(error)
            )
        }
        return (engine, sourceNode)
    }

    private func installConfigurationObservers(
        captureEngine: AVAudioEngine,
        publisherEngine: AVAudioEngine
    ) {
        let engines = [captureEngine, publisherEngine]
        configurationObservers = engines.map { engine in
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleRestartRequest()
            }
        }
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

    private func scheduleRestartRequest() {
        guard scheduledRestartRequest == nil, isRunning else {
            return
        }

        // Configuration changes can invalidate the public muted route. Stop
        // both engines immediately, then let the owner validate/recreate the
        // tap after Core Audio has settled. Never keep publisher audio running
        // during the debounce interval.
        stop()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.scheduledRestartRequest = nil
            self.onNeedsRestart?()
        }
        scheduledRestartRequest = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
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
            )
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

/// Owns every object and raw allocation touched by the input-node tap. The tap
/// closure retains this context for the entire callback, including if the
/// engine concurrently removes the tap during shutdown.
private final class ProcessedMicrophoneTapContext: @unchecked Sendable {
    private static let scratchCapacity = 1_024

    private let gainScalar: ProcessedMicrophoneAtomicFloat
    private let ringBuffer: ProcessedMicrophoneRingBuffer
    private let webRTCProcessor: OpaquePointer?
    private let webRTCScratch: UnsafeMutablePointer<Float>?
    /// 0 means no error and Int32.min means the first error was consumed by
    /// the main-thread timer. The audio callback only performs a single CAS;
    /// it never allocates, locks, or dispatches error work.
    private var webRTCErrorStatus: Int32 = 0

    init(
        gainScalar: ProcessedMicrophoneAtomicFloat,
        ringBuffer: ProcessedMicrophoneRingBuffer,
        sampleRate: Double,
        webRTCLevel: Int32?
    ) throws {
        self.gainScalar = gainScalar
        self.ringBuffer = ringBuffer

        guard let webRTCLevel else {
            webRTCProcessor = nil
            webRTCScratch = nil
            return
        }

        var errorCString: UnsafePointer<CChar>?
        guard let processor = ALBWebRTCNoiseSuppressorCreate(
            UInt32(sampleRate.rounded()),
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
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return
        }

        let input = UnsafePointer(channelData[0])
        let frameCount = Int(buffer.frameLength)
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

private struct ProcessedMicrophoneLevels {
    let inputRMSDecibels: Float
    let inputPeakDecibels: Float
    let outputRMSDecibels: Float
    let outputPeakDecibels: Float
}

/// macOS 14-compatible atomic Float storage. OSAtomic's barrier variants are
/// used deliberately here because the Synchronization.Atomic API is only
/// available from macOS 15. There is one control-thread writer and one audio-
/// callback reader.
private final class ProcessedMicrophoneAtomicFloat: @unchecked Sendable {
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
private final class ProcessedMicrophoneLevelStore: @unchecked Sendable {
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
private final class ProcessedMicrophoneRingBuffer: @unchecked Sendable {
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

    init(format: AVAudioFormat, duration: TimeInterval) {
        let requestedCapacity = max(
            Int(format.sampleRate * duration),
            8_192
        )
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
            let inputSample = input[frame]
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
