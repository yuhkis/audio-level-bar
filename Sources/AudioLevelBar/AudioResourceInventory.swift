import AudioLevelBarCore
import CoreAudio
import Foundation

/// Reads Core Audio's aggregate devices and process taps and attributes each
/// one to this app or to something else.
///
/// This exists because a leaked aggregate device or process tap is invisible in
/// the normal device list: an orphan looks like an ordinary input, and nothing
/// in the UI says who created it. Verifying that a cleanup sweep touches only
/// this app's objects requires being able to see all of them first.
enum AudioResourceInventory {
    /// Result of asking Core Audio one trivial question under a deadline.
    enum HALProbe {
        case responsive(TimeInterval)
        case unresponsive(TimeInterval)
        case failed(OSStatus)
    }

    struct AggregateDevice {
        let objectID: AudioObjectID
        let uid: String
        let name: String
        let ownership: AudioResourceOwnership
        let isRunningSomewhere: Bool
    }

    struct ProcessTap {
        let objectID: AudioObjectID
        let uid: String
        let name: String
        /// Nil when no bundle identifier of this app created the tap.
        let ownership: AudioResourceOwnership?
        /// Bundles Core Audio recorded as the tap's creators. Empty below
        /// macOS 26, where the property does not exist.
        let bundleIDs: [String]
        /// True when `ownership` came from the creating bundle rather than the
        /// tap's name. Only an authoritative attribution may justify destroying
        /// the tap.
        let attributionIsAuthoritative: Bool
        /// True when macOS restores this tap across reboots, which is why a
        /// leaked tap outlives the machine it was created on.
        let restoresAcrossReboot: Bool
        /// The processes the tap description points at.
        let targets: [Target]

        struct Target {
            let processObjectID: AudioObjectID
            /// Nil when Core Audio no longer has a process object under this
            /// ID, which by itself means the process is gone.
            let pid: pid_t?
            let isAlive: Bool
        }

        /// True when the tap names targets and none of them still exist.
        ///
        /// Audio can never flow through such a tap again, and nothing will
        /// remove it: taps outlive the process that created them, so this is a
        /// leak that persists until something destroys it explicitly or the
        /// machine reboots.
        var isStranded: Bool {
            !targets.isEmpty && targets.allSatisfy { !$0.isAlive }
        }
    }

    static let namespace = AudioResourceNamespace(
        publishedMicrophoneUID: PublicProcessedMicrophoneDevice.aggregateDeviceUID,
        legacyPublishedMicrophoneUIDs: PublicProcessedMicrophoneDevice
            .legacyAggregateDeviceUIDPrefixes
            .map { "\($0).public" },
        privateTapAggregateUIDPrefix: "io.github.yuhkis.audio-level-bar.tap.",
        publishedMicrophoneTapName: "Audio Level Bar Processed Microphone Tap",
        systemOutputMeterTapName: "Audio Level Bar System Output Meter",
        bundleIdentifiers: [AudioLevelBarIdentity.bundleIdentifier]
    )

    /// Asks the HAL for the device list size on a background thread and gives
    /// up after `timeout`.
    ///
    /// A wedged coreaudiod blocks the first HAL call of every process
    /// indefinitely, so a plain call here would hang the diagnostics too. The
    /// deadline turns that hang into a reportable state, which is the whole
    /// point: it separates "this app is broken" from "audio is broken machine
    /// wide", and only the second one requires a reboot.
    static func probeHAL(timeout: TimeInterval = 5) -> HALProbe {
        final class Outcome: @unchecked Sendable {
            var status: OSStatus = noErr
        }

        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)
        let start = DispatchTime.now()

        DispatchQueue.global(qos: .userInitiated).async {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            outcome.status = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size
            )
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        ) / 1_000_000_000

        switch waitResult {
        case .timedOut:
            // The worker thread is still blocked inside the HAL and will stay
            // that way. Nothing here can free it; the process should report and
            // exit rather than wait.
            return .unresponsive(elapsed)
        case .success:
            return outcome.status == noErr
                ? .responsive(elapsed)
                : .failed(outcome.status)
        }
    }

    static func aggregateDevices() -> [AggregateDevice] {
        allObjectIDs(selector: kAudioHardwarePropertyDevices).compactMap { deviceID in
            guard transportType(of: deviceID) == kAudioDeviceTransportTypeAggregate else {
                return nil
            }
            let uid = stringProperty(
                deviceID,
                selector: kAudioDevicePropertyDeviceUID
            ) ?? "(UID could not be read)"
            let name = stringProperty(
                deviceID,
                selector: kAudioObjectPropertyName
            ) ?? "(name could not be read)"
            return AggregateDevice(
                objectID: deviceID,
                uid: uid,
                name: name,
                ownership: AudioResourceClassifier.ownership(
                    ofAggregateUID: uid,
                    in: namespace
                ),
                isRunningSomewhere: isRunningSomewhere(deviceID)
            )
        }
    }

    @available(macOS 14.2, *)
    static func processTaps() -> [ProcessTap] {
        allObjectIDs(selector: kAudioHardwarePropertyTapList).map { tapID in
            let uid = stringProperty(
                tapID,
                selector: kAudioTapPropertyUID
            ) ?? "(UID could not be read)"
            let description = tapDescription(tapID)
            let name = description?.name ?? "(description could not be read)"

            // Core Audio only reports the creating bundle, and whether it
            // restores the tap across reboots, on macOS 26 and later. Below
            // that the name is the only signal, and it is not proof of
            // ownership.
            var bundleIDs: [String] = []
            var restoresAcrossReboot = false
            var isAuthoritative = false
            if #available(macOS 26.0, *), let description {
                bundleIDs = description.bundleIDs
                restoresAcrossReboot = description.isProcessRestoreEnabled
                isAuthoritative = true
            }

            let ownership = isAuthoritative
                ? AudioResourceClassifier.ownership(
                    ofTapWithBundleIDs: bundleIDs,
                    name: name,
                    in: namespace
                )
                : AudioResourceClassifier.provisionalOwnership(
                    ofTapName: name,
                    in: namespace
                )

            return ProcessTap(
                objectID: tapID,
                uid: uid,
                name: name,
                ownership: ownership,
                bundleIDs: bundleIDs,
                attributionIsAuthoritative: isAuthoritative,
                restoresAcrossReboot: restoresAcrossReboot,
                targets: targets(of: description)
            )
        }
    }

    @available(macOS 14.2, *)
    private static func targets(
        of description: CATapDescription?
    ) -> [ProcessTap.Target] {
        guard let description else {
            return []
        }
        return description.processes.map { processObject in
            guard let pid = processID(of: processObject) else {
                // Core Audio drops the process object when the process exits,
                // so an unresolvable ID is itself proof the target is gone.
                return ProcessTap.Target(
                    processObjectID: processObject,
                    pid: nil,
                    isAlive: false
                )
            }
            // kill(pid, 0) reports whether a process with this ID exists
            // without signalling it: 0 means it exists, EPERM means it exists
            // but belongs to someone else, ESRCH means it is gone.
            let isAlive = kill(pid, 0) == 0 || errno == EPERM
            return ProcessTap.Target(
                processObjectID: processObject,
                pid: pid,
                isAlive: isAlive
            )
        }
    }

    private static func processID(of processObject: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard
            AudioObjectGetPropertyData(
                processObject,
                &address,
                0,
                nil,
                &size,
                &pid
            ) == noErr
        else {
            return nil
        }
        return pid
    }

    private static func allObjectIDs(
        selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size
            ) == noErr,
            size > 0
        else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &objectIDs
            ) == noErr
        else {
            return []
        }
        return objectIDs
    }

    private static func transportType(of deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &value
            ) == noErr
        else {
            return nil
        }
        return value
    }

    private static func isRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &value
            ) == noErr
        else {
            return false
        }
        return value != 0
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else {
            return nil
        }
        return value as String
    }

    @available(macOS 14.2, *)
    private static func tapDescription(_ tapID: AudioObjectID) -> CATapDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description: CATapDescription?
        var size = UInt32(MemoryLayout<CATapDescription?>.size)
        let status = withUnsafeMutablePointer(to: &description) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            return nil
        }
        return description
    }
}
