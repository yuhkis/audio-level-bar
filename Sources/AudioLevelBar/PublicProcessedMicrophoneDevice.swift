import AudioLevelBarCore
import CoreAudio
import Darwin
import Foundation

struct PublicProcessedMicrophoneCleanupFailure: Equatable {
    let operation: String
    let status: OSStatus
}

enum PublicProcessedMicrophoneDeviceError: LocalizedError {
    case unsupportedOS
    case audioProcessUnavailable(pid: pid_t)
    case permissionDenied(operation: String)
    case audioServiceUnavailable(operation: String, status: OSStatus)
    case missingPropertyValue(operation: String)
    case unsupportedTapFormat(formatID: AudioFormatID, channelCount: UInt32)
    case aggregateHasNoInputStreams
    case publishedDeviceInUse
    case operationFailed(operation: String, status: OSStatus)
    case cleanupFailed([PublicProcessedMicrophoneCleanupFailure])
    case rollbackFailed(
        primaryErrorDescription: String,
        cleanupFailures: [PublicProcessedMicrophoneCleanupFailure]
    )

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return localized("Publishing the processed microphone requires macOS 14.2 or later.")
        case let .audioProcessUnavailable(pid):
            return localized(
                "This app’s audio process object could not be read (PID %d). Try again once the audio engine is ready.",
                pid
            )
        case let .permissionDenied(operation):
            return localized("%@ needs system audio recording permission, which has not been granted.", operation)
        case let .audioServiceUnavailable(operation, status):
            return localized(
                "%1$@ cannot run. Try again once the Core Audio service is available (status %2$@).",
                operation,
                Self.describe(status)
            )
        case let .missingPropertyValue(operation):
            return localized("Core Audio returned no value for %@.", operation)
        case let .unsupportedTapFormat(formatID, channelCount):
            return localized(
                "The processed microphone tap’s audio format cannot be used (format %1$@, channels %2$u).",
                Self.describe(formatID),
                channelCount
            )
        case .aggregateHasNoInputStreams:
            return localized("The published processed microphone was created without an input stream.")
        case .publishedDeviceInUse:
            return localized(
                "Another app is using “%@”, so publication cannot be withdrawn. Choosing a different microphone in that app releases it.",
                PublicProcessedMicrophoneDevice.deviceName
            )
        case let .operationFailed(operation, status):
            return localized("%1$@ failed (Core Audio status %2$@).", operation, Self.describe(status))
        case let .cleanupFailed(failures):
            return localized("Shutting down the processed microphone failed (%@).", Self.describe(failures))
        case let .rollbackFailed(primaryErrorDescription, failures):
            return localized(
                "%1$@ Cleaning up the resources it had already created also failed (%2$@).",
                primaryErrorDescription,
                Self.describe(failures)
            )
        }
    }

    private static func describe(_ failures: [PublicProcessedMicrophoneCleanupFailure]) -> String {
        failures
            .map { "\($0.operation): \(describe($0.status))" }
            .joined(separator: ", ")
    }

    private static func describe<T: BinaryInteger>(_ status: T) -> String {
        let value = UInt32(truncatingIfNeeded: status)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")' (\(status))"
        }
        return String(status)
    }
}

/// Publishes this process's rendered audio as a system-visible, mono input device.
///
/// The class does not render audio itself. Call `start()` before starting the audio engine that
/// sends processed microphone samples to its output node. The process tap uses `.muted`, so those
/// samples are captured by the public aggregate device without reaching the physical output.
///
/// A publication makes several lifecycle calls in a row on the main thread:
/// the process tap's create, the aggregate device's create, and the
/// permission probe IOProc's create, start, stop and destroy. Like any other
/// start, it takes the quiet window's generation it was issued in once and
/// compares it immediately before each of those calls. A listener can advance
/// the generation on its own queue while an earlier call waits in coreaudiod;
/// the publication then stops before its next call, writes an `interrupt`
/// line, and throws `Interrupted`. It issues nothing more inside the window,
/// neither a create or start nor a stop, destroy or rollback: what it created
/// is kept, unpublished, a started probe IOProc still running, and
/// `keepsInterruptedPublication` tells the owner. The owner's first
/// evaluation after the window rolls it back with `stop(holdToken:)`, and
/// publishes again once starts are admitted.
final class PublicProcessedMicrophoneDevice {
    /// A quiet window armed after a publication, or a release of what one
    /// kept, was issued, and it stopped before its next lifecycle call. Not a
    /// failure: nothing was rolled back inside the window, and the owner
    /// releases what is kept after it.
    struct Interrupted: Error {}

    private enum DeviceLookupResult {
        case found(AudioDeviceID)
        case absent
        case failed(OSStatus)
    }

    /// Why a teardown did or did not happen.
    ///
    /// `refusedWhileInUse` is not an error condition to recover from but a
    /// deliberate refusal: destroying an aggregate device that another process
    /// is running IO on takes coreaudiod down for every process on the machine,
    /// and SIP means the only way back is a restart. Leaving the publication in
    /// place is always recoverable, so the caller is expected to keep it and
    /// retry once the device reports itself idle.
    private enum CleanupOutcome {
        case completed
        case refusedWhileInUse
        /// A quiet window armed after the release was issued. It ended before
        /// the lifecycle call its `interrupt` line names, and what it had not
        /// yet released stays as it is.
        case interrupted
        case failed([PublicProcessedMicrophoneCleanupFailure])
    }

    /// How the quiet window holds one sequence of this device's lifecycle
    /// calls, and what its lines carry.
    private struct Hold {
        /// The generation the sequence was issued in: compared immediately
        /// before each of its lifecycle calls, and carried on their lines. A
        /// publication, the rollback of what one kept, the owed teardown, the
        /// retry of a switched-off teardown and the launch cleanup all carry
        /// the generation the owner's evaluation saw. nil only for a sequence
        /// the window does not hold: Quit, and what deallocation releases.
        let token: UInt64?
        /// Set by Quit and by the launch cleanup, for the log.
        var reason: String?
        /// What a mismatch is logged as: `interrupt` for a publication,
        /// `interrupt-stop` for a release.
        var interruption: HALLifecycleLog.Operation = .interruptStop
    }

    /// The permission probe's IOProc, from its create until its destroy has
    /// returned.
    private struct Probe {
        let deviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
        var state: LifecycleTeardown.IOProc
    }

    private enum ProbeRelease {
        case released([PublicProcessedMicrophoneCleanupFailure])
        case interrupted
    }

    struct PublishedDevice {
        let deviceID: AudioObjectID
        let deviceUID: String
        let tapID: AudioObjectID
        let tapUID: String
        let sampleRate: Double
        let channelCount: UInt32
    }

    static let deviceName = "Audio Level Bar Microphone"
    static let aggregateDeviceUIDPrefix =
        "io.github.yuhkis.audio-level-bar.processed-microphone"
    static let aggregateDeviceUID = "\(aggregateDeviceUIDPrefix).public"

    /// UIDs earlier builds published this aggregate under.
    ///
    /// Empty: the app has only ever been published under the current
    /// identifier. The list stays because `AudioResourceNamespace` takes it as
    /// a parameter, and because a future rename would need it again.
    static let legacyAggregateDeviceUIDPrefixes: [String] = []

    /// True when the UID belongs to an aggregate this app publishes.
    static func ownsAggregateDeviceUID(_ uid: String) -> Bool {
        if uid.hasPrefix(aggregateDeviceUIDPrefix) {
            return true
        }
        return legacyAggregateDeviceUIDPrefixes.contains { uid.hasPrefix($0) }
    }

    private static let staleAggregateDeviceUIDs =
        [aggregateDeviceUID]
            + legacyAggregateDeviceUIDPrefixes.map { "\($0).public" }

    private static let tapName = "Audio Level Bar Processed Microphone Tap"
    private static let permissionProbeQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.processed-microphone.permission-probe",
        qos: .userInitiated
    )

    private let halCalls: any HALLifecycleCalls
    /// Compared immediately before each lifecycle call of a publication, a
    /// release and a removal issued with a generation, which is every one
    /// but Quit's.
    private let holdGeneration: LifecycleHoldGeneration
    private let lifecycleLock = NSLock()
    /// Guarded by `lifecycleLock`. The permission probe's IOProc while it
    /// exists: during a publication, and afterwards only when a quiet window
    /// interrupted that publication before the probe's destroy.
    private var probe: Probe?
    /// Guarded by `lifecycleLock`. A quiet window interrupted a publication,
    /// or the release of what one kept, and something it created is still
    /// held, unpublished. Cleared once a release has run to its end, whatever
    /// its outcome, and when coreaudiod restarts.
    private var interruptedPublicationIsKept = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    /// The UID of the tap `tapID` names, the UUID its description carried,
    /// for the log; set immediately before the create.
    private var tapUIDForLog: String?
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var currentPublishedDevice: PublishedDevice?
    private var inUseListenerBlock: AudioObjectPropertyListenerBlock?
    private var inUseListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
    /// A device an earlier run published whose removal was refused because
    /// a consuming app still had it open. While this instance holds no
    /// publication of its own, the in-use listener watches it and `isInUse`
    /// reads it, so the owner learns when the teardown it owes can proceed
    /// instead of reading the device as idle on every check. Dropped once the
    /// device is destroyed or no longer listed.
    private var refusedStaleDevice: (deviceID: AudioObjectID, uid: String)?
    /// Guarded by `lifecycleLock`. Whether the stale removal under way
    /// destroyed an earlier run's device.
    private var destroyedStaleDevice = false

    /// Reports another process starting or stopping IO on the published
    /// device. Delivered on the main queue.
    var onInUseChanged: ((Bool) -> Void)?

    init(halCalls: any HALLifecycleCalls, holdGeneration: LifecycleHoldGeneration) {
        self.halCalls = halCalls
        self.holdGeneration = holdGeneration
    }

    /// `gen=` for a line of a sequence held as `hold`: the generation it was
    /// issued in, carried on every one of its lines. For a sequence that is
    /// not compared, `-` at Quit, which the quiet window does not hold, and
    /// otherwise the generation current as the call is made. Read once
    /// immediately before each call and carried on both its begin and result
    /// lines, so a listener that advances the generation during the call
    /// cannot split the pair.
    private func logGeneration(_ hold: Hold) -> UInt64? {
        if let token = hold.token {
            return token
        }
        return hold.reason == HALLifecycleLog.quitReason ? nil : holdGeneration.current
    }

    /// Whether the next lifecycle call of a sequence held as `hold` may be
    /// made: always, for one that is not compared. At a mismatch the call is
    /// held back, and an `interrupt` or `interrupt-stop` line names its
    /// object, the generation the sequence was issued in, and the call, as
    /// `reason=before-<operation>`.
    private func mayCall(
        _ operation: HALLifecycleLog.Operation,
        on object: HALLifecycleLog.Object,
        id: AudioObjectID,
        hold: Hold,
        aggregateUID: String? = nil,
        tapUID: String? = nil
    ) -> Bool {
        guard !holdGeneration.allows(hold.token) else {
            return true
        }
        HALLifecycleLog.record(
            object,
            hold.interruption,
            id: id,
            generation: hold.token,
            reason: HALLifecycleLog.heldBackReason(operation),
            aggregateUID: aggregateUID,
            tapUID: tapUID
        )
        return false
    }

    /// Whether a publication the quiet window interrupted left something
    /// behind: a tap, an aggregate device, or a probe IOProc that may still
    /// be running, none of it published. The owner rolls it back with
    /// `stop(holdToken:)` at its first evaluation after the window.
    var keepsInterruptedPublication: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return interruptedPublicationIsKept
    }

    /// False when the in-use listener could not be installed. The owner must
    /// then keep the processing pipeline running unconditionally rather than
    /// leave a device that publishes silence.
    var isMonitoringInUse: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return inUseListenerBlock != nil
    }

    /// True while another process is running IO on the published device, or,
    /// while this instance holds none, on an earlier run's device whose
    /// removal was refused because it was in use.
    ///
    /// This app's own publisher engine renders to a physical output device
    /// and is captured through the process tap, so it does not make the
    /// aggregate itself run; the value reflects consuming apps only.
    ///
    /// While an interrupted publication's probe IOProc exists, nothing is
    /// read and the value is false: the device can read as running because
    /// of the probe alone, and a consumer cannot be told from it. A release
    /// stops and destroys the probe first, and reads the device itself
    /// immediately before it destroys it.
    var isInUse: Bool {
        lifecycleLock.lock()
        let deviceID = aggregateDeviceID != kAudioObjectUnknown
            ? aggregateDeviceID
            : refusedStaleDevice?.deviceID ?? AudioObjectID(kAudioObjectUnknown)
        let probeExists = probe != nil
        lifecycleLock.unlock()
        guard deviceID != kAudioObjectUnknown, !probeExists else {
            return false
        }
        return readIsRunningSomewhere(deviceID)
    }

    /// Whether this instance holds a publication, without asking the HAL
    /// whether it is still valid. Cheap enough for every lifecycle
    /// evaluation; `isPublished` enumerates every device to validate it.
    var holdsPublication: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return currentPublishedDevice != nil
    }

    var publishedDevice: PublishedDevice? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard
            let currentPublishedDevice,
            isPublishedDeviceValidLocked(currentPublishedDevice)
        else {
            return nil
        }
        return currentPublishedDevice
    }

    var isPublished: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let currentPublishedDevice else {
            return false
        }
        return isPublishedDeviceValidLocked(currentPublishedDevice)
    }

    /// Publishes the device, or returns the publication it already holds
    /// when that is still valid.
    ///
    /// The owner issues a publication only outside the quiet window, but the
    /// calls below run one after another on the main thread, and each can
    /// wait in coreaudiod while a listener advances the window's generation
    /// on its own queue. The publication takes the generation once, here, and
    /// compares it immediately before every lifecycle call it makes: the
    /// release of what an earlier publication left, the removal of an earlier
    /// run's device, the tap's and the aggregate device's create, the probe
    /// IOProc's create, start, stop and destroy, and the rollback of a
    /// publication that failed. At a mismatch it makes no further call and
    /// throws `Interrupted`; what exists is kept for the release after the
    /// window (`keepsInterruptedPublication`). The owner's other conditions
    /// cannot change meanwhile: they are written on the main thread, which
    /// this call occupies.
    ///
    /// - Parameter issuedToken: The generation the owner's evaluation admitted
    ///   the publication under. An advance that lands after that evaluation
    ///   read its admission then fails the first check. nil takes the current
    ///   one.
    @discardableResult
    func start(holdToken issuedToken: UInt64? = nil) throws -> PublishedDevice {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let hold = Hold(token: issuedToken ?? holdGeneration.current, interruption: .interrupt)
        return try notingAnInterruptionLocked {
            try startLocked(hold)
        }
    }

    private func startLocked(_ hold: Hold) throws -> PublishedDevice {
        if let currentPublishedDevice {
            if isPublishedDeviceValidLocked(currentPublishedDevice) {
                return currentPublishedDevice
            }

            try throwIfNotCompleted(cleanupLocked(hold))
        }

        guard #available(macOS 14.2, *) else {
            throw PublicProcessedMicrophoneDeviceError.unsupportedOS
        }

        // Releases what a publication the window interrupted kept, if the
        // owner's evaluation has not already rolled it back.
        try throwIfNotCompleted(cleanupLocked(hold))
        try throwIfNotCompleted(removeStalePublishedDeviceLocked(hold))

        do {
            return try createLocked(hold)
        } catch let interruption as Interrupted {
            // Nothing is rolled back inside the window.
            throw interruption
        } catch {
            try rollbackLocked(after: error, hold: hold)
            throw error
        }
    }

    /// Runs a publication or a release, and records whether a quiet window
    /// interrupted it with something unpublished still held. A publication
    /// found invalid whose release was held back before its first call is
    /// still a publication, and is not counted.
    private func notingAnInterruptionLocked<T>(_ body: () throws -> T) throws -> T {
        do {
            let value = try body()
            interruptedPublicationIsKept = false
            return value
        } catch let interruption as Interrupted {
            interruptedPublicationIsKept = currentPublishedDevice == nil
                && (probe != nil || aggregateDeviceID != kAudioObjectUnknown || tapID != kAudioObjectUnknown)
            throw interruption
        } catch {
            // The release ran to its end. What a refusal or a failure left
            // is the owner's owed teardown from here on.
            interruptedPublicationIsKept = false
            throw error
        }
    }

    /// coreaudiod restarted, and the publication went with the old server:
    /// its tap, its aggregate device and the in-use listener no longer exist,
    /// and their IDs may name something else now. They are dropped without a
    /// HAL call, so a later teardown cannot destroy another object under a
    /// reused ID, and the owner publishes again after the quiet window. What
    /// an interrupted publication kept, its probe IOProc included, is dropped
    /// the same way.
    func forgetAfterServiceRestart() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if let probe {
            HALLifecycleLog.record(
                .processedMicrophoneProbeIOProc,
                .forget,
                id: probe.deviceID,
                generation: holdGeneration.current,
                aggregateUID: Self.aggregateDeviceUID
            )
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            HALLifecycleLog.record(
                .processedMicrophoneAggregate,
                .forget,
                id: aggregateDeviceID,
                generation: holdGeneration.current,
                aggregateUID: Self.aggregateDeviceUID,
                tapUID: tapUIDForLog
            )
        }
        if tapID != kAudioObjectUnknown {
            HALLifecycleLog.record(
                .processedMicrophoneTap,
                .forget,
                id: tapID,
                generation: holdGeneration.current,
                tapUID: tapUIDForLog
            )
        }
        probe = nil
        interruptedPublicationIsKept = false
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapUIDForLog = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        currentPublishedDevice = nil
        inUseListenerBlock = nil
        inUseListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
        refusedStaleDevice = nil
    }

    /// Withdraws the publication, or rolls back what a publication the quiet
    /// window interrupted kept, refusing while a consuming app has the device
    /// open. The calls come one at a time in `LifecycleTeardown`'s order: the
    /// probe IOProc's stop and destroy, the aggregate device, then the tap.
    ///
    /// - Parameter holdToken: The generation the owner's evaluation issued
    ///   the withdrawal or the rollback in. It is compared immediately before
    ///   each lifecycle call; at a mismatch no further call is made,
    ///   `interrupt-stop` is written, what remains is kept for the next
    ///   release, and `Interrupted` is thrown. Held back before the aggregate
    ///   device's destroy, the publication is intact, in-use listener
    ///   included. Held back before the tap's destroy, which follows a wait
    ///   of up to half a second for the destroyed device to leave the device
    ///   list, the device is gone and the tap is kept like what an
    ///   interrupted publication left (`keepsInterruptedPublication`). nil
    ///   for Quit alone, which the window does not hold.
    /// - Parameter reason: Set by Quit, which the quiet window does not hold,
    ///   and appended to the stop and destroy lines in the hal-lifecycle log.
    func stop(holdToken: UInt64? = nil, reason: String? = nil) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        try notingAnInterruptionLocked {
            try throwIfNotCompleted(cleanupLocked(Hold(token: holdToken, reason: reason)))
        }
    }

    /// Removes an aggregate device left behind by an earlier process instance.
    ///
    /// The stable UID is owned by this app. This method intentionally does nothing while this
    /// instance owns any publication resources, so it cannot tear down its active route.
    ///
    /// - Parameter reason: Set at launch, where the removal runs at the first
    ///   evaluation that admits starts, and appended to the destroy lines in
    ///   the hal-lifecycle log.
    /// - Parameter holdToken: The generation the owner's evaluation issued
    ///   the removal in, compared immediately before the destroy, after the
    ///   device list has been read to find the device. At a mismatch nothing
    ///   is destroyed, `interrupt-stop` is written and `Interrupted` is
    ///   thrown; the owner removes it after the window.
    /// - Returns: Whether an earlier run's device was destroyed. Destroying
    ///   it can change the default input, if it was the default, so the
    ///   owner holds the quiet window before it starts anything.
    @discardableResult
    func removeStalePublishedDevice(reason: String? = nil, holdToken: UInt64? = nil) throws -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard
            currentPublishedDevice == nil,
            aggregateDeviceID == kAudioObjectUnknown,
            tapID == kAudioObjectUnknown
        else {
            return false
        }

        destroyedStaleDevice = false
        try throwIfNotCompleted(removeStalePublishedDeviceLocked(Hold(token: holdToken, reason: reason)))
        return destroyedStaleDevice
    }

    deinit {
        // Best effort. A refusal here cannot be deferred to anything, so the
        // publication outlives the process; the next launch reclaims it once
        // no consumer is holding it.
        lifecycleLock.lock()
        _ = cleanupLocked(Hold(token: nil))
        lifecycleLock.unlock()
    }

    private func throwIfNotCompleted(_ outcome: CleanupOutcome) throws {
        switch outcome {
        case .completed:
            return
        case .refusedWhileInUse:
            throw PublicProcessedMicrophoneDeviceError.publishedDeviceInUse
        case .interrupted:
            throw Interrupted()
        case let .failed(failures):
            throw PublicProcessedMicrophoneDeviceError.cleanupFailed(failures)
        }
    }

    /// Unwinds a half-built publication, preserving the error that caused it.
    ///
    /// A publication that fails while a quiet window arms is not unwound
    /// inside that window: the rollback stops before its next lifecycle call,
    /// and the publication counts as interrupted rather than failed, as a
    /// meter's failed start does. A failure during a device change is likely
    /// that change's doing, and the owner publishes again after the window.
    private func rollbackLocked(after error: Error, hold: Hold) throws {
        switch cleanupLocked(hold) {
        case .completed, .refusedWhileInUse:
            return
        case .interrupted:
            throw Interrupted()
        case let .failed(failures):
            let primaryDescription = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            throw PublicProcessedMicrophoneDeviceError.rollbackFailed(
                primaryErrorDescription: primaryDescription,
                cleanupFailures: failures
            )
        }
    }

    @available(macOS 14.2, *)
    private func createLocked(_ hold: Hold) throws -> PublishedDevice {
        let pid = getpid()
        let processObjectID = try audioProcessObjectID(for: pid)

        let tapDescription = CATapDescription(
            monoMixdownOfProcesses: [processObjectID]
        )
        tapDescription.name = Self.tapName
        tapDescription.isPrivate = false
        tapDescription.muteBehavior = .muted

        guard
            mayCall(.create, on: .processedMicrophoneTap, id: AudioObjectID(kAudioObjectUnknown), hold: hold)
        else {
            throw Interrupted()
        }
        // The tap's UID is the UUID of its description, generated here, so
        // the begin line can already name it.
        let newTapUID = tapDescription.uuid.uuidString
        let tapGeneration = logGeneration(hold)
        HALLifecycleLog.begin(
            .processedMicrophoneTap,
            .create,
            id: AudioObjectID(kAudioObjectUnknown),
            generation: tapGeneration,
            tapUID: newTapUID
        )
        let (tapStatus, newTapID) = halCalls.createProcessTap(tapDescription)
        HALLifecycleLog.record(
            .processedMicrophoneTap,
            .create,
            id: newTapID,
            status: tapStatus,
            generation: tapGeneration,
            tapUID: newTapUID
        )
        try check(
            tapStatus,
            operation: localized("Creating the processed microphone tap")
        )
        tapID = newTapID
        tapUIDForLog = newTapUID

        let tapUIDOperation = localized("Reading the processed microphone tap UID")
        let tapUIDRead = halCalls.tapUID(newTapID)
        try check(tapUIDRead.status, operation: tapUIDOperation)
        guard let tapUID = tapUIDRead.uid else {
            throw PublicProcessedMicrophoneDeviceError.missingPropertyValue(operation: tapUIDOperation)
        }
        // Later lines name the tap by the UID the HAL reports for it, the one
        // the aggregate device lists.
        tapUIDForLog = tapUID
        let format = try readTapFormat(newTapID)
        guard
            format.mFormatID == kAudioFormatLinearPCM,
            format.mChannelsPerFrame == 1
        else {
            throw PublicProcessedMicrophoneDeviceError.unsupportedTapFormat(
                formatID: format.mFormatID,
                channelCount: format.mChannelsPerFrame
            )
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.deviceName,
            kAudioAggregateDeviceUIDKey: Self.aggregateDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]

        // The tap's UID and format reads above can wait in coreaudiod too.
        guard
            mayCall(
                .create,
                on: .processedMicrophoneAggregate,
                id: AudioObjectID(kAudioObjectUnknown),
                hold: hold,
                tapUID: tapUIDForLog
            )
        else {
            throw Interrupted()
        }
        let aggregateGeneration = logGeneration(hold)
        HALLifecycleLog.begin(
            .processedMicrophoneAggregate,
            .create,
            id: AudioObjectID(kAudioObjectUnknown),
            generation: aggregateGeneration,
            aggregateUID: Self.aggregateDeviceUID,
            tapUID: tapUIDForLog
        )
        let (aggregateStatus, newAggregateDeviceID) = halCalls.createAggregate(
            aggregateDescription as CFDictionary
        )
        HALLifecycleLog.record(
            .processedMicrophoneAggregate,
            .create,
            id: newAggregateDeviceID,
            status: aggregateStatus,
            generation: aggregateGeneration,
            aggregateUID: Self.aggregateDeviceUID,
            tapUID: tapUIDForLog
        )
        try check(
            aggregateStatus,
            operation: localized("Creating the processed microphone aggregate device")
        )
        aggregateDeviceID = newAggregateDeviceID

        guard try inputStreamCount(of: newAggregateDeviceID) > 0 else {
            throw PublicProcessedMicrophoneDeviceError.aggregateHasNoInputStreams
        }

        try probeInputPermission(of: newAggregateDeviceID, hold: hold)

        // Install after the permission probe, whose own short-lived IOProc
        // would otherwise report this app as a consumer of its own device.
        // An earlier run's device was removed before this publication was
        // created, so nothing is left to watch there. Adding a listener is
        // not a lifecycle call and is not held: once the probe has been
        // destroyed, the publication completes.
        refusedStaleDevice = nil
        installInUseListenerLocked(for: newAggregateDeviceID)

        let published = PublishedDevice(
            deviceID: newAggregateDeviceID,
            deviceUID: Self.aggregateDeviceUID,
            tapID: newTapID,
            tapUID: tapUID,
            sampleRate: format.mSampleRate,
            channelCount: format.mChannelsPerFrame
        )
        currentPublishedDevice = published
        return published
    }

    private func installInUseListenerLocked(for deviceID: AudioObjectID) {
        removeInUseListenerLocked()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else {
                return
            }
            onInUseChanged?(readIsRunningSomewhere(deviceID))
        }
        // A failure here is not fatal to publication, but it leaves the owner
        // without the signal. isMonitoringInUse reports that so it can fall
        // back to running the pipeline unconditionally.
        guard
            halCalls.addPropertyListener(
                deviceID: deviceID,
                address: Self.inUsePropertyAddress,
                queue: DispatchQueue.main,
                block: block
            ) == noErr
        else {
            return
        }
        inUseListenerBlock = block
        inUseListenerDeviceID = deviceID
    }

    private func removeInUseListenerLocked() {
        guard
            let inUseListenerBlock,
            inUseListenerDeviceID != kAudioObjectUnknown
        else {
            self.inUseListenerBlock = nil
            inUseListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
            return
        }

        halCalls.removePropertyListener(
            deviceID: inUseListenerDeviceID,
            address: Self.inUsePropertyAddress,
            queue: DispatchQueue.main,
            block: inUseListenerBlock
        )
        self.inUseListenerBlock = nil
        inUseListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private static var inUsePropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readIsRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        let (status, value) = halCalls.isRunningSomewhere(deviceID)
        return Self.readsAsRunningSomewhere(status: status, value: value)
    }

    /// Whether a `kAudioDevicePropertyDeviceIsRunningSomewhere` read counts
    /// as in use. A read that failed counts as in use, so a destroy is
    /// refused rather than risked: destroying an aggregate device a process
    /// has open stops coreaudiod answering. Only a bad object status, a
    /// device that is already gone, counts as not running.
    static func readsAsRunningSomewhere(status: OSStatus, value: UInt32) -> Bool {
        switch status {
        case noErr:
            return value != 0
        case kAudioHardwareBadObjectError:
            return false
        default:
            return true
        }
    }

    private func isPublishedDeviceValidLocked(_ published: PublishedDevice) -> Bool {
        guard
            aggregateDeviceID == published.deviceID,
            tapID == published.tapID,
            published.deviceUID == Self.aggregateDeviceUID,
            case let .found(liveDeviceID) = deviceLookupResult(
                withUID: Self.aggregateDeviceUID
            ),
            liveDeviceID == published.deviceID
        else {
            return false
        }

        do {
            let aggregateUID = try readString(
                halCalls.readDeviceUID(published.deviceID),
                operation: localized("Confirming the processed microphone aggregate device UID")
            )
            let liveTapUID = try readString(
                halCalls.tapUID(published.tapID),
                operation: localized("Confirming the processed microphone tap UID")
            )
            let hasInputStreams = try inputStreamCount(of: published.deviceID) > 0
            return aggregateUID == Self.aggregateDeviceUID
                && liveTapUID == published.tapUID
                && hasInputStreams
        } catch {
            return false
        }
    }

    /// - Parameter hold: How the removal is held and logged: the generation
    ///   of the publication or of the evaluation that issued it, with the
    ///   reason of a removal that names one.
    private func removeStalePublishedDeviceLocked(_ hold: Hold) -> CleanupOutcome {
        // Covers the UIDs in legacyAggregateDeviceUIDPrefixes as well as the
        // current one — that list is empty today — so an aggregate a crashed
        // build left under an earlier UID cannot outlive the change.
        var failures: [PublicProcessedMicrophoneCleanupFailure] = []
        for staleUID in Self.staleAggregateDeviceUIDs {
            switch removeStaleAggregateDeviceLocked(withUID: staleUID, hold: hold) {
            case .completed:
                continue
            case .refusedWhileInUse:
                return .refusedWhileInUse
            case .interrupted:
                return .interrupted
            case let .failed(staleFailures):
                failures.append(contentsOf: staleFailures)
            }
        }
        return failures.isEmpty ? .completed : .failed(failures)
    }

    private func removeStaleAggregateDeviceLocked(
        withUID staleUID: String,
        hold: Hold
    ) -> CleanupOutcome {
        let reason = hold.reason
        let staleDeviceID: AudioDeviceID
        switch deviceLookupResult(withUID: staleUID) {
        case let .found(deviceID):
            staleDeviceID = deviceID
        case .absent:
            forgetRefusedStaleDeviceLocked(uid: staleUID)
            return .completed
        case let .failed(status):
            return .failed([
                PublicProcessedMicrophoneCleanupFailure(
                    operation: localized("Searching for an earlier processed microphone aggregate device"),
                    status: status
                )
            ])
        }

        // The generation first, so that in use is still read immediately
        // before the destroy.
        guard
            mayCall(
                .destroy,
                on: .processedMicrophoneAggregate,
                id: staleDeviceID,
                hold: hold,
                aggregateUID: staleUID
            )
        else {
            return .interrupted
        }

        // A device left behind by a crashed run is still a real input other
        // apps can be holding open right now. Destroying it under them is the
        // same machine-wide hazard as destroying a live one. It is watched
        // instead, so the teardown owed for it runs once it is let go.
        guard !readIsRunningSomewhere(staleDeviceID) else {
            watchRefusedStaleDeviceLocked(deviceID: staleDeviceID, uid: staleUID)
            return .refusedWhileInUse
        }

        let generation = logGeneration(hold)
        HALLifecycleLog.begin(
            .processedMicrophoneAggregate,
            .destroy,
            id: staleDeviceID,
            generation: generation,
            reason: reason,
            aggregateUID: staleUID
        )
        let status = halCalls.destroyAggregate(staleDeviceID)
        HALLifecycleLog.record(
            .processedMicrophoneAggregate,
            .destroy,
            id: staleDeviceID,
            status: status,
            generation: generation,
            reason: reason,
            aggregateUID: staleUID
        )
        guard status == noErr || status == kAudioHardwareBadObjectError else {
            return .failed([
                PublicProcessedMicrophoneCleanupFailure(
                    operation: localized("Destroying an earlier processed microphone aggregate device"),
                    status: status
                )
            ])
        }
        if status == noErr {
            destroyedStaleDevice = true
        }

        let disappearanceStatus = waitForAggregateDeviceUIDToDisappear(
            uid: staleUID,
            knownDeviceID: staleDeviceID
        )
        guard disappearanceStatus == noErr else {
            return .failed([
                PublicProcessedMicrophoneCleanupFailure(
                    operation: localized("Confirming an earlier processed microphone aggregate device is gone"),
                    status: disappearanceStatus
                )
            ])
        }
        forgetRefusedStaleDeviceLocked(uid: staleUID)
        return .completed
    }

    /// Watches an earlier run's device whose removal was refused while in
    /// use, with the in-use listener. Never while this instance holds a
    /// publication of its own, whose listener is not replaced.
    private func watchRefusedStaleDeviceLocked(deviceID: AudioObjectID, uid: String) {
        guard currentPublishedDevice == nil, aggregateDeviceID == kAudioObjectUnknown else {
            return
        }
        refusedStaleDevice = (deviceID: deviceID, uid: uid)
        if inUseListenerBlock != nil, inUseListenerDeviceID == deviceID {
            return
        }
        installInUseListenerLocked(for: deviceID)
    }

    /// Stops watching an earlier run's device once it is destroyed or no
    /// longer listed under `uid`.
    private func forgetRefusedStaleDeviceLocked(uid: String) {
        guard let refused = refusedStaleDevice, refused.uid == uid else {
            return
        }
        refusedStaleDevice = nil
        if inUseListenerDeviceID == refused.deviceID {
            removeInUseListenerLocked()
        }
    }

    private func deviceLookupResult(
        withUID expectedUID: String,
        treatingUnreadableDeviceIDAsPresent knownDeviceID: AudioDeviceID? = nil
    ) -> DeviceLookupResult {
        let (status, deviceIDs) = halCalls.deviceIDList()
        guard status == noErr else {
            return .failed(status)
        }

        var firstUIDReadFailure: OSStatus?
        for deviceID in deviceIDs {
            let result = halCalls.readDeviceUID(deviceID)
            if let uid = result.uid {
                if uid == expectedUID {
                    return .found(deviceID)
                }
            } else if deviceID == knownDeviceID {
                return .found(deviceID)
            } else if firstUIDReadFailure == nil {
                firstUIDReadFailure = result.status
            }
        }
        if let firstUIDReadFailure {
            return .failed(firstUIDReadFailure)
        }
        return .absent
    }

    private func waitForAggregateDeviceUIDToDisappear(
        uid: String = PublicProcessedMicrophoneDevice.aggregateDeviceUID,
        knownDeviceID: AudioDeviceID
    ) -> OSStatus {
        let pollIntervalMicroseconds: useconds_t = 10_000
        let maximumPollCount = 50

        for pollIndex in 0...maximumPollCount {
            switch deviceLookupResult(
                withUID: uid,
                treatingUnreadableDeviceIDAsPresent: knownDeviceID
            ) {
            case .absent:
                return noErr
            case .found:
                guard pollIndex < maximumPollCount else {
                    return kAudioHardwareNotReadyError
                }
            case let .failed(status):
                return status
            }
            usleep(pollIntervalMicroseconds)
        }
        return kAudioHardwareNotReadyError
    }

    /// Confirms the system audio recording permission by starting a no-op
    /// IOProc on the published aggregate device for 100 ms.
    ///
    /// The generation is compared immediately before the probe's create, its
    /// start, its stop and its destroy. An advance that arrives between the
    /// start and the stop leaves the probe's IO running until the release
    /// after the window, as a meter that a window finds running keeps
    /// running: a stop inside the window is what the window forbids, the
    /// callback does nothing, and the aggregate device it runs on has this
    /// process's own muted tap as its only input. A start that fails throws,
    /// and the publication's rollback releases the probe first, reading
    /// `kAudioDevicePropertyDeviceIsRunning` and stopping IO that reports
    /// running before it destroys the IOProc.
    private func probeInputPermission(of deviceID: AudioDeviceID, hold: Hold) throws {
        guard
            mayCall(
                .create,
                on: .processedMicrophoneProbeIOProc,
                id: deviceID,
                hold: hold,
                aggregateUID: Self.aggregateDeviceUID
            )
        else {
            throw Interrupted()
        }
        let createGeneration = logGeneration(hold)
        HALLifecycleLog.begin(
            .processedMicrophoneProbeIOProc,
            .create,
            id: deviceID,
            generation: createGeneration,
            aggregateUID: Self.aggregateDeviceUID
        )
        let (createStatus, ioProcID) = halCalls.createIOProc(
            deviceID: deviceID,
            queue: Self.permissionProbeQueue
        ) { _, _, _, _, _ in }
        HALLifecycleLog.record(
            .processedMicrophoneProbeIOProc,
            .create,
            id: deviceID,
            status: createStatus,
            generation: createGeneration,
            aggregateUID: Self.aggregateDeviceUID
        )
        if let ioProcID {
            // Held from here until its destroy has returned, whatever the
            // create's status says.
            probe = Probe(deviceID: deviceID, ioProcID: ioProcID, state: .created)
        }
        try check(
            createStatus,
            operation: localized("Creating the processed microphone permission probe IOProc")
        )
        guard let ioProcID else {
            throw PublicProcessedMicrophoneDeviceError.operationFailed(
                operation: localized("Creating the processed microphone permission probe IOProc"),
                status: kAudioHardwareUnspecifiedError
            )
        }

        guard
            mayCall(
                .start,
                on: .processedMicrophoneProbeIOProc,
                id: deviceID,
                hold: hold,
                aggregateUID: Self.aggregateDeviceUID
            )
        else {
            throw Interrupted()
        }
        probe?.state = .startUnconfirmed
        let startGeneration = logGeneration(hold)
        HALLifecycleLog.begin(
            .processedMicrophoneProbeIOProc,
            .start,
            id: deviceID,
            generation: startGeneration,
            aggregateUID: Self.aggregateDeviceUID
        )
        let startStatus = halCalls.start(deviceID: deviceID, ioProcID: ioProcID)
        HALLifecycleLog.record(
            .processedMicrophoneProbeIOProc,
            .start,
            id: deviceID,
            status: startStatus,
            generation: startGeneration,
            aggregateUID: Self.aggregateDeviceUID
        )
        try check(
            startStatus,
            operation: localized("Checking processed microphone recording permission")
        )
        probe?.state = .started

        // Starting the device is the permission check. Keep the real-time callback a no-op
        // and briefly let the HAL activate the public tap from this non-real-time path.
        usleep(100_000)

        switch releaseProbeLocked(hold) {
        case .interrupted:
            throw Interrupted()
        case let .released(failures):
            guard failures.isEmpty else {
                throw PublicProcessedMicrophoneDeviceError.cleanupFailed(failures)
            }
        }
    }

    /// Releases the permission probe's IOProc, if one exists, one HAL call at
    /// a time in `LifecycleTeardown`'s order: the stop, then the IOProc.
    /// After a start that did not return `noErr`, whether the device reports
    /// the IO running is read first, and running IO is stopped before its
    /// IOProc is destroyed (`reason=failed-start`). The generation is
    /// compared immediately before each lifecycle call, and the probe's
    /// state moves on only after its own call has returned, so a release a
    /// quiet window interrupts resumes where it ended.
    private func releaseProbeLocked(_ hold: Hold) -> ProbeRelease {
        guard let held = probe else {
            return .released([])
        }
        var failures: [PublicProcessedMicrophoneCleanupFailure] = []
        var teardown = LifecycleTeardown(ioProc: held.state)
        while let step = teardown.nextStep {
            switch step {
            case .readIsRunning:
                let (readStatus, running) = halCalls.isRunning(held.deviceID)
                teardown.noteIsRunning(readStatus == noErr && running != 0)
            case .stop:
                guard
                    mayCall(
                        .stop,
                        on: .processedMicrophoneProbeIOProc,
                        id: held.deviceID,
                        hold: hold,
                        aggregateUID: Self.aggregateDeviceUID
                    )
                else {
                    return .interrupted
                }
                let stopReason = teardown.stopFollowsUnconfirmedStart
                    ? hold.reason ?? HALLifecycleLog.unconfirmedStartReason
                    : hold.reason
                let stopGeneration = logGeneration(hold)
                HALLifecycleLog.begin(
                    .processedMicrophoneProbeIOProc,
                    .stop,
                    id: held.deviceID,
                    generation: stopGeneration,
                    reason: stopReason,
                    aggregateUID: Self.aggregateDeviceUID
                )
                let status = halCalls.stop(deviceID: held.deviceID, ioProcID: held.ioProcID)
                HALLifecycleLog.record(
                    .processedMicrophoneProbeIOProc,
                    .stop,
                    id: held.deviceID,
                    status: status,
                    generation: stopGeneration,
                    reason: stopReason,
                    aggregateUID: Self.aggregateDeviceUID
                )
                if status != noErr, status != kAudioHardwareBadObjectError {
                    failures.append(
                        PublicProcessedMicrophoneCleanupFailure(
                            operation: localized("Stopping the recording permission probe device"),
                            status: status
                        )
                    )
                }
                teardown.complete(.stop)
            case .destroyIOProc:
                guard
                    mayCall(
                        .destroy,
                        on: .processedMicrophoneProbeIOProc,
                        id: held.deviceID,
                        hold: hold,
                        aggregateUID: Self.aggregateDeviceUID
                    )
                else {
                    return .interrupted
                }
                let destroyGeneration = logGeneration(hold)
                HALLifecycleLog.begin(
                    .processedMicrophoneProbeIOProc,
                    .destroy,
                    id: held.deviceID,
                    generation: destroyGeneration,
                    reason: hold.reason,
                    aggregateUID: Self.aggregateDeviceUID
                )
                let status = halCalls.destroyIOProc(deviceID: held.deviceID, ioProcID: held.ioProcID)
                HALLifecycleLog.record(
                    .processedMicrophoneProbeIOProc,
                    .destroy,
                    id: held.deviceID,
                    status: status,
                    generation: destroyGeneration,
                    reason: hold.reason,
                    aggregateUID: Self.aggregateDeviceUID
                )
                if status != noErr, status != kAudioHardwareBadObjectError {
                    failures.append(
                        PublicProcessedMicrophoneCleanupFailure(
                            operation: localized("Destroying the recording permission probe IOProc"),
                            status: status
                        )
                    )
                }
                teardown.complete(.destroyIOProc)
            case .destroyAggregate, .destroyProcessTap:
                // The aggregate device and the tap are the cleanup's.
                teardown.complete(step)
            }
            probe?.state = teardown.ioProc
        }
        probe = nil
        return .released(failures)
    }

    /// Releases everything this instance holds, one lifecycle call at a time
    /// in `LifecycleTeardown`'s order: the probe IOProc's stop and destroy,
    /// when an interrupted publication left one, then the aggregate device,
    /// then the tap, so an aggregate device is never destroyed while its
    /// IOProc exists, nor the tap while its aggregate device exists.
    ///
    /// - Parameter hold: How the release is held and logged. With a
    ///   generation, it is compared immediately before each lifecycle call;
    ///   at a mismatch the release ends there with `.interrupted`, and each
    ///   handle it has not yet released stays as it is.
    private func cleanupLocked(_ hold: Hold) -> CleanupOutcome {
        let reason = hold.reason
        var failures: [PublicProcessedMicrophoneCleanupFailure] = []

        // A probe IOProc exists only while nothing is published, so its
        // release leaves any publication intact.
        switch releaseProbeLocked(hold) {
        case .interrupted:
            return .interrupted
        case let .released(probeFailures):
            failures.append(contentsOf: probeFailures)
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            // The generation first: it is no HAL call, and a release it holds
            // back leaves the publication completely intact too.
            guard
                mayCall(
                    .destroy,
                    on: .processedMicrophoneAggregate,
                    id: aggregateDeviceID,
                    hold: hold,
                    aggregateUID: Self.aggregateDeviceUID
                )
            else {
                return .interrupted
            }
            // Checked before the publication is released, and immediately
            // before the destroy below with no HAL call in between, so a
            // refusal leaves the publication completely intact — including the
            // in-use listener, which is how the owner learns that the teardown
            // can finally proceed. The check and the destroy cannot be made
            // atomic; this keeps the gap as short as the HAL allows. A read
            // that fails counts as in use.
            if readIsRunningSomewhere(aggregateDeviceID) {
                return .refusedWhileInUse
            }
        }

        currentPublishedDevice = nil
        var aggregateRemovalConfirmed = false

        if aggregateDeviceID != kAudioObjectUnknown {
            let aggregateGeneration = logGeneration(hold)
            HALLifecycleLog.begin(
                .processedMicrophoneAggregate,
                .destroy,
                id: aggregateDeviceID,
                generation: aggregateGeneration,
                reason: reason,
                aggregateUID: Self.aggregateDeviceUID
            )
            let status = halCalls.destroyAggregate(aggregateDeviceID)
            HALLifecycleLog.record(
                .processedMicrophoneAggregate,
                .destroy,
                id: aggregateDeviceID,
                status: status,
                generation: aggregateGeneration,
                reason: reason,
                aggregateUID: Self.aggregateDeviceUID
            )
            if status == noErr || status == kAudioHardwareBadObjectError {
                // This instance's own listener goes once its device has been
                // destroyed; a destroy that failed keeps it watching. A
                // listener watching an earlier run's device stays until that
                // device is removed below, or a refusal there leaves it
                // watching.
                removeInUseListenerLocked()
                let disappearanceStatus = waitForAggregateDeviceUIDToDisappear(
                    knownDeviceID: aggregateDeviceID
                )
                if disappearanceStatus == noErr {
                    aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
                    aggregateRemovalConfirmed = true
                } else {
                    failures.append(
                        PublicProcessedMicrophoneCleanupFailure(
                            operation: localized("Confirming the aggregate device is gone"),
                            status: disappearanceStatus
                        )
                    )
                }
            } else {
                failures.append(
                    PublicProcessedMicrophoneCleanupFailure(
                        operation: localized("Destroying the aggregate device"),
                        status: status
                    )
                )
            }
        } else {
            switch deviceLookupResult(withUID: Self.aggregateDeviceUID) {
            case .absent:
                forgetRefusedStaleDeviceLocked(uid: Self.aggregateDeviceUID)
                aggregateRemovalConfirmed = true
            case .found:
                // The stable UID can outlive this instance's cached object ID
                // after a crash or Core Audio reset. Remove that aggregate and
                // wait for its actual disappearance before touching any tap.
                switch removeStalePublishedDeviceLocked(hold) {
                case .completed:
                    aggregateRemovalConfirmed = true
                case .refusedWhileInUse:
                    return .refusedWhileInUse
                case .interrupted:
                    return .interrupted
                case let .failed(staleFailures):
                    failures.append(contentsOf: staleFailures)
                }
            case let .failed(status):
                failures.append(
                    PublicProcessedMicrophoneCleanupFailure(
                        operation: localized("Confirming the aggregate device is gone"),
                        status: status
                    )
                )
            }
        }

        if
            aggregateRemovalConfirmed,
            tapID != kAudioObjectUnknown,
            #available(macOS 14.2, *)
        {
            // The destroy above and the wait for the UID to leave the device
            // list can take half a second.
            guard
                mayCall(.destroy, on: .processedMicrophoneTap, id: tapID, hold: hold, tapUID: tapUIDForLog)
            else {
                return .interrupted
            }
            let tapGeneration = logGeneration(hold)
            HALLifecycleLog.begin(
                .processedMicrophoneTap,
                .destroy,
                id: tapID,
                generation: tapGeneration,
                reason: reason,
                tapUID: tapUIDForLog
            )
            let status = halCalls.destroyProcessTap(tapID)
            HALLifecycleLog.record(
                .processedMicrophoneTap,
                .destroy,
                id: tapID,
                status: status,
                generation: tapGeneration,
                reason: reason,
                tapUID: tapUIDForLog
            )
            if status == noErr || status == kAudioHardwareBadObjectError {
                tapID = AudioObjectID(kAudioObjectUnknown)
                tapUIDForLog = nil
            } else {
                failures.append(
                    PublicProcessedMicrophoneCleanupFailure(
                        operation: localized("Destroying the process tap"),
                        status: status
                    )
                )
            }
        }

        return failures.isEmpty ? .completed : .failed(failures)
    }

    /// Through the seam, as the system playback meter reads it.
    private func audioProcessObjectID(for pid: pid_t) throws -> AudioObjectID {
        let (status, processObjectID) = halCalls.processObjectID(for: pid)
        try check(status, operation: localized("Translating the PID to an audio process object"))
        guard processObjectID != kAudioObjectUnknown else {
            throw PublicProcessedMicrophoneDeviceError.audioProcessUnavailable(pid: pid)
        }
        return processObjectID
    }

    /// Through the seam, as the system playback meter reads it.
    private func readTapFormat(_ objectID: AudioObjectID) throws -> AudioStreamBasicDescription {
        let (status, format) = halCalls.tapFormat(objectID)
        try check(status, operation: localized("Reading the processed microphone tap format"))
        return format
    }

    /// A string property read through the seam: its status checked, and a
    /// read with no value thrown as missing.
    private func readString(
        _ read: (status: OSStatus, uid: String?),
        operation: String
    ) throws -> String {
        try check(read.status, operation: operation)
        guard let value = read.uid else {
            throw PublicProcessedMicrophoneDeviceError.missingPropertyValue(
                operation: operation
            )
        }
        return value
    }

    /// Through the seam.
    private func inputStreamCount(of deviceID: AudioObjectID) throws -> Int {
        let (status, count) = halCalls.inputStreamCount(of: deviceID)
        try check(
            status,
            operation: localized("Counting the processed microphone input streams")
        )
        return count
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status != kAudioDevicePermissionsError else {
            throw PublicProcessedMicrophoneDeviceError.permissionDenied(
                operation: operation
            )
        }
        guard
            status != kAudioHardwareNotRunningError,
            status != kAudioHardwareNotReadyError
        else {
            throw PublicProcessedMicrophoneDeviceError.audioServiceUnavailable(
                operation: operation,
                status: status
            )
        }
        guard status == noErr else {
            throw PublicProcessedMicrophoneDeviceError.operationFailed(
                operation: operation,
                status: status
            )
        }
    }
}
