import AudioLevelBarCore
import CoreAudio
import Foundation
import os

/// One log line immediately before and one immediately after each HAL
/// resource lifecycle call, and one per quiet-window hold or release.
///
/// A hardware check matches these lines against coreaudiod's own log, so each
/// line carries what that matching needs and nothing that identifies the
/// user's hardware: the object kind, the AudioObjectID, the transport class,
/// the OSStatus, and the quiet window's generation. The process taps and
/// aggregate devices this app creates also carry their UIDs
/// (`aggregate-uid=`, `tap-uid=`), which the app generates in its own
/// namespace. coreaudiod prints the aggregate device's UID in
/// `IOWorkLoopInit`; whether it prints the tap's in the same form is not yet
/// confirmed on hardware. A physical device's `id=` is matched to its UID
/// through the IDs `--diagnose` lists. Never a device name, and never the UID
/// of a device the app did not create. Every field is logged public, because
/// a redacted ID cannot be matched.
///
/// A create, start, stop or destroy, and the `prepare()` of a processed
/// microphone `AVAudioEngine`, writes `<object> <operation>-begin`
/// immediately before the call, after any generation check has passed, and
/// `<object> <operation> ... status=` once it has returned. A call that never
/// returns leaves its begin line alone. Both lines carry `gen=`: the quiet
/// window's generation the work was issued in, or `-` for work the window
/// does not hold (Quit, the stop of an IOProc whose aggregate device gained a
/// Bluetooth sub-device, and the stop of Apple voice processing's engines
/// before the app's own picker writes a default device that may involve
/// Bluetooth) and for the `--reclaim-taps` command, which
/// runs outside the app. A line that belongs to no issued call, such
/// as a `forget`, an `invalidate` or a `stall`, carries the generation current
/// when it was written.
///
/// Stream it with:
///
///     /usr/bin/log stream --level debug \
///         --predicate 'subsystem == "io.github.yuhkis.audio-level-bar" AND category == "hal-lifecycle"'
enum HALLifecycleLog {
    enum Object: String {
        case microphoneIOProc = "microphone-ioproc"
        case microphoneListener = "microphone-listener"
        /// The system playback meter's process tap. Its lines, and those of
        /// the meter's aggregate device and IOProc, end with
        /// `output=<tapped output ID>` once the output has been read.
        case systemOutputTap = "system-output-tap"
        /// `invalidate`: a listener on the aggregate device or on the tapped
        /// output reported it dead or reconfigured. Nothing is stopped for it
        /// here; the owner rebuilds after the quiet window.
        case systemOutputAggregate = "system-output-aggregate"
        case systemOutputIOProc = "system-output-ioproc"
        /// A listener of the system playback meter's. Logged only when it
        /// could not be added; the ID is the device it was to be added on.
        case systemOutputListener = "system-output-listener"
        /// The published process tap, and the published aggregate device.
        /// Every line of a publication carries the generation the publication
        /// was issued in. `interrupt`, on either or on the probe IOProc: a
        /// listener advanced the generation while the publication was on its
        /// way on the main thread, and it stopped before the call its
        /// `reason=before-<operation>` names. Nothing more is issued for it
        /// inside the window, no rollback either; the owner's first
        /// evaluation after the window rolls back what it kept, and an
        /// `interrupt-stop` there is that rollback held back in turn.
        case processedMicrophoneTap = "processed-microphone-tap"
        case processedMicrophoneAggregate = "processed-microphone-aggregate"
        /// The IOProc on the published aggregate device that confirms the
        /// system audio recording permission. After an `interrupt` with
        /// `reason=before-stop` its IO keeps running until the release.
        case processedMicrophoneProbeIOProc = "processed-microphone-probe-ioproc"
        case processedMicrophoneCaptureIOProc = "processed-microphone-capture-ioproc"
        case processedMicrophoneCaptureListener = "processed-microphone-capture-listener"
        /// The processed microphone's publisher `AVAudioEngine`. `start`,
        /// `stop` and `invalidate` carry the output device its node is bound
        /// to, read back from the node's audio unit. `refuse`: the read made
        /// immediately before it is built found no output it may be bound
        /// to, and nothing was built; the ID and transport are the default
        /// output's.
        case processedMicrophonePublisherEngine = "processed-microphone-publisher-engine"
        /// The processed microphone's Apple voice processing capture
        /// `AVAudioEngine`. Its lines carry the input device its unit is bound
        /// to as `id=`, and the device its output element is bound to as
        /// `output=`, both read back from the unit; `transport=` describes
        /// `id=` alone.
        case processedMicrophoneVoiceProcessingEngine = "processed-microphone-voice-processing-engine"
        /// A process tap an earlier run left behind, destroyed by the launch
        /// cleanup (`reason=launch`) or the `--reclaim-taps` command
        /// (`reason=reclaim-command`).
        case reclaimedTap = "reclaimed-tap"
        /// The processed microphone refusing its source; the ID is the default
        /// input's, for Apple voice processing refused by the output the
        /// default output's, and for Apple voice processing refused because a
        /// Bluetooth audio device is connected, the lowest-numbered such
        /// device's (`transport=unread` when neither picker lists it). Also
        /// Apple voice processing not starting because the defaults it re-read
        /// immediately before starting had moved or involved Bluetooth, or the
        /// output devices it re-read listed a Bluetooth one, whose ID the line
        /// then carries (`refuse`), or because a quiet window armed first
        /// (`interrupt`). Its start also re-reads both defaults by ID on the
        /// main thread immediately before and after its engine starts; a
        /// `refuse` with `transport=moved` names the device a default moved
        /// to. An `interrupt` there, before the publisher is built, before the
        /// tap is installed, or before the engine starts, leaves what the
        /// start built until the release after the window.
        case processedMicrophoneSource = "processed-microphone-source"
        /// A listener on the HAL system object for default-device changes,
        /// device-list changes or a coreaudiod restart. Logged only when it
        /// could not be added; the ID is the system object's.
        case systemListener = "system-listener"
    }

    enum Operation: String {
        case create
        /// A processed microphone `AVAudioEngine`'s `prepare()`, which
        /// allocates its I/O unit's resources and can create the unit's
        /// IOProc on the bound device. The status is `noErr`, or
        /// `kAudioHardwareUnspecifiedError` when the call raised.
        case prepare
        case start
        case stop
        case destroy
        /// Written immediately before the create call, with no status. For a
        /// process tap or an aggregate device the ID is 0: the call assigns
        /// it.
        case createBegin = "create-begin"
        /// Written immediately before an engine's `prepare()`.
        case prepareBegin = "prepare-begin"
        /// Written immediately before `AudioDeviceStart`, or an engine start.
        case startBegin = "start-begin"
        /// Written immediately before `AudioDeviceStop`, or an engine stop.
        case stopBegin = "stop-begin"
        /// Written immediately before the destroy call.
        case destroyBegin = "destroy-begin"
        /// The device was not opened; see the transport class.
        case refuse
        /// The device is opened although Bluetooth could not be ruled out.
        case openUnverified = "open-unverified"
        /// A quiet window armed after the start was issued, and the start was
        /// abandoned before this call. What it created stays until the next
        /// start or stop, after the window. The line can follow the `stop`
        /// or `destroy` lines of the release a start makes first; only the
        /// steps after those lines stay held.
        case interrupt
        /// A stop issued before a quiet window armed, abandoned before this
        /// call. What it would have stopped stays, no longer reported, until
        /// the next start or stop after the window. The line can follow the
        /// `stop` or `destroy` lines of the same release: what those lines
        /// name is already stopped or destroyed, and only the steps after
        /// them stay. The processed microphone's engines write it, one line
        /// for each engine, when the generation their stop was issued in is
        /// no longer current as the main thread is about to stop them:
        /// neither is stopped.
        case interruptStop = "interrupt-stop"
        /// A lifecycle call has not come back within `LifecycleCallWatch`'s
        /// 10 s timeout, the microphone meter's start timeout. It is written
        /// for a microphone meter start (`microphone-ioproc`), the meter's
        /// stop for a hand-off to the processed microphone
        /// (`microphone-ioproc`, `reason=hand-off`), a system playback meter
        /// start or stop (`system-output-tap`, id 0), and a processed
        /// microphone capture start or release
        /// (`processed-microphone-capture-ioproc`). Its queue is most likely
        /// waiting in an unresponsive coreaudiod; nothing further is issued
        /// to that queue until the call comes back.
        case stall
        /// coreaudiod restarted, and the object went with it. Its ID is
        /// dropped without a HAL call: it may name something else now.
        case forget
        /// The framework reported a configuration change under an
        /// `AVAudioEngine`, which it stops itself, or a listener reported the
        /// system playback meter's aggregate device or tapped output dead or
        /// reconfigured. Nothing is stopped or started for it here; the owner
        /// rebuilds after the quiet window. The ID is the device the engine
        /// is bound to now, or the meter's aggregate device.
        case invalidate
        /// Automatic rebuilds or retries stopped after repeated failures on
        /// one output, and nothing further is issued for them, neither a
        /// start nor a stop, until the user retries or the output device
        /// changes. Written once when that happens: for the system playback
        /// meter (`system-output-tap`, id 0, with `output=`) at
        /// `SystemOutputRecovery.maximumConsecutiveInvalidations`
        /// invalidations in a row, and for the processed microphone
        /// (`processed-microphone-publisher-engine`, the output's ID and its
        /// transport class as the poll shows it, or `unread`) at
        /// `PublisherOutputRetry.maximumConsecutiveFailures` unusable format
        /// reads in a row on that output.
        ///
        /// Also the processed microphone's IOProc capture
        /// (`processed-microphone-capture-ioproc`, the input's ID and its
        /// transport class as the poll shows it): the read made as the
        /// capture opened that input could not read its transport, or could
        /// not resolve an aggregate member the poll had resolved,
        /// `CaptureInputRetry.maximumConsecutiveFailures` times in a row. The
        /// processed microphone is then halted with Retry.
        ///
        /// Also the processed microphone's publication
        /// (`processed-microphone-aggregate`, id 0, with the fixed
        /// `aggregate-uid=`): a quiet window interrupted
        /// `PublicationInterruptions.maximumConsecutiveInterruptions`
        /// publications in a row. Written once, after the rollback of what
        /// the last of them kept, and nothing is published again until the
        /// user retries or switches the processed microphone off and on.
        ///
        /// Also the microphone meter (`microphone-ioproc`, the input's ID and
        /// its transport class as the poll shows it): its start on that input
        /// failed, or could not read the transport or resolve an aggregate
        /// member as it opened it, `MeterSession.maximumStartAttempts` times
        /// in a row. Each of those starts released what it created, so
        /// nothing is left open. The meter then shows its error with Retry,
        /// and no start follows until the user retries, the input changes,
        /// the processed microphone starts, or coreaudiod restarts.
        case giveUp = "give-up"

        /// The operation written immediately before this call, or nil for an
        /// operation that is not a HAL call.
        var begin: Operation? {
            switch self {
            case .create:
                return .createBegin
            case .prepare:
                return .prepareBegin
            case .start:
                return .startBegin
            case .stop:
                return .stopBegin
            case .destroy:
                return .destroyBegin
            default:
                return nil
            }
        }

        /// Whether this is written before a call, and so carries no status.
        var isBegin: Bool {
            switch self {
            case .createBegin, .prepareBegin, .startBegin, .stopBegin, .destroyBegin:
                return true
            default:
                return false
            }
        }
    }

    /// The `reason` on the stops and destroys Quit issues, which the quiet
    /// window does not hold.
    static let quitReason = "quit"

    /// The `reason` on the stop of Apple voice processing's capture and
    /// publisher engines that the app's own device picker issues before it
    /// writes a default device that may involve Bluetooth. The quiet window
    /// does not hold it: it comes before the change it is for.
    static let bluetoothSelectionReason = "bluetooth-selection"

    /// Whether a stop issued with `reason` is one the quiet window does not
    /// hold, so that its lines carry `gen=-`.
    static func isUnheldStopReason(_ reason: String?) -> Bool {
        reason == quitReason || reason == bluetoothSelectionReason
    }

    /// The `reason` on the stop of IO that reported running after an
    /// `AudioDeviceStart` that did not return `noErr`. It exempts nothing.
    static let unconfirmedStartReason = "failed-start"

    /// The `reason` on the `stall` of the microphone meter's stop for a
    /// hand-off to the processed microphone. It exempts nothing.
    static let handOffReason = "hand-off"

    /// The `reason` on the `interrupt` of a processed microphone start whose
    /// AVFAudio call raised an Objective-C exception. It exempts nothing.
    static let engineRaisedReason = "engine-raised"

    /// The `reason` on the `interrupt` of the processed microphone's
    /// publication, and on the `interrupt-stop` of the rollback of what an
    /// interrupted publication kept: the call that was held back, as
    /// `before-create`, `before-start`, `before-stop` or `before-destroy`. The
    /// probe IOProc's four calls share one object, so the word tells which of
    /// them did not happen: after `before-stop`, the probe's IO keeps running
    /// until the release. It exempts nothing.
    static func heldBackReason(_ operation: Operation) -> String {
        "before-\(operation.rawValue)"
    }

    private static let logger = Logger(
        subsystem: "io.github.yuhkis.audio-level-bar",
        category: "hal-lifecycle"
    )

    private static let observerLock = NSLock()
    private static var lineObserver: ((String) -> Void)?

    /// Tests only. Receives every line once it has been logged, on the thread
    /// that wrote it.
    static var observer: ((String) -> Void)? {
        get {
            observerLock.lock()
            defer { observerLock.unlock() }
            return lineObserver
        }
        set {
            observerLock.lock()
            lineObserver = newValue
            observerLock.unlock()
        }
    }

    /// Writes the begin line of the call `operation` names, immediately
    /// before that call. The parameters are those of the line the call writes
    /// once it returns; see `record`.
    static func begin(
        _ object: Object,
        _ operation: Operation,
        id: AudioObjectID,
        transport: String = "-",
        generation: UInt64?,
        reason: String? = nil,
        output: AudioObjectID? = nil,
        aggregateUID: String? = nil,
        tapUID: String? = nil
    ) {
        assert(operation.begin != nil, "\(operation) is not a HAL call")
        record(
            object,
            operation.begin ?? operation,
            id: id,
            transport: transport,
            generation: generation,
            reason: reason,
            output: output,
            aggregateUID: aggregateUID,
            tapUID: tapUID
        )
    }

    /// - Parameter generation: The quiet window's generation the work was
    ///   issued in, or the one current when a line that belongs to no issued
    ///   call is written; nil (`gen=-`) for work the window does not hold.
    /// - Parameter reason: A fixed word appended as `reason=<word>` to a stop
    ///   or destroy that is exempt from the quiet window, such as `quit`, or
    ///   that names the cleanup or release it belongs to, such as `launch` or
    ///   `failed-start`, or to the `interrupt` of a publication, naming the
    ///   call that was held back (`heldBackReason`). Never data read from a
    ///   device.
    /// - Parameter output: The output device a system playback meter line
    ///   belongs to, or the device a voice-processing engine's output element
    ///   is bound to, appended as `output=<id>`.
    /// - Parameter aggregateUID: The UID of the aggregate device this app
    ///   created that the line is about, or that the IOProc runs on, appended
    ///   as `aggregate-uid=`. Never the UID of a device the app did not
    ///   create.
    /// - Parameter tapUID: The UID of the process tap this app created that
    ///   the line is about, or that feeds the line's aggregate device,
    ///   appended last as `tap-uid=`.
    static func record(
        _ object: Object,
        _ operation: Operation,
        id: AudioObjectID,
        transport: String = "-",
        status: OSStatus = noErr,
        generation: UInt64?,
        reason: String? = nil,
        output: AudioObjectID? = nil,
        aggregateUID: String? = nil,
        tapUID: String? = nil
    ) {
        write(
            line(
                object,
                operation,
                id: id,
                transport: transport,
                status: status,
                generation: generation,
                reason: reason,
                output: output,
                aggregateUID: aggregateUID,
                tapUID: tapUID
            )
        )
    }

    /// The text of a lifecycle line. A begin operation carries no status.
    static func line(
        _ object: Object,
        _ operation: Operation,
        id: AudioObjectID,
        transport: String = "-",
        status: OSStatus = noErr,
        generation: UInt64?,
        reason: String? = nil,
        output: AudioObjectID? = nil,
        aggregateUID: String? = nil,
        tapUID: String? = nil
    ) -> String {
        var text = "\(object.rawValue) \(operation.rawValue) id=\(id) transport=\(transport)"
        if !operation.isBegin {
            text += " status=\(status)"
        }
        text += " gen=\(generationField(generation))"
        if let reason {
            text += " reason=\(reason)"
        }
        if let output {
            text += " output=\(output)"
        }
        if let aggregateUID {
            text += " aggregate-uid=\(aggregateUID)"
        }
        if let tapUID {
            text += " tap-uid=\(tapUID)"
        }
        return text
    }

    /// `gen=` as written: the generation, or `-` for work the quiet window
    /// does not hold.
    static func generationField(_ generation: UInt64?) -> String {
        generation.map(String.init) ?? "-"
    }

    /// Quit arrived while the quiet window held, so its teardown waits
    /// `seconds`: until the window's end, and never more than
    /// `QuitPlan.deferralMaximum` after the request. The menu bar item is
    /// already gone. The `reason=quit` lines follow once the deferral ends.
    static func quitDeferred(releaseIn seconds: TimeInterval) {
        write("quit-deferred release-in=\(String(format: "%.2f", seconds)) gen=-")
    }

    /// Quit waited for the meters and the capture to stop on their lifecycle
    /// queues. `completed=false` when the wait gave up, no stop having
    /// finished a HAL call within the idle bound, or at the ceiling; the
    /// process exits anyway. `pending` names each unfinished queue and the
    /// phase it was in (`<queue>:<phase>`, comma-separated), and `waited` the
    /// seconds the wait took.
    static func quitStops(_ outcome: LifecycleStopGroup.Outcome) {
        let pending = outcome.pendingDescription
        let waited = String(format: "%.2f", outcome.waited)
        write(
            "quit lifecycle-stops completed=\(outcome.completed) pending=\(pending) waited=\(waited) gen=-"
        )
    }

    /// The quiet window started holding, or was re-armed. `reason` is a fixed
    /// word such as `default-input`, never data read from a device.
    /// `generation` is the quiet window's generation after the hold: a start
    /// or stop issued with an earlier one is abandoned before its next HAL
    /// call, and one issued with this one is not.
    static func quietWindowHold(
        reason: String,
        releaseIn seconds: TimeInterval,
        generation: UInt64
    ) {
        let releaseIn = String(format: "%.2f", seconds)
        write("quiet-window hold reason=\(reason) release-in=\(releaseIn) gen=\(generation)")
    }

    /// A listener advanced the quiet window's generation on its own queue,
    /// before the main thread armed the window. `source` is the reason the
    /// main thread arms it with, a fixed word. The hold line that follows
    /// carries a generation one higher, and work lines written in between can
    /// carry this one.
    static func quietWindowAdvance(source: String, generation: UInt64) {
        write("quiet-window advance source=\(source) gen=\(generation)")
    }

    /// An evaluation released the quiet window.
    ///
    /// - Parameters:
    ///   - admission: `full`, or `stops-only` when the release may issue
    ///     stops, destroys and owed teardowns but no create or start.
    ///   - generation: The generation the release's work carries.
    ///   - snapshotAge: Seconds since the newest applied poll was issued.
    ///   - writesOutstanding: Default-device writes not yet completed.
    ///   - pollInFlight: Whether a poll had not returned yet.
    static func quietWindowRelease(
        _ admission: LifecycleQuietWindow.Admission,
        generation: UInt64,
        snapshotAge: TimeInterval?,
        writesOutstanding: Int,
        pollInFlight: Bool
    ) {
        let mode: String
        switch admission {
        case .full:
            mode = "full"
        case .stopsOnly:
            mode = "stops-only"
        case .hold:
            mode = "hold"
        }
        let age = snapshotAge.map { String(format: "%.2f", $0) } ?? "-"
        write(
            "quiet-window release mode=\(mode) gen=\(generation) snapshot-age=\(age) writes-outstanding=\(writesOutstanding) poll-in-flight=\(pollInFlight)"
        )
    }

    /// A control write the HAL worker made.
    enum ControlWrite: String {
        case defaultDevice = "default"
        case volume
        case mute
    }

    /// The periodic poll dropped a tick while the poll in flight had been
    /// issued `issuedAgo` seconds before, more than
    /// `HALPollWatch.slowAfter`. Written once per poll.
    static func pollSlow(issuedAgo: TimeInterval, generation: UInt64) {
        write("hal-poll slow issued-ago=\(seconds(issuedAgo)) gen=\(generation)")
    }

    /// A poll that was noted slow, or took longer than
    /// `HALPollWatch.slowAfter`, returned after `elapsed` seconds. Written
    /// immediately before its result is applied.
    static func pollRecovered(elapsed: TimeInterval, generation: UInt64) {
        write("hal-poll recovered elapsed=\(seconds(elapsed)) gen=\(generation)")
    }

    /// A default-device, volume or mute write finished on the HAL worker's
    /// queue.
    ///
    /// - Parameters:
    ///   - id: The device written: the device made the default, or the
    ///     device whose volume or mute was set.
    ///   - transport: The device's transport class as the worker had already
    ///     read it, or `unread`.
    ///   - status: The first status other than `noErr` among the writes, or
    ///     `noErr`.
    ///   - queued: Seconds the write waited on the queue.
    ///   - elapsed: Seconds the write itself took.
    static func controlWrite(
        _ kind: ControlWrite,
        id: AudioObjectID,
        direction: String,
        transport: String,
        status: OSStatus,
        queued: TimeInterval,
        elapsed: TimeInterval,
        generation: UInt64
    ) {
        write(
            "control-write \(kind.rawValue) id=\(id) direction=\(direction) transport=\(transport) status=\(status) queued=\(seconds(queued)) elapsed=\(seconds(elapsed)) gen=\(generation)"
        )
    }

    /// The app's own picker did not take a pick of a device that may involve
    /// Bluetooth, because Apple voice processing was engaged while a change
    /// could be under way: neither its stop nor the write was issued.
    ///
    /// - Parameters:
    ///   - id: The picked device.
    ///   - direction: `input` or `output`.
    ///   - transport: The picked device's class as its list shows it,
    ///     `unread`, or `-` for a device the list does not show.
    ///   - generation: The generation current at the pick.
    static func pickerRefused(id: AudioObjectID, direction: String, transport: String, generation: UInt64) {
        write("picker refuse id=\(id) direction=\(direction) transport=\(transport) gen=\(generation)")
    }

    /// A change of the system's power state.
    enum PowerEvent: String {
        case willSleep = "will-sleep"
        case didWake = "did-wake"
    }

    /// The system is about to sleep, or has woken. `generation` is the one
    /// current when the notification arrived.
    static func power(_ event: PowerEvent, generation: UInt64) {
        write("power \(event.rawValue) gen=\(generation)")
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }

    /// Logs `text` with every field public: each line is built only from
    /// object kinds, IDs, transport classes, statuses, generations, fixed
    /// words and durations.
    private static func write(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        observer?(text)
    }
}
