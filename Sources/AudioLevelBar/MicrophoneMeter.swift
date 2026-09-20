import AudioLevelBarCore
import CoreAudio
import Foundation
import os

enum MicrophoneMeterError: LocalizedError, Equatable {
    case unsupportedFormat
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return localized("The microphone audio format could not be read.")
        case let .operationFailed(operation, status):
            return localized("%1$@ failed (Core Audio status %2$d).", operation, status)
        }
    }
}

/// Meters one explicitly chosen input device through a HAL IOProc.
///
/// The meter is bound to the AudioDeviceID it was started with and never
/// follows the default input by itself. A framework engine that follows the
/// default does so on its own: when a Bluetooth headset arrives it moves the
/// running IO onto the headset's microphone before the app can react, which
/// puts the headset into call mode, and a framework-issued restart of that IO
/// while the headset's input reconfigures can leave coreaudiod waiting for
/// every process. Here nothing moves unless the owner starts the meter on
/// another device.
///
/// Three queues, each with one job:
/// - `lifecycleQueue` re-reads the exact device's transport, reads its format,
///   and creates, starts, stops and destroys the IOProc and its listeners.
///   `AudioDeviceStart` can wait in coreaudiod for an unbounded time, and a
///   wait there costs this queue and nothing else.
/// - `processingQueue` runs the IOProc block and accumulates about 100 ms of
///   samples per level.
/// - `listenerQueue` runs the property listeners. They only close the
///   session's report gate and tell the owner; they never call a HAL lifecycle
///   function. The owner decides a restart on its next evaluation.
///
/// `start(deviceID:)` and `stop(completion:)` must be called from the main
/// thread. Events and levels are delivered on the main thread, only for the
/// current session.
final class MicrophoneMeter {
    enum Event: Equatable {
        /// The IOProc is running on the device.
        case started(AudioDeviceID)
        /// Nothing is left running on the device.
        case failed(AudioDeviceID, MicrophoneMeterError)
        /// The re-read transport ruled the device out; nothing was created.
        case refused(AudioDeviceID, InputOpenRefusal)
        /// The device died or changed its format under the running meter. Its
        /// levels are no longer reported; the resources stay until the owner
        /// starts or stops the meter again.
        case invalidated(AudioDeviceID)
        /// A quiet window armed after the start was issued, and the meter
        /// stopped before its next HAL call. Whatever the start created, and
        /// whatever the meter held before it, stays until the owner starts or
        /// stops the meter again.
        case interrupted(AudioDeviceID)
        /// A quiet window armed after the stop was issued, and the meter kept
        /// what it held rather than stop it inside the window. Its levels are
        /// no longer reported; it stays until the owner starts or stops the
        /// meter again.
        case stopInterrupted
    }

    /// What became of a stop, for a caller that waits for the device to be
    /// released.
    enum StopOutcome: Equatable {
        /// Nothing is left open on the device.
        case stopped
        /// A quiet window armed after the stop was issued. What the meter held
        /// stays until the next start or stop after the window.
        case interrupted
        /// A newer start or stop took over before this one ran.
        case superseded
    }

    var onLevel: ((Float, Float) -> Void)?
    var onEvent: ((Event) -> Void)?

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

    private let halCalls: any HALLifecycleCalls
    private let holdGeneration: LifecycleHoldGeneration
    /// Internal rather than private so a test can suspend it or wait for it.
    let lifecycleQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.microphone-meter.lifecycle",
        qos: .userInitiated
    )
    private let processingQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.microphone-meter",
        qos: .userInteractive
    )
    private let listenerQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.microphone-meter.listener",
        qos: .userInitiated
    )
    private let sessionLock = NSLock()
    private var sessionID = UUID()
    /// Guarded by `sessionLock`. The capture of the IOProc last created,
    /// reachable from the main thread at Quit.
    private weak var liveCapture: CaptureContext?

    /// What one session created on one device.
    private struct Resources {
        let deviceID: AudioDeviceID
        /// The transport class as last read, for the log lines.
        var transport: String
        let capture: CaptureContext
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

    /// Lifecycle-queue confined.
    private var resources: Resources?

    init(halCalls: any HALLifecycleCalls, holdGeneration: LifecycleHoldGeneration) {
        self.halCalls = halCalls
        self.holdGeneration = holdGeneration
    }

    /// Opens `deviceID` and meters it, replacing whatever the meter held.
    ///
    /// The owner issues a start only outside the quiet window, but the
    /// lifecycle queue can reach it later, behind a HAL call that is taking
    /// its time. The start takes the window's generation now and compares it
    /// before each call that releases the previous meter, before it creates
    /// the IOProc, and immediately before `AudioDeviceStart`. A window that
    /// armed in between ends the start there, with `.interrupted`.
    ///
    /// - Parameter issuedToken: The generation the owner's evaluation admitted
    ///   the start under. An advance that lands after that evaluation read
    ///   its admission then fails the first check. nil takes the current one.
    func start(deviceID: AudioDeviceID, holdToken issuedToken: UInt64? = nil) {
        let session = replaceSession()
        let holdToken = issuedToken ?? holdGeneration.current
        lifecycleQueue.async { [self] in
            // A newer start or stop releases what the meter holds when its
            // turn comes.
            guard isCurrentSession(session) else {
                return
            }
            guard holdGeneration.isCurrent(holdToken) else {
                // The meter being replaced keeps running, as any meter does
                // while the window holds.
                interrupt(deviceID: deviceID, transport: "-", session: session, holdToken: holdToken)
                return
            }
            guard
                stopResources(holdToken: holdToken, loggingAnInterruptionAs: .interrupt) == .released
            else {
                // What the previous meter still holds stays until the next
                // start or stop after the window.
                post(.interrupted(deviceID), session: session)
                return
            }
            open(deviceID: deviceID, session: session, holdToken: holdToken)
        }
    }

    /// Stops and destroys the IOProc and calls `completion` on the main
    /// thread with what became of the stop.
    ///
    /// The session is invalidated before dispatching, so a start already
    /// queued behind this cannot bring the meter back up. Like a start, the
    /// stop takes the quiet window's generation now and compares it
    /// immediately before each HAL call it makes: a window that armed in
    /// between leaves what the meter still holds as it is, with its levels no
    /// longer reported, and `.stopInterrupted` tells the owner to stop it
    /// again after the window.
    func stop(holdToken issuedToken: UInt64? = nil, completion: ((StopOutcome) -> Void)? = nil) {
        let session = replaceSession()
        let holdToken = issuedToken ?? holdGeneration.current
        lifecycleQueue.async { [self] in
            let outcome: StopOutcome
            if !isCurrentSession(session) {
                // The newer start or stop releases what the meter holds when
                // its turn comes.
                outcome = .superseded
            } else {
                switch stopResources(holdToken: holdToken) {
                case .released:
                    outcome = .stopped
                case .interrupted:
                    post(.stopInterrupted, session: session)
                    outcome = .interrupted
                }
            }
            if let completion {
                DispatchQueue.main.async {
                    completion(outcome)
                }
            }
        }
    }

    /// coreaudiod restarted. The IOProc and its listeners went with the old
    /// server, and their IDs may name something else now, so they are dropped
    /// on the lifecycle queue without a HAL call: no stop, destroy or listener
    /// removal. The session ends here, so a start or stop already queued
    /// reports nothing. The owner starts the meter again after the window.
    func forgetAfterServiceRestart() {
        invalidateSession()
        lifecycleQueue.async { [self] in
            guard let held = resources else {
                return
            }
            resources = nil
            held.capture.close()
            HALLifecycleLog.record(
                .microphoneIOProc,
                .forget,
                id: held.deviceID,
                transport: held.transport,
                generation: holdGeneration.current
            )
        }
    }

    /// The label of the meter's stop in Quit's `LifecycleStopGroup`.
    static let quitStopLabel = "microphone"

    /// Main thread, Quit only. Ends the session and closes the current
    /// capture's gate, so its IOProc passes nothing on while the process
    /// exits. Both happen under one lock: a start on the lifecycle queue
    /// either set its capture before this reads it, and that capture is
    /// closed, or sets it afterwards and fails its next session check, so it
    /// never reaches `AudioDeviceStart`. Quit's stop releases what it built.
    func closeLevelGateAtQuit() {
        sessionLock.lock()
        sessionID = UUID()
        let capture = liveCapture
        sessionLock.unlock()
        capture?.close()
    }

    /// Quit only. Stops and destroys the IOProc on the lifecycle queue,
    /// whatever the quiet window, and counts it in `stops`, reporting
    /// progress before each HAL call. Nothing is delivered to the main
    /// thread, which is waiting.
    func stopAtQuit(in stops: LifecycleStopGroup) {
        invalidateSession()
        stops.run(label: Self.quitStopLabel, on: lifecycleQueue) { [self] progress in
            stopResources(holdToken: nil, reason: HALLifecycleLog.quitReason, progress: progress)
        }
    }

    /// Runs only on `lifecycleQueue`.
    private func open(deviceID: AudioDeviceID, session: UUID, holdToken: UInt64) {
        // Read the exact device again, uncached, immediately before opening
        // it. The poll that chose it may be a quarter of a second old, and an
        // aggregate's active sub-devices can change while its ID stays.
        let info = halCalls.transportInfo(for: deviceID)
        let transport = AudioDeviceTransportInfo.logDescription(info)
        let firstNote: InputOpenNote
        switch InputOpenPolicy.decide(deviceID: deviceID, info: info) {
        case .refuse(let refusal):
            HALLifecycleLog.record(
                .microphoneIOProc,
                .refuse,
                id: deviceID,
                transport: transport,
                generation: holdToken
            )
            post(.refused(deviceID, refusal), session: session)
            return
        case .open(let note):
            firstNote = note
            if note.shouldBeLogged {
                HALLifecycleLog.record(
                    .microphoneIOProc,
                    .openUnverified,
                    id: deviceID,
                    transport: transport,
                    generation: holdToken
                )
            }
        }

        guard let format = halCalls.inputStreamFormat(for: deviceID) else {
            post(.failed(deviceID, .unsupportedFormat), session: session)
            return
        }
        guard isCurrentSession(session) else {
            return
        }
        guard holdGeneration.isCurrent(holdToken) else {
            interrupt(deviceID: deviceID, transport: transport, session: session, holdToken: holdToken)
            return
        }

        let capture = CaptureContext(
            session: session,
            deviceID: deviceID,
            sampleFormat: format.sampleFormat,
            windowSampleCount: AudioBufferLevels.windowSampleCount(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            ),
            owner: self
        )
        HALLifecycleLog.begin(
            .microphoneIOProc,
            .create,
            id: deviceID,
            transport: transport,
            generation: holdToken
        )
        let (createStatus, newIOProcID) = halCalls.createIOProc(
            deviceID: deviceID,
            queue: processingQueue
        ) { [capture] _, inputData, _, _, _ in
            capture.consume(inputData)
        }
        HALLifecycleLog.record(
            .microphoneIOProc,
            .create,
            id: deviceID,
            transport: transport,
            status: createStatus,
            generation: holdToken
        )
        guard createStatus == noErr, let newIOProcID else {
            capture.close()
            post(
                .failed(
                    deviceID,
                    .operationFailed(
                        localized("Creating the microphone IOProc"),
                        createStatus == noErr ? kAudioHardwareUnspecifiedError : createStatus
                    )
                ),
                session: session
            )
            return
        }
        resources = Resources(
            deviceID: deviceID,
            transport: transport,
            capture: capture,
            ioProcID: newIOProcID
        )
        sessionLock.lock()
        liveCapture = capture
        sessionLock.unlock()
        addListeners(
            for: capture,
            properties: Self.invalidatingProperties
                + (AggregateMembershipPolicy.watchesSubDeviceLists(info) ? SubDeviceListProperty.addresses : []),
            transport: transport,
            holdToken: holdToken
        )

        guard isCurrentSession(session) else {
            // The newer start or stop is queued behind this one and releases
            // it, after its own generation check.
            return
        }

        // Read the device again now that its listeners are in place. A
        // sub-device change made before this read is in it, and one made after
        // it reaches a listener, so nothing starts on the first read alone.
        let startInfo = halCalls.transportInfo(for: deviceID)
        let startTransport = AudioDeviceTransportInfo.logDescription(startInfo)
        resources?.transport = startTransport
        switch InputOpenSequence.afterListeners(
            deviceID: deviceID,
            secondInfo: startInfo,
            generationCurrent: holdGeneration.isCurrent(holdToken)
        ) {
        case let .interrupt(refusal):
            if refusal != nil {
                HALLifecycleLog.record(
                    .microphoneIOProc,
                    .refuse,
                    id: deviceID,
                    transport: startTransport,
                    generation: holdToken
                )
            }
            // Created, not started. The owner's next start or stop, after the
            // window, releases it.
            interrupt(deviceID: deviceID, transport: startTransport, session: session, holdToken: holdToken)
            return
        case let .refuseAndRelease(refusal):
            HALLifecycleLog.record(
                .microphoneIOProc,
                .refuse,
                id: deviceID,
                transport: startTransport,
                generation: holdToken
            )
            // Created, never started: released here, as a failed start is.
            guard
                stopResources(holdToken: holdToken, loggingAnInterruptionAs: .interrupt) == .released
            else {
                post(.interrupted(deviceID), session: session)
                return
            }
            post(.refused(deviceID, refusal), session: session)
            return
        case let .start(note):
            if note.shouldBeLogged, note != firstNote {
                HALLifecycleLog.record(
                    .microphoneIOProc,
                    .openUnverified,
                    id: deviceID,
                    transport: startTransport,
                    generation: holdToken
                )
            }
        }
        if InputOpenSequence.addsSubDeviceListenersAfterSecondRead(first: info, second: startInfo) {
            addListeners(
                for: capture,
                properties: SubDeviceListProperty.addresses,
                transport: startTransport,
                holdToken: holdToken
            )
        }

        resources?.ioProc = .startUnconfirmed
        HALLifecycleLog.begin(
            .microphoneIOProc,
            .start,
            id: deviceID,
            transport: startTransport,
            generation: holdToken
        )
        let startStatus = halCalls.start(deviceID: deviceID, ioProcID: newIOProcID)
        HALLifecycleLog.record(
            .microphoneIOProc,
            .start,
            id: deviceID,
            transport: startTransport,
            status: startStatus,
            generation: holdToken
        )
        guard startStatus == noErr else {
            guard
                stopResources(holdToken: holdToken, loggingAnInterruptionAs: .interrupt) == .released
            else {
                // The start waited long enough for a window to arm. What it
                // created and has not released yet is released after the
                // window, not inside it.
                post(.interrupted(deviceID), session: session)
                return
            }
            post(
                .failed(
                    deviceID,
                    .operationFailed(localized("Starting microphone level monitoring"), startStatus)
                ),
                session: session
            )
            return
        }
        resources?.ioProc = .started

        guard isCurrentSession(session) else {
            // A stop or another start landed while this one was starting. It
            // is queued behind this one and stops what started here, after
            // its own generation check.
            return
        }
        post(.started(deviceID), session: session)
    }

    /// Runs only on `lifecycleQueue`. Adds one listener block for
    /// `properties` to what the current resources already listen to.
    ///
    /// A listener that cannot be added is logged and skipped rather than
    /// failing the start: the poll still notices a default-input change, and
    /// the level math reads each buffer's own byte size.
    private func addListeners(
        for capture: CaptureContext,
        properties: [AudioObjectPropertyAddress],
        transport: String,
        holdToken: UInt64
    ) {
        let deviceID = capture.deviceID
        let session = capture.session
        let listener: AudioObjectPropertyListenerBlock = resources?.listenerBlock ?? { [weak self, capture] count, addresses in
            // Only closes the gate, tells the owner on the main thread, and
            // for an aggregate's active sub-devices asks the lifecycle queue
            // to read the device again. A change of its full composition only
            // invalidates. Never a HAL call.
            let activeSubDevicesChanged = SubDeviceListProperty.isActiveAmong(count, addresses)
            if capture.close() {
                self?.post(.invalidated(deviceID), session: session)
            }
            if activeSubDevicesChanged {
                self?.recheckAggregateMembership(of: capture)
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
                    .microphoneListener,
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

    /// Runs only on `lifecycleQueue`. Releases everything the current
    /// resources hold, one HAL call at a time, in `LifecycleTeardown`'s order:
    /// the listeners, the stop, then the IOProc. After a start that did not
    /// return `noErr`, whether the device reports the IO running is read
    /// first, and running IO is stopped before its IOProc is destroyed.
    ///
    /// `holdToken` is the quiet window's generation the release was issued
    /// in, compared immediately before the listener removal and before each
    /// lifecycle call. At a mismatch the release ends there, logs the call it
    /// held back as `interruption`, and keeps what remains, recorded as far as
    /// it got, for the next start or stop after the window. A device that
    /// already vanished answers with a bad device or bad object status, which
    /// is logged and otherwise tolerated.
    ///
    /// - Parameters:
    ///   - holdToken: nil for a release the quiet window does not hold.
    ///   - interruption: `interrupt-stop` for a stop, `interrupt` for the
    ///     release a start makes of what it replaces or created.
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
        current.capture.close()

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
                    .microphoneIOProc,
                    .stop,
                    id: current.deviceID,
                    transport: current.transport,
                    generation: holdToken,
                    reason: stopReason
                )
                let stopStatus = halCalls.stop(deviceID: current.deviceID, ioProcID: current.ioProcID)
                HALLifecycleLog.record(
                    .microphoneIOProc,
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
                    .microphoneIOProc,
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
                    .microphoneIOProc,
                    .destroy,
                    id: current.deviceID,
                    transport: current.transport,
                    status: destroyStatus,
                    generation: holdToken,
                    reason: reason
                )
                teardown.complete(.destroyIOProc)
            case .destroyAggregate, .destroyProcessTap:
                // The meter holds neither.
                teardown.complete(step)
            }
            current.ioProc = teardown.ioProc
            resources = current
        }
        resources = nil
        return .released
    }

    /// Runs only on `lifecycleQueue`.
    private func interruptRelease(
        of held: Resources,
        as operation: HALLifecycleLog.Operation,
        holdToken: UInt64?
    ) -> Release {
        HALLifecycleLog.record(
            .microphoneIOProc,
            operation,
            id: held.deviceID,
            transport: held.transport,
            generation: holdToken
        )
        return .interrupted
    }

    /// Listener queue. Has the lifecycle queue read the aggregate the IOProc
    /// runs on again, uncached, after its active sub-devices changed.
    ///
    /// A last resort, and a lifecycle step the quiet window does not hold:
    /// the meter never opens an aggregate that names a Bluetooth member, so
    /// this is reached only when the composition is edited while it is open.
    /// If a Bluetooth device is now active in the aggregate, the IOProc is
    /// stopped and destroyed at once, because a stop of the app's own IO is
    /// safer than letting it carry the headset's microphone through the
    /// headset's configuration change. Nothing is started here; the owner
    /// already has the invalidation and decides after the window. The stop is
    /// not exempt from the hardware gate's judgement of stops against the
    /// Bluetooth configuration-change requests.
    private func recheckAggregateMembership(of capture: CaptureContext) {
        lifecycleQueue.async { [self] in
            guard let current = resources, current.capture === capture else {
                // Already released, or replaced by a newer start.
                return
            }
            let info = halCalls.transportInfo(for: current.deviceID)
            guard AggregateMembershipPolicy.afterActiveSubDevicesChanged(info) == .stopNow else {
                return
            }
            HALLifecycleLog.record(
                .microphoneIOProc,
                .refuse,
                id: current.deviceID,
                transport: AudioDeviceTransportInfo.logDescription(info),
                generation: nil,
                reason: SubDeviceListProperty.bluetoothJoinedReason
            )
            stopResources(holdToken: nil, reason: SubDeviceListProperty.bluetoothJoinedReason)
        }
    }

    /// Runs only on `lifecycleQueue`.
    private func interrupt(
        deviceID: AudioDeviceID,
        transport: String,
        session: UUID,
        holdToken: UInt64
    ) {
        HALLifecycleLog.record(
            .microphoneIOProc,
            .interrupt,
            id: deviceID,
            transport: transport,
            generation: holdToken
        )
        post(.interrupted(deviceID), session: session)
    }

    private func post(_ event: Event, session: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, isCurrentSession(session) else {
                return
            }
            onEvent?(event)
        }
    }

    fileprivate func deliverLevel(rmsDecibels: Float, peakDecibels: Float, session: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, isCurrentSession(session) else {
                return
            }
            onLevel?(rmsDecibels, peakDecibels)
        }
    }

    private func replaceSession() -> UUID {
        let newSessionID = UUID()
        sessionLock.lock()
        sessionID = newSessionID
        sessionLock.unlock()
        return newSessionID
    }

    private func invalidateSession() {
        _ = replaceSession()
    }

    private func isCurrentSession(_ candidate: UUID) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionID == candidate
    }
}

/// The sub-device lists of an aggregate device, which the microphone meter
/// and the processed microphone's capture watch on an aggregate they have
/// open: the active sub-devices, whose change is read again at once, and the
/// full composition, whose change only invalidates.
enum SubDeviceListProperty {
    static let active = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static let full = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static let addresses = [active, full]

    /// The `reason` on the log lines of an IOProc stopped at once because a
    /// Bluetooth device became active in its aggregate.
    static let bluetoothJoinedReason = "bluetooth-sub-device"

    /// Whether a property listener was called for the active sub-device list.
    static func isActiveAmong(
        _ count: UInt32,
        _ addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) -> Bool {
        UnsafeBufferPointer(start: addresses, count: Int(count)).contains {
            $0.mSelector == kAudioAggregateDevicePropertyActiveSubDeviceList
        }
    }
}

/// One session's capture state, shared by the IOProc block, the listeners and
/// the lifecycle queue.
///
/// The IOProc block holds it strongly, and a block already queued on the
/// processing queue can outlive `AudioDeviceDestroyIOProcID`; the closed gate
/// is what keeps such a block from reporting anything.
private final class CaptureContext {
    let session: UUID
    let deviceID: AudioDeviceID
    private let sampleFormat: PCMSampleFormat
    private let windowSampleCount: Int
    private weak var owner: MicrophoneMeter?
    private let gate = OSAllocatedUnfairLock(initialState: true)
    /// Processing-queue confined.
    private var accumulator = LevelAccumulator()

    init(
        session: UUID,
        deviceID: AudioDeviceID,
        sampleFormat: PCMSampleFormat,
        windowSampleCount: Int,
        owner: MicrophoneMeter
    ) {
        self.session = session
        self.deviceID = deviceID
        self.sampleFormat = sampleFormat
        self.windowSampleCount = windowSampleCount
        self.owner = owner
    }

    /// Runs only on the processing queue.
    func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        guard gate.withLock({ $0 }) else {
            return
        }
        accumulator.add(inputData, format: sampleFormat)
        guard
            accumulator.sampleCount >= windowSampleCount,
            let levels = accumulator.take()
        else {
            return
        }
        owner?.deliverLevel(
            rmsDecibels: levels.rmsDecibels,
            peakDecibels: levels.peakDecibels,
            session: session
        )
    }

    /// Stops reporting. True when this call closed an open gate.
    @discardableResult
    func close() -> Bool {
        gate.withLock { isOpen in
            defer { isOpen = false }
            return isOpen
        }
    }
}
