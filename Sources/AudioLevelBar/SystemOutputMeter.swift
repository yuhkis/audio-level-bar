import AudioLevelBarCore
import CoreAudio
import Darwin
import Foundation
import os

enum SystemOutputMeterError: LocalizedError {
    case unsupportedOS
    case permissionDenied
    case audioProcessUnavailable
    case unsupportedFormat
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return localized("Monitoring the system playback level requires macOS 14.2 or later.")
        case .permissionDenied:
            return localized("System audio recording is not allowed.")
        case .audioProcessUnavailable:
            return localized("Audio Level Bar could not exclude itself from system playback monitoring.")
        case .unsupportedFormat:
            return localized("The system playback audio format could not be read.")
        case let .operationFailed(operation, status):
            return localized("%1$@ failed (Core Audio status %2$d).", operation, status)
        }
    }
}

final class SystemOutputMeter {
    /// 20 Hz while a SwiftUI meter is on screen.
    private static let detailedEmissionIntervalNanoseconds: UInt64 = 50_000_000
    /// 4 Hz otherwise. Only the menu bar item consumes levels then, and it
    /// redraws every 0.5 s.
    private static let idleEmissionIntervalNanoseconds: UInt64 = 250_000_000

    /// Watched on the private aggregate device: it went away, its input
    /// streams changed, or its IO stopped without being asked to.
    private static let aggregateInvalidatingProperties: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOStoppedAbnormally,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    ]

    /// Watched on the tapped output device.
    private static let outputInvalidatingProperties: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    ]

    var onLevel: ((Float, Float) -> Void)?
    var onStarted: (() -> Void)?
    var onError: ((SystemOutputMeterError) -> Void)?
    /// A quiet window armed while a start was on its way to the HAL, and the
    /// start stopped before its next create or start. Whatever it created,
    /// and the meter it was replacing, stay until the next start or stop.
    var onInterrupted: (() -> Void)?
    /// A quiet window armed while a stop was on its way to the HAL, and the
    /// stop left the tap, the aggregate device and the IOProc in place. Its
    /// levels are no longer reported; it stays until the next start or stop.
    var onStopInterrupted: (() -> Void)?
    /// The default output read again on the lifecycle queue was not the
    /// output the start was issued for, or could not be read. The start
    /// stopped before touching anything: the tap already running stays until
    /// the owner's next start or stop.
    var onOutputMoved: (() -> Void)?
    /// A listener reported the private aggregate device or the tapped output
    /// dead or reconfigured. Levels stopped there, and nothing was stopped or
    /// destroyed: what the meter holds stays until the owner's next start or
    /// stop, after the quiet window. Reported once per start.
    var onInvalidated: (() -> Void)?
    /// A listener of the current build fired again after `onInvalidated`: the
    /// device is still reconfiguring. Nothing was stopped or destroyed. The
    /// quiet window's generation was already advanced on the listener queue;
    /// the owner extends the window, so the rebuild waits for the last
    /// notification of the change rather than the first.
    var onChangeObserved: (() -> Void)?

    private let processingQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.system-output-meter",
        qos: .userInteractive
    )
    /// Internal rather than private so a test can suspend it or wait for it.
    let lifecycleQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.system-output-meter.lifecycle",
        qos: .userInitiated
    )
    private let listenerQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.system-output-meter.listener",
        qos: .userInitiated
    )
    private let halCalls: any HALLifecycleCalls
    private let holdGeneration: LifecycleHoldGeneration
    private let sessionLock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// Lifecycle-queue confined. What became of `ioProcID`.
    private var ioProcState: LifecycleTeardown.IOProc = .none
    /// Lifecycle-queue confined. The tapped output's transport class, for the
    /// HAL lifecycle log of the resources built for it.
    private var tappedTransport = "-"
    /// Lifecycle-queue confined. The tapped output's ID, read uncached when
    /// the start was admitted, for its listener and the log.
    private var tappedOutputID = AudioObjectID(kAudioObjectUnknown)
    /// Lifecycle-queue confined. The listeners added for the current build,
    /// with the one block they share.
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var listeners: [(deviceID: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    /// Guarded by `sessionLock`. The gate of the current build's levels,
    /// reachable from the main thread.
    private var levelGate: SystemOutputLevelGate?
    private var sessionID = UUID()

    /// Only ever touched on `processingQueue`, which also serializes every
    /// `consume(_:...)` call, so the interval can be retuned without a lock in
    /// the audio callback.
    private final class EmissionState {
        var lastEmissionNanoseconds: UInt64 = 0
        var intervalNanoseconds = SystemOutputMeter.idleEmissionIntervalNanoseconds
    }

    private let emissionState = EmissionState()

    /// What became of a release of the tap, the aggregate device and the
    /// IOProc.
    private enum Release: Equatable {
        case released
        /// A quiet window armed after the release was issued. What it had
        /// not yet stopped or destroyed stays.
        case interrupted
    }

    private enum LifecycleCancellation: Error {
        case superseded
        /// A quiet window armed after the start was issued.
        case interrupted
    }

    init(halCalls: any HALLifecycleCalls, holdGeneration: LifecycleHoldGeneration) {
        self.halCalls = halCalls
        self.holdGeneration = holdGeneration
    }

    /// - Parameter transportDescription: The output device's transport class,
    ///   recorded in the HAL lifecycle log. Never a name or UID.
    /// - Parameter issuedToken: The generation the owner's evaluation admitted
    ///   the start under; nil takes the current one.
    func start(
        deviceUID: String,
        transportDescription: String = "-",
        excludingCurrentProcess: Bool = false,
        holdToken issuedToken: UInt64? = nil
    ) {
        let newSessionID = replaceSession()

        guard #available(macOS 14.2, *) else {
            lifecycleQueue.async { [self] in
                stopResources(holdToken: nil)
            }
            report(.unsupportedOS, sessionID: newSessionID)
            return
        }

        // AudioDeviceStart can wait in Core Audio for an unbounded amount of
        // time on a broken or reconfiguring route. Keep every HAL lifecycle
        // operation serialized, but never run it on the UI thread. The owner
        // issues a start only outside the quiet window; the generation taken
        // here is compared before each create and before the start, so a
        // window that armed while the queue was busy ends the start there.
        let holdToken = issuedToken ?? holdGeneration.current
        lifecycleQueue.async { [self] in
            // A newer start or stop releases the resources when its turn
            // comes.
            guard isCurrentSession(newSessionID) else {
                return
            }
            guard holdGeneration.isCurrent(holdToken) else {
                // The tap being replaced keeps running while the window holds.
                HALLifecycleLog.record(
                    .systemOutputTap,
                    .interrupt,
                    id: AudioObjectID(kAudioObjectUnknown),
                    transport: transportDescription,
                    generation: holdToken
                )
                reportInterrupted(sessionID: newSessionID)
                return
            }
            // The rebuild was decided from a poll that may be a quarter of a
            // second old, and this queue may have waited since. Read the
            // default output again, uncached, before stopping or creating
            // anything: an output that moved means a change is under way.
            guard let outputID = defaultOutput(matching: deviceUID) else {
                HALLifecycleLog.record(
                    .systemOutputTap,
                    .interrupt,
                    id: AudioObjectID(kAudioObjectUnknown),
                    transport: transportDescription,
                    generation: holdToken
                )
                reportOutputMoved(sessionID: newSessionID)
                return
            }
            guard
                stopResources(holdToken: holdToken, loggingAnInterruptionAs: .interrupt) == .released
            else {
                // What the previous meter still holds stays until the next
                // start or stop after the window.
                reportInterrupted(sessionID: newSessionID)
                return
            }
            tappedTransport = transportDescription
            tappedOutputID = outputID

            do {
                try configureAndStart(
                    deviceUID: deviceUID,
                    excludingCurrentProcess: excludingCurrentProcess,
                    sessionID: newSessionID,
                    holdToken: holdToken
                )
                guard isCurrentSession(newSessionID) else {
                    // The newer start or stop is queued behind this one and
                    // releases what started here, after its own generation
                    // check.
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard self?.isCurrentSession(newSessionID) == true else {
                        return
                    }
                    self?.onStarted?()
                }
            } catch LifecycleCancellation.superseded {
                // The newer start or stop releases what was built.
            } catch LifecycleCancellation.interrupted {
                // Nothing is destroyed while the window holds. What was
                // created stays, not started, until the rebuild after it.
                reportInterrupted(sessionID: newSessionID)
            } catch let error as SystemOutputMeterError {
                releaseFailedStart(error, holdToken: holdToken, sessionID: newSessionID)
            } catch {
                releaseFailedStart(
                    .operationFailed(localized("Starting system playback level monitoring"), -1),
                    holdToken: holdToken,
                    sessionID: newSessionID
                )
            }
        }
    }

    /// Stops and destroys the tap, the aggregate device and the IOProc.
    ///
    /// Levels stop at once, because the session ends here. Like a start, the
    /// stop takes the quiet window's generation now and compares it
    /// immediately before each HAL call it makes: a window that armed in
    /// between leaves what is not yet stopped or destroyed in place, reported
    /// through `onStopInterrupted`, until the owner's next start or stop after
    /// the window.
    func stop(holdToken issuedToken: UInt64? = nil) {
        let session = replaceSession()
        let holdToken = issuedToken ?? holdGeneration.current
        lifecycleQueue.async { [self] in
            // A newer start or stop releases the resources when its turn
            // comes.
            guard isCurrentSession(session), holdsResources else {
                return
            }
            if stopResources(holdToken: holdToken) == .interrupted {
                reportStopInterrupted(sessionID: session)
            }
        }
    }

    /// Main thread. Calls `body` on the main thread once the lifecycle queue
    /// has come back from everything issued to it before this call, whether
    /// or not its session is still current. The owner uses it to tell a start
    /// or stop that is waiting in coreaudiod.
    func afterLifecycleQueue(_ body: @escaping () -> Void) {
        lifecycleQueue.async {
            DispatchQueue.main.async(execute: body)
        }
    }

    /// Lifecycle-queue confined.
    private var holdsResources: Bool {
        tapID != kAudioObjectUnknown || aggregateDeviceID != kAudioObjectUnknown
    }

    /// Lifecycle-queue confined. The tapped output for the log, once read.
    private var loggedOutput: AudioObjectID? {
        tappedOutputID == kAudioObjectUnknown ? nil : tappedOutputID
    }

    /// Lifecycle-queue confined. The UID this meter generated for its
    /// aggregate device, for the log, from immediately before the create
    /// until the create fails, or the aggregate device is destroyed or
    /// forgotten.
    private var loggedAggregateUID: String?

    /// Lifecycle-queue confined. The UID of this meter's process tap, for the
    /// log: the UUID its description carries on the create's own lines, then
    /// the UID the HAL reports for it, until the create fails, or the tap is
    /// destroyed or forgotten.
    private var loggedTapUID: String?

    /// Runs only on `lifecycleQueue`. The default output, read now and
    /// uncached, when it is still the device with `deviceUID`. A failed read
    /// counts as moved.
    private func defaultOutput(matching deviceUID: String) -> AudioObjectID? {
        guard
            let deviceID = halCalls.defaultOutputDeviceID(),
            deviceID != kAudioObjectUnknown,
            let currentUID = halCalls.deviceUID(for: deviceID),
            currentUID == deviceUID
        else {
            return nil
        }
        return deviceID
    }

    /// Runs only on `lifecycleQueue`. Releases what a failed start built and
    /// reports the failure, unless a quiet window armed after the start was
    /// issued: then what it has not released yet stays, and the start is
    /// reported as interrupted, for the rebuild after the window to release.
    private func releaseFailedStart(
        _ error: SystemOutputMeterError,
        holdToken: UInt64,
        sessionID: UUID
    ) {
        switch stopResources(holdToken: holdToken, loggingAnInterruptionAs: .interrupt) {
        case .released:
            report(error, sessionID: sessionID)
        case .interrupted:
            reportInterrupted(sessionID: sessionID)
        }
    }

    /// Raises the level emission rate while a SwiftUI meter can show it.
    func setDetailedLevelUpdatesEnabled(_ enabled: Bool) {
        let interval = enabled
            ? Self.detailedEmissionIntervalNanoseconds
            : Self.idleEmissionIntervalNanoseconds
        processingQueue.async { [emissionState] in
            emissionState.intervalNanoseconds = interval
        }
    }

    /// coreaudiod restarted. The tap, the aggregate device, the IOProc and the
    /// listeners went with the old server, and their IDs may name something
    /// else now, so they are dropped on the lifecycle queue without a HAL
    /// call. The session ends here; the owner rebuilds after the window, and
    /// that rebuild has nothing to destroy first.
    func forgetAfterServiceRestart() {
        invalidateSession()
        closeLevelGate()
        lifecycleQueue.async { [self] in
            if tapID != kAudioObjectUnknown {
                HALLifecycleLog.record(
                    .systemOutputTap,
                    .forget,
                    id: tapID,
                    transport: tappedTransport,
                    generation: holdGeneration.current,
                    output: loggedOutput,
                    aggregateUID: loggedAggregateUID,
                    tapUID: loggedTapUID
                )
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                HALLifecycleLog.record(
                    .systemOutputAggregate,
                    .forget,
                    id: aggregateDeviceID,
                    transport: tappedTransport,
                    generation: holdGeneration.current,
                    output: loggedOutput,
                    aggregateUID: loggedAggregateUID,
                    tapUID: loggedTapUID
                )
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            loggedAggregateUID = nil
            loggedTapUID = nil
            ioProcID = nil
            ioProcState = .none
            listenerBlock = nil
            listeners = []
            tappedOutputID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// The label of the meter's stop in Quit's `LifecycleStopGroup`.
    static let quitStopLabel = "system-output"

    /// Main thread, Quit only. Ends the session and closes the current
    /// build's level gate, so its IOProc passes nothing on while the process
    /// exits. Both happen under one lock, the session first: a build on the
    /// lifecycle queue either installed its gate before this reads it, and
    /// that gate is closed, or installs it afterwards and fails its session
    /// check before `AudioDeviceStart`. Closing the gate alone would let such
    /// a build start IO with an open gate while Quit's main-thread steps run,
    /// before `stopAtQuit(in:)` ends the session. Quit's stop releases what
    /// the build created.
    func closeLevelGateAtQuit() {
        sessionLock.lock()
        sessionID = UUID()
        let gate = levelGate
        sessionLock.unlock()
        gate?.close()
    }

    /// Quit only. Stops and destroys the tap, the aggregate device and the
    /// IOProc on the lifecycle queue, whatever the quiet window, and counts
    /// it in `stops`, reporting progress before each HAL call. Nothing is
    /// delivered to the main thread, which is waiting.
    func stopAtQuit(in stops: LifecycleStopGroup) {
        invalidateSession()
        stops.run(label: Self.quitStopLabel, on: lifecycleQueue) { [self] progress in
            stopResources(holdToken: nil, reason: HALLifecycleLog.quitReason, progress: progress)
        }
    }

    /// Runs only on `lifecycleQueue`. Releases the listeners, then the
    /// IOProc, the aggregate device and the tap, one HAL call at a time, in
    /// `LifecycleTeardown`'s order: the stop, the IOProc, the aggregate
    /// device, then the tap. After a start that did not return `noErr`,
    /// whether the aggregate device reports the IO running is read first, and
    /// running IO is stopped before its IOProc is destroyed. Each ID is
    /// cleared only after its own call has returned, whatever status it
    /// returned.
    ///
    /// `holdToken` is the quiet window's generation the release was issued
    /// in, compared immediately before the listener removal and before each
    /// lifecycle call. At a mismatch the release ends there and logs the call
    /// it held back as `interruption`. What remains stays for the next start
    /// or stop after the window, so an aggregate device is never destroyed
    /// while its IOProc exists, nor the tap while the aggregate device exists.
    ///
    /// - Parameters:
    ///   - holdToken: nil for a release the quiet window does not hold.
    ///   - interruption: `interrupt-stop` for a stop, `interrupt` for the
    ///     release a start makes of what it replaces or built.
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
        closeLevelGate()
        if ioProcID == nil || aggregateDeviceID == kAudioObjectUnknown {
            // An IOProc is only ever created on the aggregate device.
            ioProcID = nil
            ioProcState = .none
        }
        if let listenerBlock {
            guard holdGeneration.allows(holdToken) else {
                HALLifecycleLog.record(
                    ioProcID == nil ? .systemOutputAggregate : .systemOutputIOProc,
                    interruption,
                    id: aggregateDeviceID,
                    transport: tappedTransport,
                    generation: holdToken,
                    output: loggedOutput,
                    aggregateUID: loggedAggregateUID,
                    tapUID: loggedTapUID
                )
                return .interrupted
            }
            progress?.report(.removeListeners)
            for listener in listeners {
                halCalls.removePropertyListener(
                    deviceID: listener.deviceID,
                    address: listener.address,
                    queue: listenerQueue,
                    block: listenerBlock
                )
            }
            self.listenerBlock = nil
            listeners = []
        }
        var teardown = LifecycleTeardown(
            ioProc: ioProcState,
            holdsAggregate: aggregateDeviceID != kAudioObjectUnknown,
            holdsTap: tapID != kAudioObjectUnknown
        )
        while let step = teardown.nextStep {
            guard !step.isLifecycleCall || holdGeneration.allows(holdToken) else {
                switch step {
                case .readIsRunning, .stop, .destroyIOProc:
                    HALLifecycleLog.record(.systemOutputIOProc, interruption, id: aggregateDeviceID, transport: tappedTransport, generation: holdToken, output: loggedOutput, aggregateUID: loggedAggregateUID, tapUID: loggedTapUID)
                case .destroyAggregate:
                    HALLifecycleLog.record(.systemOutputAggregate, interruption, id: aggregateDeviceID, transport: tappedTransport, generation: holdToken, output: loggedOutput, aggregateUID: loggedAggregateUID, tapUID: loggedTapUID)
                case .destroyProcessTap:
                    HALLifecycleLog.record(.systemOutputTap, interruption, id: tapID, transport: tappedTransport, generation: holdToken, output: loggedOutput, aggregateUID: loggedAggregateUID, tapUID: loggedTapUID)
                }
                return .interrupted
            }
            progress?.report(LifecycleStopGroup.Phase(step))
            switch step {
            case .readIsRunning:
                let (status, value) = halCalls.isRunning(aggregateDeviceID)
                teardown.noteIsRunning(status == noErr && value != 0)
            case .stop:
                if let ioProcID {
                    let stopReason = teardown.stopFollowsUnconfirmedStart
                        ? reason ?? HALLifecycleLog.unconfirmedStartReason
                        : reason
                    HALLifecycleLog.begin(
                        .systemOutputIOProc,
                        .stop,
                        id: aggregateDeviceID,
                        transport: tappedTransport,
                        generation: holdToken,
                        reason: stopReason,
                        output: loggedOutput,
                        aggregateUID: loggedAggregateUID,
                        tapUID: loggedTapUID
                    )
                    let stopStatus = halCalls.stop(deviceID: aggregateDeviceID, ioProcID: ioProcID)
                    HALLifecycleLog.record(
                        .systemOutputIOProc,
                        .stop,
                        id: aggregateDeviceID,
                        transport: tappedTransport,
                        status: stopStatus,
                        generation: holdToken,
                        reason: stopReason,
                        output: loggedOutput,
                        aggregateUID: loggedAggregateUID,
                        tapUID: loggedTapUID
                    )
                }
                teardown.complete(.stop)
            case .destroyIOProc:
                if let ioProcID {
                    HALLifecycleLog.begin(
                        .systemOutputIOProc,
                        .destroy,
                        id: aggregateDeviceID,
                        transport: tappedTransport,
                        generation: holdToken,
                        reason: reason,
                        output: loggedOutput,
                        aggregateUID: loggedAggregateUID,
                        tapUID: loggedTapUID
                    )
                    let destroyStatus = halCalls.destroyIOProc(deviceID: aggregateDeviceID, ioProcID: ioProcID)
                    HALLifecycleLog.record(
                        .systemOutputIOProc,
                        .destroy,
                        id: aggregateDeviceID,
                        transport: tappedTransport,
                        status: destroyStatus,
                        generation: holdToken,
                        reason: reason,
                        output: loggedOutput,
                        aggregateUID: loggedAggregateUID,
                        tapUID: loggedTapUID
                    )
                }
                ioProcID = nil
                teardown.complete(.destroyIOProc)
            case .destroyAggregate:
                HALLifecycleLog.begin(
                    .systemOutputAggregate,
                    .destroy,
                    id: aggregateDeviceID,
                    transport: tappedTransport,
                    generation: holdToken,
                    reason: reason,
                    output: loggedOutput,
                    aggregateUID: loggedAggregateUID,
                    tapUID: loggedTapUID
                )
                let destroyStatus = halCalls.destroyAggregate(aggregateDeviceID)
                HALLifecycleLog.record(
                    .systemOutputAggregate,
                    .destroy,
                    id: aggregateDeviceID,
                    transport: tappedTransport,
                    status: destroyStatus,
                    generation: holdToken,
                    reason: reason,
                    output: loggedOutput,
                    aggregateUID: loggedAggregateUID,
                    tapUID: loggedTapUID
                )
                aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
                loggedAggregateUID = nil
                teardown.complete(.destroyAggregate)
            case .destroyProcessTap:
                if #available(macOS 14.2, *) {
                    HALLifecycleLog.begin(
                        .systemOutputTap,
                        .destroy,
                        id: tapID,
                        transport: tappedTransport,
                        generation: holdToken,
                        reason: reason,
                        output: loggedOutput,
                        aggregateUID: loggedAggregateUID,
                        tapUID: loggedTapUID
                    )
                    let destroyStatus = halCalls.destroyProcessTap(tapID)
                    HALLifecycleLog.record(
                        .systemOutputTap,
                        .destroy,
                        id: tapID,
                        transport: tappedTransport,
                        status: destroyStatus,
                        generation: holdToken,
                        reason: reason,
                        output: loggedOutput,
                        aggregateUID: loggedAggregateUID,
                        tapUID: loggedTapUID
                    )
                }
                tapID = AudioObjectID(kAudioObjectUnknown)
                loggedTapUID = nil
                teardown.complete(.destroyProcessTap)
            }
            ioProcState = teardown.ioProc
        }
        return .released
    }

    @available(macOS 14.2, *)
    private func configureAndStart(
        deviceUID: String,
        excludingCurrentProcess: Bool,
        sessionID: UUID,
        holdToken: UInt64
    ) throws {
        let excludedProcesses: [AudioObjectID]
        if excludingCurrentProcess {
            excludedProcesses = [try currentAudioProcessObjectID()]
        } else {
            excludedProcesses = []
        }

        let tapDescription = CATapDescription(
            excludingProcesses: excludedProcesses,
            deviceUID: deviceUID,
            stream: 0
        )
        tapDescription.name = "Audio Level Bar System Output Meter"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        try checkNotInterrupted(
            holdToken,
            before: .systemOutputTap,
            id: AudioObjectID(kAudioObjectUnknown)
        )
        // The tap's UID is the UUID of its description, generated here, so
        // the begin line can already name it.
        loggedTapUID = tapDescription.uuid.uuidString
        HALLifecycleLog.begin(
            .systemOutputTap,
            .create,
            id: AudioObjectID(kAudioObjectUnknown),
            transport: tappedTransport,
            generation: holdToken,
            output: loggedOutput,
            aggregateUID: loggedAggregateUID,
            tapUID: loggedTapUID
        )
        let (tapStatus, newTapID) = halCalls.createProcessTap(tapDescription)
        HALLifecycleLog.record(
            .systemOutputTap,
            .create,
            id: newTapID,
            transport: tappedTransport,
            status: tapStatus,
            generation: holdToken,
            output: loggedOutput,
            aggregateUID: loggedAggregateUID,
            tapUID: loggedTapUID
        )
        if tapStatus != noErr {
            // No tap exists under that UID; nothing after names it.
            loggedTapUID = nil
        }
        try check(tapStatus, operation: localized("Creating the system audio tap"))
        tapID = newTapID

        let tapUID = try readTapUID(tapID)
        // The lines after the create name the tap by the UID the HAL reports
        // for it, the one the aggregate device lists.
        loggedTapUID = tapUID
        let format = try readTapFormat(tapID)
        guard
            format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mBitsPerChannel == 32 || format.mBitsPerChannel == 64
        else {
            throw SystemOutputMeterError.unsupportedFormat
        }
        let aggregateUID = "io.github.yuhkis.audio-level-bar.tap.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Level Bar System Output Meter",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]
        try checkNotInterrupted(
            holdToken,
            before: .systemOutputAggregate,
            id: AudioObjectID(kAudioObjectUnknown)
        )
        loggedAggregateUID = aggregateUID
        HALLifecycleLog.begin(
            .systemOutputAggregate,
            .create,
            id: AudioObjectID(kAudioObjectUnknown),
            transport: tappedTransport,
            generation: holdToken,
            output: loggedOutput,
            aggregateUID: loggedAggregateUID,
            tapUID: loggedTapUID
        )
        let (aggregateStatus, newAggregateDeviceID) = halCalls.createAggregate(
            aggregateDescription as CFDictionary
        )
        HALLifecycleLog.record(
            .systemOutputAggregate,
            .create,
            id: newAggregateDeviceID,
            transport: tappedTransport,
            status: aggregateStatus,
            generation: holdToken,
            output: loggedOutput,
            aggregateUID: loggedAggregateUID,
            tapUID: loggedTapUID
        )
        if aggregateStatus != noErr {
            // No aggregate device exists under that UID; the tap's destroy
            // and the next start's lines must not name it.
            loggedAggregateUID = nil
        }
        try check(
            aggregateStatus,
            operation: localized("Creating the system audio aggregate device")
        )
        aggregateDeviceID = newAggregateDeviceID

        let gate = SystemOutputLevelGate()
        replaceLevelGate(with: gate)
        addInvalidationListeners(gate: gate, sessionID: sessionID, holdToken: holdToken)

        try checkNotInterrupted(
            holdToken,
            before: .systemOutputIOProc,
            id: aggregateDeviceID
        )
        let emissionState = self.emissionState
        processingQueue.async {
            emissionState.lastEmissionNanoseconds = 0
        }
        HALLifecycleLog.begin(
            .systemOutputIOProc,
            .create,
            id: aggregateDeviceID,
            transport: tappedTransport,
            generation: holdToken,
            output: loggedOutput,
            aggregateUID: loggedAggregateUID,
            tapUID: loggedTapUID
        )
        let (ioProcStatus, newIOProcID) = halCalls.createIOProc(
            deviceID: aggregateDeviceID,
            queue: processingQueue
        ) { [weak self, gate] _, inputData, _, _, _ in
            guard gate.isOpen else {
                return
            }
            self?.consume(
                inputData,
                sampleBitWidth: format.mBitsPerChannel,
                sessionID: sessionID,
                emissionState: emissionState
            )
        }
        HALLifecycleLog.record(
            .systemOutputIOProc,
            .create,
            id: aggregateDeviceID,
            transport: tappedTransport,
            status: ioProcStatus,
            generation: holdToken,
            output: loggedOutput,
            aggregateUID: loggedAggregateUID,
            tapUID: loggedTapUID
        )
        try check(
            ioProcStatus,
            operation: localized("Creating the system audio IOProc")
        )
        guard let newIOProcID else {
            throw SystemOutputMeterError.operationFailed(
                localized("Creating the system audio IOProc"),
                kAudioHardwareUnspecifiedError
            )
        }
        ioProcID = newIOProcID
        ioProcState = .created

        guard isCurrentSession(sessionID) else {
            throw LifecycleCancellation.superseded
        }
        try checkNotInterrupted(
            holdToken,
            before: .systemOutputIOProc,
            id: aggregateDeviceID
        )

        ioProcState = .startUnconfirmed
        HALLifecycleLog.begin(
            .systemOutputIOProc,
            .start,
            id: aggregateDeviceID,
            transport: tappedTransport,
            generation: holdToken,
            output: loggedOutput,
            aggregateUID: loggedAggregateUID,
            tapUID: loggedTapUID
        )
        let startStatus = halCalls.start(deviceID: aggregateDeviceID, ioProcID: newIOProcID)
        HALLifecycleLog.record(
            .systemOutputIOProc,
            .start,
            id: aggregateDeviceID,
            transport: tappedTransport,
            status: startStatus,
            generation: holdToken,
            output: loggedOutput,
            aggregateUID: loggedAggregateUID,
            tapUID: loggedTapUID
        )
        try check(
            startStatus,
            operation: localized("Starting system audio recording")
        )
        ioProcState = .started
    }

    /// Runs only on `lifecycleQueue`, right after the aggregate device was
    /// created. Adds the listeners that only close `gate` and tell the owner:
    /// never a HAL call, a stop or a rebuild. A listener that cannot be added
    /// is logged and skipped rather than failing the start; the owner's
    /// silence check still notices levels that stop arriving.
    ///
    /// Every notification while this build is the current session advances
    /// the quiet window's generation at once, on the listener queue, so a
    /// start or stop already on its way stops at its next check. The first
    /// closes the gate and reports the invalidation; each later one, from the
    /// same reconfiguration such as a Bluetooth output switching profile and
    /// back, reports that the change is still under way, so the owner extends
    /// the window rather than rebuild 3 s after the first notification.
    private func addInvalidationListeners(
        gate: SystemOutputLevelGate,
        sessionID: UUID,
        holdToken: UInt64
    ) {
        let aggregate = aggregateDeviceID
        let transport = tappedTransport
        let output = loggedOutput
        let aggregateUID = loggedAggregateUID
        let tapUID = loggedTapUID
        let holdGeneration = holdGeneration
        let listener: AudioObjectPropertyListenerBlock = { [weak self, gate] _, _ in
            // A build that was released, replaced or forgotten reports
            // nothing, and advances nothing.
            guard let self, isCurrentSession(sessionID) else {
                return
            }
            holdGeneration.advance()
            guard gate.close() else {
                reportChangeObserved(sessionID: sessionID)
                return
            }
            HALLifecycleLog.record(
                .systemOutputAggregate,
                .invalidate,
                id: aggregate,
                transport: transport,
                generation: holdGeneration.current,
                output: output,
                aggregateUID: aggregateUID,
                tapUID: tapUID
            )
            reportInvalidated(sessionID: sessionID)
        }

        var wanted = Self.aggregateInvalidatingProperties.map { (deviceID: aggregate, address: $0) }
        if let output {
            wanted += Self.outputInvalidatingProperties.map { (deviceID: output, address: $0) }
        }
        var added: [(deviceID: AudioObjectID, address: AudioObjectPropertyAddress)] = []
        for candidate in wanted {
            let status = halCalls.addPropertyListener(
                deviceID: candidate.deviceID,
                address: candidate.address,
                queue: listenerQueue,
                block: listener
            )
            if status == noErr {
                added.append(candidate)
            } else {
                HALLifecycleLog.record(
                    .systemOutputListener,
                    .create,
                    id: candidate.deviceID,
                    transport: transport,
                    status: status,
                    generation: holdToken,
                    output: output
                )
            }
        }
        listenerBlock = listener
        listeners = added
    }

    private func consume(
        _ inputData: UnsafePointer<AudioBufferList>,
        sampleBitWidth: UInt32,
        sessionID: UUID,
        emissionState: EmissionState
    ) {
        // Buffers arrive about every 10 ms and only one in every emission
        // interval is reported. Discard the rest before summing them: the
        // reported values are unchanged, and the per-sample loop stops running
        // for buffers nothing will ever read.
        let now = DispatchTime.now().uptimeNanoseconds
        guard
            now - emissionState.lastEmissionNanoseconds
                >= emissionState.intervalNanoseconds
        else {
            return
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        var sumOfSquares: Double = 0
        var peak: Double = 0
        var sampleCount = 0

        for buffer in bufferList {
            guard let data = buffer.mData else {
                continue
            }

            if sampleBitWidth == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                let samples = data.assumingMemoryBound(to: Float32.self)
                for index in 0..<count {
                    let amplitude = abs(Double(samples[index]))
                    sumOfSquares += amplitude * amplitude
                    peak = max(peak, amplitude)
                }
                sampleCount += count
            } else if sampleBitWidth == 64 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float64>.size
                let samples = data.assumingMemoryBound(to: Float64.self)
                for index in 0..<count {
                    let amplitude = abs(samples[index])
                    sumOfSquares += amplitude * amplitude
                    peak = max(peak, amplitude)
                }
                sampleCount += count
            }
        }

        // An empty buffer must not start the next interval.
        guard sampleCount > 0 else {
            return
        }
        emissionState.lastEmissionNanoseconds = now

        let rms = sqrt(sumOfSquares / Double(sampleCount))
        let rmsDecibels = MeterScale.decibels(amplitude: Float(rms))
        let peakDecibels = MeterScale.decibels(amplitude: Float(peak))
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(sessionID) == true else {
                return
            }
            self?.onLevel?(rmsDecibels, peakDecibels)
        }
    }

    @available(macOS 14.2, *)
    private func readTapUID(_ tapID: AudioObjectID) throws -> String {
        let (status, uid) = halCalls.tapUID(tapID)
        try check(status, operation: localized("Reading the system audio tap UID"))
        guard let uid else {
            throw SystemOutputMeterError.operationFailed(
                localized("Reading the system audio tap UID"),
                kAudioHardwareUnspecifiedError
            )
        }
        return uid
    }

    @available(macOS 14.2, *)
    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        let (status, format) = halCalls.tapFormat(tapID)
        try check(status, operation: localized("Reading the system audio tap format"))
        return format
    }

    /// Throws `.interrupted` when a quiet window armed after this start was
    /// issued, and logs the call it held back.
    private func checkNotInterrupted(
        _ holdToken: UInt64,
        before object: HALLifecycleLog.Object,
        id: AudioObjectID
    ) throws {
        guard holdGeneration.isCurrent(holdToken) else {
            HALLifecycleLog.record(object, .interrupt, id: id, transport: tappedTransport, generation: holdToken, output: loggedOutput, aggregateUID: loggedAggregateUID, tapUID: loggedTapUID)
            throw LifecycleCancellation.interrupted
        }
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status != kAudioDevicePermissionsError else {
            throw SystemOutputMeterError.permissionDenied
        }
        guard status == noErr else {
            throw SystemOutputMeterError.operationFailed(operation, status)
        }
    }

    private func currentAudioProcessObjectID() throws -> AudioObjectID {
        let (status, processObjectID) = halCalls.processObjectID(for: getpid())
        try check(
            status,
            operation: localized("Reading the Audio Level Bar audio process object")
        )
        guard processObjectID != kAudioObjectUnknown else {
            throw SystemOutputMeterError.audioProcessUnavailable
        }
        return processObjectID
    }

    private func replaceLevelGate(with gate: SystemOutputLevelGate) {
        sessionLock.lock()
        let previous = levelGate
        levelGate = gate
        sessionLock.unlock()
        previous?.close()
    }

    /// Any thread. Stops the current build's levels at the IO callback.
    private func closeLevelGate() {
        sessionLock.lock()
        let gate = levelGate
        sessionLock.unlock()
        gate?.close()
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

    private func reportInterrupted(sessionID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(sessionID) == true else {
                return
            }
            self?.onInterrupted?()
        }
    }

    private func reportOutputMoved(sessionID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(sessionID) == true else {
                return
            }
            self?.onOutputMoved?()
        }
    }

    private func reportInvalidated(sessionID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(sessionID) == true else {
                return
            }
            self?.onInvalidated?()
        }
    }

    private func reportChangeObserved(sessionID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(sessionID) == true else {
                return
            }
            self?.onChangeObserved?()
        }
    }

    private func reportStopInterrupted(sessionID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(sessionID) == true else {
                return
            }
            self?.onStopInterrupted?()
        }
    }

    private func report(
        _ error: SystemOutputMeterError,
        sessionID: UUID
    ) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(sessionID) == true else {
                return
            }
            self?.onError?(error)
        }
    }
}

/// Whether one build of the system playback meter still passes levels on.
/// Shared by the IOProc block, the listeners and the lifecycle queue; closed
/// by an invalidation, a release, a service restart, or Quit.
private final class SystemOutputLevelGate: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: true)

    var isOpen: Bool {
        state.withLock { $0 }
    }

    /// Stops passing levels on. True when this call closed an open gate.
    @discardableResult
    func close() -> Bool {
        state.withLock { isOpen in
            defer { isOpen = false }
            return isOpen
        }
    }
}
