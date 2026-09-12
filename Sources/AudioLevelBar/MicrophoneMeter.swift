import AVFoundation
import AudioLevelBarCore
import Foundation
import ObjCExceptionShim

/// Watches the default input and reports RMS and peak levels.
///
/// Every engine operation runs on a serial lifecycle queue rather than the
/// caller's thread. `AVAudioEngine.inputNode` opens the current default input
/// through the HAL, and a device that is slow to answer — a Continuity
/// microphone on an iPhone that has to wake and connect, most reliably — leaves
/// that call spinning inside AVFAudio. Called from the main thread, as it was,
/// that spin freezes the menu, the panel, and Quit, which is what pushes a user
/// into force quitting. Serializing here keeps the wait where it belongs.
///
/// `start()`, `restart()`, and `stop()` must be called from the main thread.
/// Only the scheduled-restart bookkeeping requires it; everything touching the
/// engine is confined to the lifecycle queue.
final class MicrophoneMeter {
    var onLevel: ((Float, Float) -> Void)?
    var onError: ((String) -> Void)?

    private let lifecycleQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.microphone-meter.lifecycle",
        qos: .userInitiated
    )
    private let sessionLock = NSLock()
    private var sessionID = UUID()

    /// Queue-confined: only ever touched inside `lifecycleQueue`.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    /// Queue-confined. The engine release a suspend deferred; see
    /// `scheduleEngineRelease()`.
    private var pendingEngineRelease: DispatchWorkItem?

    /// Main-confined.
    private var scheduledRestart: DispatchWorkItem?
    /// Main-confined. False between suspend()/stop() and the next start().
    /// The configuration-change observer delivers on the main queue, and a
    /// block already enqueued there survives removeObserver — so cancelling
    /// the scheduled restart is not enough: the late block would schedule a
    /// new one, and start() mints a fresh session that no invalidation can
    /// veto. The revived meter would reopen the very input the caller just
    /// released. Disarming here, on the same thread the block runs on, is
    /// what actually closes that door.
    private var restartsArmed = false
    /// Main-confined. Consecutive shim-caught start failures. The retry loop
    /// re-reads the settled format 0.75 s later, but a permanently hostile
    /// device would otherwise retry forever, and every caught raise leaks a
    /// little (the exception object, and the tap closure context the foreign
    /// unwind never cleans up). External triggers — a device change, a panel
    /// opening — still get their attempt regardless; success resets this.
    private var shimRetryCount = 0

    func start() {
        start(completion: nil)
    }

    private func start(completion: (() -> Void)?) {
        restartsArmed = true
        let session = replaceSession()
        cancelScheduledRestart()

        lifecycleQueue.async { [self] in
            // Always fires, including when a newer start superseded this one.
            // The caller is waiting on the queue having finished, not on this
            // particular session winning, and a completion that can silently
            // never run strands whatever depends on it.
            defer {
                if let completion {
                    DispatchQueue.main.async(execute: completion)
                }
            }
            quiesceEngine()
            guard isCurrentSession(session) else {
                return
            }
            startEngine(session: session)
        }
    }

    func restart() {
        start(completion: nil)
    }

    /// Restarts and calls `completion` on the main thread once the engine has
    /// been brought up, or has failed to.
    ///
    /// The processed microphone needs this: publishing its device translates
    /// this process's pid to a Core Audio process object, and that only exists
    /// once something here has opened audio. Running the meter first is what
    /// opens it, and `start()` is asynchronous, so a caller that depends on the
    /// object waits for this completion rather than assuming it.
    func restart(completion: @escaping () -> Void) {
        start(completion: completion)
    }

    func stop() {
        stop(completion: nil)
    }

    /// Stops the engine and, when given a completion, calls it on the main
    /// thread once the input device is actually released.
    ///
    /// The completion exists for one caller: the processed microphone starts
    /// voice processing on the same physical input this meter holds, so the
    /// device has to be released before voice processing claims it. The engine
    /// is serialized on `lifecycleQueue`, which makes `stop()` a request rather
    /// than a guarantee, so a caller that needs the device free waits for this
    /// completion rather than assuming it.
    func stop(completion: (() -> Void)?) {
        // Invalidate before dispatching so a start already queued behind this
        // cannot bring the engine back up after the caller asked for silence.
        restartsArmed = false
        invalidateSession()
        cancelScheduledRestart()
        lifecycleQueue.async { [self] in
            teardownResources()
            guard let completion else {
                return
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Stops capturing now and lets go of the engine shortly after.
    ///
    /// The Bluetooth pause calls this every time the panels close. Stopping
    /// the engine ends the IO — the in-use light goes out — but a stopped
    /// engine still holds its claim on the input device, and with a Bluetooth
    /// headset that claim alone keeps the link in call mode with playback
    /// degraded. Measured directly: stop(), reset(), and
    /// deallocateRenderResources() all leave that pin in place, and only
    /// releasing the engine object frees it. The release is deferred rather
    /// than immediate because deallocating an AVAudioEngine in the middle of
    /// a device-change storm is what crashed a pre-publication build —
    /// AVFAudio's own IO unit property listener races the dealloc — and a
    /// transport-change suspend runs milliseconds after a device arrived. The
    /// configuration observer comes off too; a device change while suspended
    /// must not schedule a restart the policy never asked for. `stop()`
    /// remains the immediate-teardown path for shutdown and for handing the
    /// input to the processed microphone.
    func suspend() {
        restartsArmed = false
        invalidateSession()
        cancelScheduledRestart()
        lifecycleQueue.async { [self] in
            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
                self.configurationObserver = nil
            }
            quiesceEngine()
            scheduleEngineRelease()
        }
    }

    /// Runs only on `lifecycleQueue`. See `suspend()` for why the release
    /// exists and why it waits. A start that lands meanwhile cancels it and
    /// reuses the engine.
    private func scheduleEngineRelease() {
        pendingEngineRelease?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            pendingEngineRelease = nil
            engine = nil
        }
        pendingEngineRelease = workItem
        lifecycleQueue.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    private func startEngine(session: UUID) {
        pendingEngineRelease?.cancel()
        pendingEngineRelease = nil
        // Reuse the engine instead of building one per start. Releasing an
        // AVAudioEngine races AVFAudio's own IO unit property listener: an
        // arriving device fires that listener on the AVAudioIOUnit queue while
        // the last reference goes away here, and the block then messages freed
        // memory. Observed on hardware as a crash the first time AirPods
        // became the default input, with this queue inside
        // -[AVAudioEngine dealloc] and the listener block on the other side of
        // the race. A restart is exactly when the listener is busiest, so the
        // restart path keeps the object and redoes only the tap.
        let engine = self.engine ?? AVAudioEngine()
        // Retain it before reading inputNode. That read is what instantiates
        // the IO unit and registers the listener, and an early return below
        // would otherwise drop the only reference to a brand-new engine
        // immediately after it.
        self.engine = engine
        // The call that can spin. It runs on the lifecycle queue, so a
        // microphone that never answers costs this queue and nothing else.
        let inputNode = engine.inputNode
        // The hardware format, not outputFormat(forBus:). They agree only while
        // the input device runs at the engine's rate. An AirPods microphone
        // runs at 24 kHz while outputFormat keeps reporting 48 kHz, and a tap
        // installed at the wrong rate starts without ever delivering a frame —
        // the meter sits at `--` with nothing to report. Reading the input side
        // gives the rate the device is actually running at.
        let format = inputNode.inputFormat(forBus: 0)

        guard isCurrentSession(session) else {
            return
        }

        guard format.sampleRate > 0, format.channelCount > 0 else {
            report(localized("The selected microphone did not provide an audio format."), session: session)
            return
        }

        // Passing the hardware format explicitly. nil resolves to the node's
        // outputFormat, which is the rate that does not match a 24 kHz
        // microphone, and the engine then refuses to start at all
        // (kAudioUnitErr_FormatNotSupported). A format that disagrees with the
        // hardware is also what -installTapOnBus: raises on, and an
        // Objective-C exception cannot be caught from Swift, so this has to be
        // the rate the device is really running at.
        // Even freshly read, the format can be stale by the time AVFAudio
        // validates it inside installTap: a device change in flight moves the
        // hardware rate between the read and the install, and the resulting
        // Objective-C exception cannot be caught from Swift — it killed
        // builds 42 and 45 during fast microphone switching. The shim turns
        // it into a value, and the scheduled restart tries again once the
        // change has settled.
        let installException = ALBCatchObjCException {
            inputNode.installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(
                    min(max(format.sampleRate * 0.1, 1_024), 8_192)
                ),
                format: format
            ) { [weak self] buffer, _ in
                guard let levels = Self.levels(from: buffer) else {
                    return
                }
                DispatchQueue.main.async {
                    guard self?.isCurrentSession(session) == true else {
                        return
                    }
                    self?.onLevel?(levels.rms, levels.peak)
                }
            }
        }
        if let installException {
            report(
                localized(
                    "Could not start microphone level monitoring: %@",
                    installException.reason ?? installException.name.rawValue
                ),
                session: session
            )
            scheduleShimRetry(session: session)
            return
        }

        // start can raise the same way installTap can — AVFAudio's graph
        // configuration checks the rate again and raises rather than returns
        // when it moved — so the shim covers it too. A Swift error thrown by
        // start comes out through startError instead.
        var startError: Error?
        let startException = ALBCatchObjCException {
            do {
                engine.prepare()
                try engine.start()
            } catch {
                startError = error
            }
        }
        if let startException {
            inputNode.removeTap(onBus: 0)
            report(
                localized(
                    "Could not start microphone level monitoring: %@",
                    startException.reason ?? startException.name.rawValue
                ),
                session: session
            )
            scheduleShimRetry(session: session)
            return
        }
        if let startError {
            inputNode.removeTap(onBus: 0)
            report(
                localized("Could not start microphone level monitoring: %@", startError.localizedDescription),
                session: session
            )
            return
        }
        guard isCurrentSession(session) else {
            // A stop landed while the engine was starting. Undo it here
            // rather than leave a running engine nothing will stop.
            inputNode.removeTap(onBus: 0)
            engine.stop()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.shimRetryCount = 0
        }
        observeConfigurationChanges(of: engine)
    }

    /// Runs only on `lifecycleQueue`.
    ///
    /// Registered once per engine. The engine outlives a restart, so re-adding
    /// this on every start would stack observers on one object.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        guard configurationObserver == nil else {
            return
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRestart()
        }
    }

    /// Runs only on `lifecycleQueue`.
    ///
    /// Stops the engine and drops its tap while keeping the object, so a
    /// restart never has to deallocate one. `teardownResources()` remains the
    /// path that actually lets the input device go, for the caller that needs
    /// it free.
    private func quiesceEngine() {
        guard let engine else {
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Runs only on `lifecycleQueue`.
    private func teardownResources() {
        pendingEngineRelease?.cancel()
        pendingEngineRelease = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else {
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func report(_ message: String, session: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(session) == true else {
                return
            }
            self?.onError?(message)
        }
    }

    private func cancelScheduledRestart() {
        if Thread.isMainThread {
            scheduledRestart?.cancel()
            scheduledRestart = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduledRestart?.cancel()
                self?.scheduledRestart = nil
            }
        }
    }

    /// Retries a start whose AVFAudio call raised, once the device change
    /// that made it raise has settled. Gated on the session still being
    /// current — a newer start supersedes the failed one and must not be
    /// torn down by its predecessor's retry — and on the retry budget.
    private func scheduleShimRetry(session: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, isCurrentSession(session) else {
                return
            }
            guard shimRetryCount < 8 else {
                return
            }
            shimRetryCount += 1
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard restartsArmed, scheduledRestart == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.scheduledRestart = nil
            self?.start()
        }
        scheduledRestart = workItem
        // Long enough for the input rebinding behind a configuration change to
        // settle. A restart that lands while AVFAudio is still inside
        // IOBindingChanged touches a node whose format is in the middle of
        // moving. Measured on hardware, 0.3 s is not clear of that window and
        // 0.75 s is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func replaceSession() -> UUID {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        sessionID = UUID()
        return sessionID
    }

    private func invalidateSession() {
        sessionLock.lock()
        sessionID = UUID()
        sessionLock.unlock()
    }

    private func isCurrentSession(_ session: UUID) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionID == session
    }

    private static func levels(from buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float)? {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0,
            buffer.format.channelCount > 0
        else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sumOfSquares: Float = 0
        var peak: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let amplitude = abs(samples[frame])
                sumOfSquares += amplitude * amplitude
                peak = max(peak, amplitude)
            }
        }

        let sampleCount = Float(frameCount * channelCount)
        let rms = sqrt(sumOfSquares / sampleCount)
        return (
            rms: MeterScale.decibels(amplitude: rms),
            peak: MeterScale.decibels(amplitude: peak)
        )
    }
}
