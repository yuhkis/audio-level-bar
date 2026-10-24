import AudioLevelBarCore
import CoreAudio
import Darwin
import Foundation

/// The Core Audio calls that create, start, stop and destroy the app's
/// IOProcs, process taps and aggregate devices, and the reads made
/// immediately before them.
///
/// A thin seam and nothing more. `CoreAudioHALLifecycleCalls` forwards each
/// requirement to the one Core Audio function, or `CoreAudioSystem` read, it
/// names, with the arguments unchanged, and returns what that call returned.
/// Nothing here checks the quiet window, orders calls, retries or interprets
/// a status: that stays with the caller. The seam exists so that a test can
/// substitute a fake that records the calls, never reaches coreaudiod, and
/// advances the quiet window's generation at a chosen call.
///
/// Every requirement may be called from any lifecycle queue, and from the
/// main thread where the caller already did so.
///
/// `PublicProcessedMicrophoneDevice` makes every Core Audio call through this
/// seam, its device lookups by UID and input stream count included, so a test
/// that publishes through a fake never reaches coreaudiod.
protocol HALLifecycleCalls {
    // MARK: IOProcs

    /// `AudioDeviceCreateIOProcIDWithBlock`.
    func createIOProc(
        deviceID: AudioObjectID,
        queue: DispatchQueue?,
        block: @escaping AudioDeviceIOBlock
    ) -> (status: OSStatus, ioProcID: AudioDeviceIOProcID?)

    /// `AudioDeviceStart`.
    func start(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) -> OSStatus

    /// `AudioDeviceStop`.
    func stop(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) -> OSStatus

    /// `AudioDeviceDestroyIOProcID`.
    func destroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) -> OSStatus

    // MARK: Process taps and aggregate devices

    /// `AudioHardwareCreateProcessTap`.
    func createProcessTap(_ description: CATapDescription) -> (status: OSStatus, tapID: AudioObjectID)

    /// `AudioHardwareCreateAggregateDevice`.
    func createAggregate(_ description: CFDictionary) -> (status: OSStatus, deviceID: AudioObjectID)

    /// `AudioHardwareDestroyAggregateDevice`.
    func destroyAggregate(_ deviceID: AudioObjectID) -> OSStatus

    /// `AudioHardwareDestroyProcessTap`.
    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus

    /// `kAudioDevicePropertyDeviceIsRunningSomewhere`, read with
    /// `AudioObjectGetPropertyData`: the status and the value as read.
    func isRunningSomewhere(_ deviceID: AudioObjectID) -> (status: OSStatus, value: UInt32)

    /// `kAudioDevicePropertyDeviceIsRunning`, read with
    /// `AudioObjectGetPropertyData`: the status and the value as read.
    func isRunning(_ deviceID: AudioObjectID) -> (status: OSStatus, value: UInt32)

    // MARK: Listeners on an opened device

    /// `AudioObjectAddPropertyListenerBlock`.
    func addPropertyListener(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    /// `AudioObjectRemovePropertyListenerBlock`.
    @discardableResult
    func removePropertyListener(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus

    // MARK: Reads made immediately before a create or start

    /// `CoreAudioSystem.transportInfo(for:)`, uncached.
    func transportInfo(for deviceID: AudioObjectID) -> AudioDeviceTransportInfo?

    /// `CoreAudioSystem.inputStreamFormat(for:)`.
    func inputStreamFormat(for deviceID: AudioObjectID) -> DeviceStreamFormat?

    /// `CoreAudioSystem.outputStreamFormat(for:)`.
    func outputStreamFormat(for deviceID: AudioObjectID) -> DeviceStreamFormat?

    /// `CoreAudioSystem.maximumBufferFrameSize(for:)`.
    func maximumBufferFrameSize(for deviceID: AudioObjectID) -> Int?

    /// `kAudioTapPropertyUID`: the status and the UID as read.
    func tapUID(_ tapID: AudioObjectID) -> (status: OSStatus, uid: String?)

    /// `kAudioTapPropertyFormat`: the status and the format as read.
    func tapFormat(_ tapID: AudioObjectID) -> (status: OSStatus, format: AudioStreamBasicDescription)

    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`: the status and
    /// the process object as read.
    func processObjectID(for pid: pid_t) -> (status: OSStatus, objectID: AudioObjectID)

    /// `CoreAudioSystem.defaultDevice(for: .input)`, uncached.
    func defaultInputDeviceID() -> AudioObjectID?

    /// `CoreAudioSystem.defaultDevice(for: .output)`, uncached.
    func defaultOutputDeviceID() -> AudioObjectID?

    /// `CoreAudioSystem.deviceUID(for:)`, uncached.
    func deviceUID(for deviceID: AudioObjectID) -> String?

    /// `CoreAudioSystem.listedDevices(for: .output)`, uncached: every device
    /// that can be the default output, with its transport, or nil when the
    /// device list could not be read.
    func outputDevices() -> [AudioDevice]?

    // MARK: The published device's lookups

    /// `kAudioHardwarePropertyDevices` on the system object, read with
    /// `AudioObjectGetPropertyDataSize` and then `AudioObjectGetPropertyData`:
    /// the status of the read that failed, or `noErr` with the IDs as read.
    /// A size too small for one ID reads as `noErr` and no IDs.
    func deviceIDList() -> (status: OSStatus, deviceIDs: [AudioObjectID])

    /// `kAudioDevicePropertyDeviceUID`, read with `AudioObjectGetPropertyData`:
    /// the status and the UID as read. A read that returned `noErr` and no
    /// value reads as `kAudioHardwareUnspecifiedError`.
    func readDeviceUID(_ deviceID: AudioObjectID) -> (status: OSStatus, uid: String?)

    /// The number of `kAudioDevicePropertyStreams` in the input scope, from
    /// `AudioObjectGetPropertyDataSize`: the status and the count as read.
    func inputStreamCount(of deviceID: AudioObjectID) -> (status: OSStatus, count: Int)
}

/// The production `HALLifecycleCalls`: each requirement is the Core Audio
/// call it names.
struct CoreAudioHALLifecycleCalls: HALLifecycleCalls {
    private let audioSystem: CoreAudioSystem

    init(audioSystem: CoreAudioSystem) {
        self.audioSystem = audioSystem
    }

    func createIOProc(
        deviceID: AudioObjectID,
        queue: DispatchQueue?,
        block: @escaping AudioDeviceIOBlock
    ) -> (status: OSStatus, ioProcID: AudioDeviceIOProcID?) {
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, queue, block)
        return (status, ioProcID)
    }

    func start(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStart(deviceID, ioProcID)
    }

    func stop(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStop(deviceID, ioProcID)
    }

    func destroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
    }

    func createProcessTap(_ description: CATapDescription) -> (status: OSStatus, tapID: AudioObjectID) {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        return (status, tapID)
    }

    func createAggregate(_ description: CFDictionary) -> (status: OSStatus, deviceID: AudioObjectID) {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description, &deviceID)
        return (status, deviceID)
    }

    func destroyAggregate(_ deviceID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(tapID)
    }

    func isRunningSomewhere(_ deviceID: AudioObjectID) -> (status: OSStatus, value: UInt32) {
        readUInt32(kAudioDevicePropertyDeviceIsRunningSomewhere, of: deviceID)
    }

    func isRunning(_ deviceID: AudioObjectID) -> (status: OSStatus, value: UInt32) {
        readUInt32(kAudioDevicePropertyDeviceIsRunning, of: deviceID)
    }

    private func readUInt32(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioObjectID
    ) -> (status: OSStatus, value: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
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
        return (status, value)
    }

    func addPropertyListener(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var address = address
        return AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
    }

    @discardableResult
    func removePropertyListener(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var address = address
        return AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
    }

    func transportInfo(for deviceID: AudioObjectID) -> AudioDeviceTransportInfo? {
        audioSystem.transportInfo(for: deviceID)
    }

    func inputStreamFormat(for deviceID: AudioObjectID) -> DeviceStreamFormat? {
        audioSystem.inputStreamFormat(for: deviceID)
    }

    func outputStreamFormat(for deviceID: AudioObjectID) -> DeviceStreamFormat? {
        audioSystem.outputStreamFormat(for: deviceID)
    }

    func maximumBufferFrameSize(for deviceID: AudioObjectID) -> Int? {
        audioSystem.maximumBufferFrameSize(for: deviceID)
    }

    func tapUID(_ tapID: AudioObjectID) -> (status: OSStatus, uid: String?) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else {
            return (status, nil)
        }
        return (status, value.takeRetainedValue() as String)
    }

    func tapFormat(_ tapID: AudioObjectID) -> (status: OSStatus, format: AudioStreamBasicDescription) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        return (status, format)
    }

    func processObjectID(for pid: pid_t) -> (status: OSStatus, objectID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var requestedPID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &requestedPID,
            &size,
            &objectID
        )
        return (status, objectID)
    }

    func defaultInputDeviceID() -> AudioObjectID? {
        audioSystem.defaultDevice(for: .input)
    }

    func defaultOutputDeviceID() -> AudioObjectID? {
        audioSystem.defaultDevice(for: .output)
    }

    func deviceUID(for deviceID: AudioObjectID) -> String? {
        audioSystem.deviceUID(for: deviceID)
    }

    func outputDevices() -> [AudioDevice]? {
        audioSystem.listedDevices(for: .output)
    }

    func deviceIDList() -> (status: OSStatus, deviceIDs: [AudioObjectID]) {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            systemObjectID,
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else {
            return (sizeStatus, [])
        }
        guard dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return (noErr, [])
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                systemObjectID,
                &address,
                0,
                nil,
                &dataSize,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            return (status, [])
        }
        return (noErr, deviceIDs)
    }

    func readDeviceUID(_ deviceID: AudioObjectID) -> (status: OSStatus, uid: String?) {
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
            return (status, nil)
        }
        guard let value else {
            return (kAudioHardwareUnspecifiedError, nil)
        }
        return (noErr, value.takeRetainedValue() as String)
    }

    func inputStreamCount(of deviceID: AudioObjectID) -> (status: OSStatus, count: Int) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )
        return (status, Int(dataSize) / MemoryLayout<AudioObjectID>.size)
    }
}
