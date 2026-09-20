import AVFoundation
import CoreAudio
import Foundation
@testable import AudioLevelBar

/// A voice-processing capture engine that records its calls and opens no
/// device. It can report an output with no sample rate, fail its start, and
/// run a hook inside each call, where a test moves a default device or arms
/// the quiet window at that moment.
final class FakeVoiceProcessingEngine: VoiceProcessingCaptureEngine, @unchecked Sendable {
    enum Call: String, Equatable {
        case loadIONodes = "load-io-nodes"
        case enableVoiceProcessing = "enable-voice-processing"
        case bindDevices = "bind-devices"
        case configureVoiceProcessing = "configure-voice-processing"
        case readInputFormat = "read-input-format"
        case readOutputFormat = "read-output-format"
        case installTap = "install-tap"
        case prepare
        case start
        case stop
        case removeTap = "remove-tap"
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    /// Whether the output format reads as 0 Hz, as a device being
    /// reconfigured does.
    var outputReportsNoSampleRate = false
    /// What `start()` throws, if anything.
    var startError: Error?
    /// What `boundInputDeviceID` reads.
    var boundInput: AudioDeviceID = AudioStateHarness.builtInMicrophone
    /// Runs inside each call, after recording it and before returning.
    var onCall: ((Call) -> Void)?
    /// The call that raises an Objective-C exception, as AVFAudio does while
    /// a device is rebound under the engine, after `onCall` has run.
    var raisesAt: Call?
    /// Whether `installTap` was given a format, and the block it was given.
    private(set) var tapFormatGiven: AVAudioFormat??
    private(set) var tapBlock: AVAudioNodeTapBlock?
    let notificationObject: AnyObject = NSObject()

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func note(_ call: Call) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
        onCall?(call)
        if call == raisesAt {
            NSException(
                name: .internalInconsistencyException,
                reason: "raised by the fake voice-processing engine",
                userInfo: nil
            ).raise()
        }
    }

    func loadIONodes() {
        note(.loadIONodes)
    }

    func enableVoiceProcessing() throws {
        note(.enableVoiceProcessing)
    }

    /// What `bindDevices` throws, if anything, once it has recorded the call.
    var bindError: Error?
    /// The input and output `bindDevices` was given, nil before it was.
    private(set) var boundDevices: (input: AudioDeviceID, output: AudioDeviceID)?
    /// What the output element reads back; the bound output, or the
    /// built-in speakers before a bind, when nil.
    var boundOutputReadBack: AudioDeviceID?
    /// What the input element reads back after a bind; the bound input when
    /// nil.
    var boundInputReadBack: AudioDeviceID?

    func bindDevices(input: AudioDeviceID, output: AudioDeviceID) throws {
        note(.bindDevices)
        if let bindError {
            throw bindError
        }
        lock.lock()
        boundDevices = (input, output)
        lock.unlock()
        boundInput = boundInputReadBack ?? input
    }

    var boundOutputDeviceID: AudioDeviceID {
        lock.lock()
        defer { lock.unlock() }
        return boundOutputReadBack ?? boundDevices?.output ?? AudioStateHarness.speakers
    }

    func configureVoiceProcessing() {
        note(.configureVoiceProcessing)
    }

    func inputFormat() -> AVAudioFormat {
        note(.readInputFormat)
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    }

    func outputFormat() -> AVAudioFormat {
        note(.readOutputFormat)
        guard !outputReportsNoSampleRate else {
            // An AVAudioFormat cannot be made with 0 Hz; one without a layout
            // reads as 0 Hz and no channels.
            return AVAudioFormat()
        }
        return AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {
        lock.lock()
        tapFormatGiven = .some(format)
        tapBlock = block
        lock.unlock()
        note(.installTap)
    }

    func prepare() {
        note(.prepare)
    }

    func start() throws {
        note(.start)
        if let startError {
            throw startError
        }
    }

    func stop() {
        note(.stop)
    }

    func removeTap() {
        note(.removeTap)
    }

    var boundInputDeviceID: AudioDeviceID {
        boundInput
    }
}

/// Every voice-processing capture engine `AudioState` made, in order.
final class VoiceProcessingEngineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeVoiceProcessingEngine] = []
    private var _prepare: ((FakeVoiceProcessingEngine) -> Void)?

    /// Runs on each engine as it is made, before `AudioState` uses it.
    var prepare: ((FakeVoiceProcessingEngine) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _prepare
        }
        set {
            lock.lock()
            _prepare = newValue
            lock.unlock()
        }
    }

    var engines: [FakeVoiceProcessingEngine] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    /// Every call every engine has recorded.
    var callCount: Int {
        engines.reduce(0) { $0 + $1.calls.count }
    }

    func make() -> FakeVoiceProcessingEngine {
        let engine = FakeVoiceProcessingEngine()
        prepare?(engine)
        lock.lock()
        made.append(engine)
        lock.unlock()
        return engine
    }
}
