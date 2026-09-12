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
final class PublicProcessedMicrophoneDevice {
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
        case failed([PublicProcessedMicrophoneCleanupFailure])
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
    private static let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private static let permissionProbeQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.processed-microphone.permission-probe",
        qos: .userInitiated
    )

    private let lifecycleLock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var currentPublishedDevice: PublishedDevice?
    private var inUseListenerBlock: AudioObjectPropertyListenerBlock?
    private var inUseListenerDeviceID = AudioObjectID(kAudioObjectUnknown)

    /// Reports another process starting or stopping IO on the published
    /// device. Delivered on the main queue.
    var onInUseChanged: ((Bool) -> Void)?

    /// False when the in-use listener could not be installed. The owner must
    /// then keep the processing pipeline running unconditionally rather than
    /// leave a device that publishes silence.
    var isMonitoringInUse: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return inUseListenerBlock != nil
    }

    /// True while another process is running IO on the published device.
    ///
    /// This app's own publisher engine renders to the physical output device
    /// and is captured through the process tap, so it does not make the
    /// aggregate itself run; the value reflects consuming apps only.
    var isInUse: Bool {
        lifecycleLock.lock()
        let deviceID = aggregateDeviceID
        lifecycleLock.unlock()
        guard deviceID != kAudioObjectUnknown else {
            return false
        }
        return Self.readIsRunningSomewhere(deviceID)
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

    @discardableResult
    func start() throws -> PublishedDevice {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if let currentPublishedDevice {
            if isPublishedDeviceValidLocked(currentPublishedDevice) {
                return currentPublishedDevice
            }

            try throwIfNotCompleted(cleanupLocked())
        }

        guard #available(macOS 14.2, *) else {
            throw PublicProcessedMicrophoneDeviceError.unsupportedOS
        }

        try throwIfNotCompleted(cleanupLocked())
        try throwIfNotCompleted(removeStalePublishedDeviceLocked())

        do {
            return try createLocked()
        } catch {
            try rollbackLocked(after: error)
            throw error
        }
    }

    func stop() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        try throwIfNotCompleted(cleanupLocked())
    }

    /// Removes an aggregate device left behind by an earlier process instance.
    ///
    /// The stable UID is owned by this app. This method intentionally does nothing while this
    /// instance owns any publication resources, so it cannot tear down its active route.
    func removeStalePublishedDevice() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard
            currentPublishedDevice == nil,
            aggregateDeviceID == kAudioObjectUnknown,
            tapID == kAudioObjectUnknown
        else {
            return
        }

        try throwIfNotCompleted(removeStalePublishedDeviceLocked())
    }

    deinit {
        // Best effort. A refusal here cannot be deferred to anything, so the
        // publication outlives the process; the next launch reclaims it once
        // no consumer is holding it.
        lifecycleLock.lock()
        _ = cleanupLocked()
        lifecycleLock.unlock()
    }

    private func throwIfNotCompleted(_ outcome: CleanupOutcome) throws {
        switch outcome {
        case .completed:
            return
        case .refusedWhileInUse:
            throw PublicProcessedMicrophoneDeviceError.publishedDeviceInUse
        case let .failed(failures):
            throw PublicProcessedMicrophoneDeviceError.cleanupFailed(failures)
        }
    }

    /// Unwinds a half-built publication, preserving the error that caused it.
    private func rollbackLocked(after error: Error) throws {
        switch cleanupLocked() {
        case .completed, .refusedWhileInUse:
            return
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
    private func createLocked() throws -> PublishedDevice {
        let pid = getpid()
        let processObjectID = try audioProcessObjectID(for: pid)

        let tapDescription = CATapDescription(
            monoMixdownOfProcesses: [processObjectID]
        )
        tapDescription.name = Self.tapName
        tapDescription.isPrivate = false
        tapDescription.muteBehavior = .muted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(tapDescription, &newTapID),
            operation: localized("Creating the processed microphone tap")
        )
        tapID = newTapID

        let tapUID = try readCFString(
            from: newTapID,
            selector: kAudioTapPropertyUID,
            operation: localized("Reading the processed microphone tap UID")
        )
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

        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &newAggregateDeviceID
            ),
            operation: localized("Creating the processed microphone aggregate device")
        )
        aggregateDeviceID = newAggregateDeviceID

        guard try inputStreamCount(of: newAggregateDeviceID) > 0 else {
            throw PublicProcessedMicrophoneDeviceError.aggregateHasNoInputStreams
        }

        try probeInputPermission(of: newAggregateDeviceID)

        // Install after the permission probe, whose own short-lived IOProc
        // would otherwise report this app as a consumer of its own device.
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

        var address = Self.inUsePropertyAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else {
                return
            }
            onInUseChanged?(Self.readIsRunningSomewhere(deviceID))
        }
        // A failure here is not fatal to publication, but it leaves the owner
        // without the signal. isMonitoringInUse reports that so it can fall
        // back to running the pipeline unconditionally.
        guard
            AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                DispatchQueue.main,
                block
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

        var address = Self.inUsePropertyAddress
        AudioObjectRemovePropertyListenerBlock(
            inUseListenerDeviceID,
            &address,
            DispatchQueue.main,
            inUseListenerBlock
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

    private static func readIsRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var address = inUsePropertyAddress
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == noErr && value != 0
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
            let aggregateUID = try readCFString(
                from: published.deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                operation: localized("Confirming the processed microphone aggregate device UID")
            )
            let liveTapUID = try readCFString(
                from: published.tapID,
                selector: kAudioTapPropertyUID,
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

    private func removeStalePublishedDeviceLocked() -> CleanupOutcome {
        // Covers the UIDs in legacyAggregateDeviceUIDPrefixes as well as the
        // current one — that list is empty today — so an aggregate a crashed
        // build left under an earlier UID cannot outlive the change.
        var failures: [PublicProcessedMicrophoneCleanupFailure] = []
        for staleUID in Self.staleAggregateDeviceUIDs {
            switch removeStaleAggregateDeviceLocked(withUID: staleUID) {
            case .completed:
                continue
            case .refusedWhileInUse:
                return .refusedWhileInUse
            case let .failed(staleFailures):
                failures.append(contentsOf: staleFailures)
            }
        }
        return failures.isEmpty ? .completed : .failed(failures)
    }

    private func removeStaleAggregateDeviceLocked(withUID staleUID: String)
        -> CleanupOutcome
    {
        let staleDeviceID: AudioDeviceID
        switch deviceLookupResult(withUID: staleUID) {
        case let .found(deviceID):
            staleDeviceID = deviceID
        case .absent:
            return .completed
        case let .failed(status):
            return .failed([
                PublicProcessedMicrophoneCleanupFailure(
                    operation: localized("Searching for an earlier processed microphone aggregate device"),
                    status: status
                )
            ])
        }

        // A device left behind by a crashed run is still a real input other
        // apps can be holding open right now. Destroying it under them is the
        // same machine-wide hazard as destroying a live one.
        guard !Self.readIsRunningSomewhere(staleDeviceID) else {
            return .refusedWhileInUse
        }

        let status = AudioHardwareDestroyAggregateDevice(staleDeviceID)
        guard status == noErr || status == kAudioHardwareBadObjectError else {
            return .failed([
                PublicProcessedMicrophoneCleanupFailure(
                    operation: localized("Destroying an earlier processed microphone aggregate device"),
                    status: status
                )
            ])
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
        return .completed
    }

    private func deviceLookupResult(
        withUID expectedUID: String,
        treatingUnreadableDeviceIDAsPresent knownDeviceID: AudioDeviceID? = nil
    ) -> DeviceLookupResult {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            Self.systemObjectID,
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else {
            return .failed(sizeStatus)
        }
        guard dataSize >= UInt32(MemoryLayout<AudioDeviceID>.size) else {
            return .absent
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        let status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                Self.systemObjectID,
                &address,
                0,
                nil,
                &dataSize,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            return .failed(status)
        }

        var firstUIDReadFailure: OSStatus?
        for deviceID in deviceIDs {
            let result = readDeviceUID(deviceID)
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

    private func readDeviceUID(_ deviceID: AudioDeviceID) -> (uid: String?, status: OSStatus) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr else {
            return (nil, status)
        }
        guard let value else {
            return (nil, kAudioHardwareUnspecifiedError)
        }
        return (value.takeRetainedValue() as String, noErr)
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

    private func probeInputPermission(of deviceID: AudioDeviceID) throws {
        var ioProcID: AudioDeviceIOProcID?
        var deviceStarted = false
        var primaryError: Error?

        do {
            try check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &ioProcID,
                    deviceID,
                    Self.permissionProbeQueue
                ) { _, _, _, _, _ in },
                operation: localized("Creating the processed microphone permission probe IOProc")
            )
            guard let ioProcID else {
                throw PublicProcessedMicrophoneDeviceError.operationFailed(
                    operation: localized("Creating the processed microphone permission probe IOProc"),
                    status: kAudioHardwareUnspecifiedError
                )
            }
            try check(
                AudioDeviceStart(deviceID, ioProcID),
                operation: localized("Checking processed microphone recording permission")
            )
            deviceStarted = true

            // Starting the device is the permission check. Keep the real-time callback a no-op
            // and briefly let the HAL activate the public tap from this non-real-time path.
            usleep(100_000)
        } catch {
            primaryError = error
        }

        var cleanupFailures: [PublicProcessedMicrophoneCleanupFailure] = []
        if deviceStarted, let ioProcID {
            let status = AudioDeviceStop(deviceID, ioProcID)
            if status != noErr, status != kAudioHardwareBadObjectError {
                cleanupFailures.append(
                    PublicProcessedMicrophoneCleanupFailure(
                        operation: localized("Stopping the recording permission probe device"),
                        status: status
                    )
                )
            }
        }
        if let ioProcID {
            let status = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            if status != noErr, status != kAudioHardwareBadObjectError {
                cleanupFailures.append(
                    PublicProcessedMicrophoneCleanupFailure(
                        operation: localized("Destroying the recording permission probe IOProc"),
                        status: status
                    )
                )
            }
        }

        if let primaryError {
            guard cleanupFailures.isEmpty else {
                let description = (primaryError as? LocalizedError)?.errorDescription
                    ?? primaryError.localizedDescription
                throw PublicProcessedMicrophoneDeviceError.rollbackFailed(
                    primaryErrorDescription: description,
                    cleanupFailures: cleanupFailures
                )
            }
            throw primaryError
        }
        guard cleanupFailures.isEmpty else {
            throw PublicProcessedMicrophoneDeviceError.cleanupFailed(cleanupFailures)
        }
    }

    private func cleanupLocked() -> CleanupOutcome {
        // Checked before anything is released, so a refusal leaves the
        // publication completely intact — including the in-use listener, which
        // is how the owner learns that the teardown can finally proceed.
        if
            aggregateDeviceID != kAudioObjectUnknown,
            Self.readIsRunningSomewhere(aggregateDeviceID)
        {
            return .refusedWhileInUse
        }

        currentPublishedDevice = nil
        removeInUseListenerLocked()
        var failures: [PublicProcessedMicrophoneCleanupFailure] = []
        var aggregateRemovalConfirmed = false

        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status == noErr || status == kAudioHardwareBadObjectError {
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
                aggregateRemovalConfirmed = true
            case .found:
                // The stable UID can outlive this instance's cached object ID
                // after a crash or Core Audio reset. Remove that aggregate and
                // wait for its actual disappearance before touching any tap.
                switch removeStalePublishedDeviceLocked() {
                case .completed:
                    aggregateRemovalConfirmed = true
                case .refusedWhileInUse:
                    return .refusedWhileInUse
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
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr || status == kAudioHardwareBadObjectError {
                tapID = AudioObjectID(kAudioObjectUnknown)
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

    private func audioProcessObjectID(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var requestedPID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                Self.systemObjectID,
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &requestedPID,
                &dataSize,
                &processObjectID
            ),
            operation: localized("Translating the PID to an audio process object")
        )
        guard processObjectID != kAudioObjectUnknown else {
            throw PublicProcessedMicrophoneDeviceError.audioProcessUnavailable(pid: pid)
        }
        return processObjectID
    }

    @available(macOS 14.2, *)
    private func readTapFormat(_ objectID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                &format
            ),
            operation: localized("Reading the processed microphone tap format")
        )
        return format
    }

    private func readCFString(
        from objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                &value
            ),
            operation: operation
        )
        guard let value else {
            throw PublicProcessedMicrophoneDeviceError.missingPropertyValue(
                operation: operation
            )
        }
        return value.takeRetainedValue() as String
    }

    private func inputStreamCount(of deviceID: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &dataSize
            ),
            operation: localized("Counting the processed microphone input streams")
        )
        return Int(dataSize) / MemoryLayout<AudioObjectID>.size
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
