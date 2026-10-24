import AudioLevelBarCore
import CoreAudio
import Darwin
import Foundation
@testable import AudioLevelBar

/// A `HALLifecycleCalls` that never reaches coreaudiod.
///
/// It records every lifecycle call in the order the code under test made it,
/// answers the reads with a non-Bluetooth device, and runs `onCall` inside
/// each call, on the caller's queue, after recording it and before returning.
/// A test uses `onCall` to advance a `LifecycleHoldGeneration` at a chosen
/// call, as a quiet window arming at that moment would, or to hold the
/// calling queue there.
final class FakeHALLifecycleCalls: HALLifecycleCalls, @unchecked Sendable {
    enum Call: Equatable {
        case createIOProc(AudioObjectID)
        case start(AudioObjectID)
        case stop(AudioObjectID)
        case destroyIOProc(AudioObjectID)
        case createProcessTap
        case createAggregate
        case destroyAggregate(AudioObjectID)
        case destroyProcessTap(AudioObjectID)
        case addPropertyListener(AudioObjectID)
        case removePropertyListener(AudioObjectID)
        /// A `kAudioDevicePropertyDeviceIsRunning` read.
        case readIsRunning(AudioObjectID)
        /// A `kAudioDevicePropertyDeviceIsRunningSomewhere` read.
        case readIsRunningSomewhere(AudioObjectID)

        /// Listener calls and reads are recorded, but most assertions are
        /// about the create, start, stop and destroy calls alone.
        var isListenerCall: Bool {
            switch self {
            case .addPropertyListener, .removePropertyListener, .readIsRunning, .readIsRunningSomewhere:
                return true
            default:
                return false
            }
        }
    }

    static let tapID: AudioObjectID = 300
    static let aggregateID: AudioObjectID = 400
    /// The processed microphone's public tap, which is not private, and its
    /// aggregate device, created under the published UID.
    static let publishedTapID: AudioObjectID = 710
    static let publishedAggregateID: AudioObjectID = 700
    static let defaultOutputID: AudioObjectID = 500
    static let builtInOutputID: AudioObjectID = 600

    /// A call, or a hal-lifecycle line handed to `noteLine`, in the order
    /// they happened.
    enum TimelineEntry: Equatable {
        case call(Call)
        case line(String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var recordedTimeline: [TimelineEntry] = []
    private var nextIOProc: UInt = 0x1000
    private var _onCall: ((Call) -> Void)?
    private var _startStatus: OSStatus = noErr
    private var _statuses: [StatusKey: OSStatus] = [:]
    private var _isRunning: (status: OSStatus, value: UInt32) = (noErr, 0)
    private var _isRunningSomewhere: (status: OSStatus, value: UInt32) = (noErr, 0)
    private var _devices: [(id: AudioObjectID, uid: String)] = []
    private var _deviceListStatus: OSStatus = noErr
    private var _inputStreamCount: (status: OSStatus, count: Int) = (noErr, 1)
    private var _transports: [AudioObjectID: AudioDeviceTransportInfo?] = [:]
    private var _createStatuses: [AudioObjectID: OSStatus] = [:]
    private var _startStatuses: [AudioObjectID: OSStatus] = [:]

    /// What the next IOProc create on `deviceID` returns, once; `noErr`
    /// unless set.
    func failNextCreateIOProc(on deviceID: AudioObjectID, with status: OSStatus) {
        withLock { _createStatuses[deviceID] = status }
    }

    /// What the next `start` on `deviceID` returns, once, instead of
    /// `startStatus`.
    func failNextStart(on deviceID: AudioObjectID, with status: OSStatus) {
        withLock { _startStatuses[deviceID] = status }
    }

    /// The calls whose status a test can override.
    enum StatusKey: Hashable {
        case createProcessTap
        case createAggregate
        case stop
        case destroyIOProc
        case destroyAggregate
        case destroyProcessTap
    }

    /// A read made immediately before a create or start. Reads are not
    /// recorded in `calls` or the timeline; `onRead` runs inside each, on the
    /// caller's queue, so a test can arm a window while the lifecycle queue
    /// is in the read, where a slow coreaudiod's latency lands.
    enum Read: Equatable {
        case transportInfo(AudioObjectID)
        case inputStreamFormat(AudioObjectID)
        case outputStreamFormat(AudioObjectID)
        case defaultInputDeviceID
        case defaultOutputDeviceID
        case processObjectID
        case tapUID(AudioObjectID)
        case tapFormat(AudioObjectID)
    }

    private var _onRead: ((Read) -> Void)?

    var onRead: ((Read) -> Void)? {
        get { withLock { _onRead } }
        set { withLock { _onRead = newValue } }
    }

    private func noteRead(_ read: Read) {
        let hook = withLock { _onRead }
        hook?(read)
    }

    /// What the call named by `key` returns; `noErr` unless set.
    func setStatus(_ status: OSStatus, for key: StatusKey) {
        withLock { _statuses[key] = status }
    }

    private func status(for key: StatusKey) -> OSStatus {
        withLock { _statuses[key] ?? noErr }
    }

    /// What `isRunning` reads; not running by default.
    var isRunningRead: (status: OSStatus, value: UInt32) {
        get { withLock { _isRunning } }
        set { withLock { _isRunning = newValue } }
    }

    /// What `isRunningSomewhere` reads; not running by default.
    var isRunningSomewhereRead: (status: OSStatus, value: UInt32) {
        get { withLock { _isRunningSomewhere } }
        set { withLock { _isRunningSomewhere = newValue } }
    }

    /// The devices `deviceIDList()` lists, with the UID `readDeviceUID` reads
    /// for each; none by default. A successful aggregate create adds its
    /// device under the UID its description names, and a successful
    /// aggregate destroy removes it.
    var listedDevices: [(id: AudioObjectID, uid: String)] {
        get { withLock { _devices } }
        set { withLock { _devices = newValue } }
    }

    /// The status `deviceIDList()` returns; with anything but `noErr` it lists
    /// nothing.
    var deviceListStatus: OSStatus {
        get { withLock { _deviceListStatus } }
        set { withLock { _deviceListStatus = newValue } }
    }

    /// What `inputStreamCount(of:)` reads; one stream by default.
    var inputStreamCountRead: (status: OSStatus, count: Int) {
        get { withLock { _inputStreamCount } }
        set { withLock { _inputStreamCount = newValue } }
    }

    /// What `transportInfo(for:)` reads for `deviceID`, nil for a failed
    /// read. A device with none set reads as built-in.
    func setTransportInfo(_ info: AudioDeviceTransportInfo?, for deviceID: AudioObjectID) {
        withLock { _transports[deviceID] = .some(info) }
    }
    private var _defaultOutputUID: String? = "output"
    private var _defaultOutputID: AudioObjectID = FakeHALLifecycleCalls.defaultOutputID
    private var _defaultInputID: AudioObjectID? = nil
    private var _listedOutputDevices: [AudioDevice]? = [
        AudioDevice(
            id: FakeHALLifecycleCalls.builtInOutputID,
            name: "Speakers",
            uid: "speakers",
            inputChannelCount: 0,
            outputChannelCount: 2,
            transport: .builtIn
        )
    ]

    /// What `outputDevices()` returns; nil reads as a failed list read. One
    /// built-in output by default.
    var listedOutputDevices: [AudioDevice]? {
        get { withLock { _listedOutputDevices } }
        set { withLock { _listedOutputDevices = newValue } }
    }
    /// Listener blocks added and not yet removed, in the order added.
    private var listeners: [(deviceID: AudioObjectID, selector: AudioObjectPropertySelector, block: AudioObjectPropertyListenerBlock)] = []

    /// The selectors of the listeners added on `deviceID` and not removed.
    func listenerSelectors(on deviceID: AudioObjectID) -> [AudioObjectPropertySelector] {
        withLock { listeners.filter { $0.deviceID == deviceID }.map(\.selector) }
    }

    /// Calls every listener added on `deviceID` for `selector`, on the
    /// calling queue, as the HAL would on the queue the listener named.
    func fireListener(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) {
        let blocks = withLock {
            listeners.filter { $0.deviceID == deviceID && $0.selector == selector }.map(\.block)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for block in blocks {
            withUnsafePointer(to: &address) { block(1, $0) }
        }
    }

    /// The UID the default output reads as; nil reads as a failed read.
    /// "output" by default, the UID the tests start the meter for.
    var defaultOutputUID: String? {
        get { withLock { _defaultOutputUID } }
        set { withLock { _defaultOutputUID = newValue } }
    }

    /// The device `defaultOutputDeviceID()` reads, the one whose UID is
    /// `defaultOutputUID`; `defaultOutputID` by default.
    var currentDefaultOutputID: AudioObjectID {
        get { withLock { _defaultOutputID } }
        set { withLock { _defaultOutputID = newValue } }
    }

    /// What `defaultInputDeviceID()` reads; nil by default.
    var currentDefaultInputID: AudioObjectID? {
        get { withLock { _defaultInputID } }
        set { withLock { _defaultInputID = newValue } }
    }

    var onCall: ((Call) -> Void)? {
        get { withLock { _onCall } }
        set { withLock { _onCall = newValue } }
    }

    /// What every `start` returns.
    var startStatus: OSStatus {
        get { withLock { _startStatus } }
        set { withLock { _startStatus = newValue } }
    }

    /// Every call, listeners included.
    var calls: [Call] {
        withLock { recorded }
    }

    /// The create, start, stop and destroy calls.
    var lifecycleCalls: [Call] {
        calls.filter { !$0.isListenerCall }
    }

    /// Every call and every line noted, interleaved in order.
    var timeline: [TimelineEntry] {
        withLock { recordedTimeline }
    }

    /// Adds a hal-lifecycle line to the timeline. A test passes this to
    /// `HALLifecycleLog.observer`, so that a line written on a lifecycle queue
    /// lands between the calls made on that queue.
    func noteLine(_ line: String) {
        withLock { recordedTimeline.append(.line(line)) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Records the call, then runs the hook outside the lock so that a hook
    /// that waits does not block a test reading `calls`.
    private func record(_ call: Call) {
        let hook = withLock { () -> ((Call) -> Void)? in
            recorded.append(call)
            recordedTimeline.append(.call(call))
            return _onCall
        }
        hook?(call)
    }

    private func makeIOProcID() -> AudioDeviceIOProcID {
        let value = withLock { () -> UInt in
            nextIOProc += 0x10
            return nextIOProc
        }
        // Never called; only compared and passed back.
        return unsafeBitCast(UnsafeRawPointer(bitPattern: value)!, to: AudioDeviceIOProcID.self)
    }

    func createIOProc(
        deviceID: AudioObjectID,
        queue: DispatchQueue?,
        block: @escaping AudioDeviceIOBlock
    ) -> (status: OSStatus, ioProcID: AudioDeviceIOProcID?) {
        let ioProcID = makeIOProcID()
        let status = withLock { _createStatuses.removeValue(forKey: deviceID) } ?? noErr
        record(.createIOProc(deviceID))
        return (status, status == noErr ? ioProcID : nil)
    }

    func start(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) -> OSStatus {
        let status = withLock { _startStatuses.removeValue(forKey: deviceID) } ?? startStatus
        record(.start(deviceID))
        return status
    }

    func stop(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) -> OSStatus {
        record(.stop(deviceID))
        return status(for: .stop)
    }

    func destroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) -> OSStatus {
        record(.destroyIOProc(deviceID))
        return status(for: .destroyIOProc)
    }

    func createProcessTap(_ description: CATapDescription) -> (status: OSStatus, tapID: AudioObjectID) {
        record(.createProcessTap)
        let status = status(for: .createProcessTap)
        let tapID = description.isPrivate ? Self.tapID : Self.publishedTapID
        return (status, status == noErr ? tapID : AudioObjectID(kAudioObjectUnknown))
    }

    func createAggregate(_ description: CFDictionary) -> (status: OSStatus, deviceID: AudioObjectID) {
        record(.createAggregate)
        let status = status(for: .createAggregate)
        guard status == noErr else {
            return (status, AudioObjectID(kAudioObjectUnknown))
        }
        let uid = (description as NSDictionary)[kAudioAggregateDeviceUIDKey] as? String ?? ""
        let deviceID = uid == PublicProcessedMicrophoneDevice.aggregateDeviceUID
            ? Self.publishedAggregateID
            : Self.aggregateID
        withLock { _devices.append((deviceID, uid)) }
        return (status, deviceID)
    }

    func destroyAggregate(_ deviceID: AudioObjectID) -> OSStatus {
        record(.destroyAggregate(deviceID))
        let status = status(for: .destroyAggregate)
        if status == noErr {
            withLock { _devices.removeAll { $0.id == deviceID } }
        }
        return status
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        record(.destroyProcessTap(tapID))
        return status(for: .destroyProcessTap)
    }

    func isRunningSomewhere(_ deviceID: AudioObjectID) -> (status: OSStatus, value: UInt32) {
        let read = isRunningSomewhereRead
        record(.readIsRunningSomewhere(deviceID))
        return read
    }

    func isRunning(_ deviceID: AudioObjectID) -> (status: OSStatus, value: UInt32) {
        let read = isRunningRead
        record(.readIsRunning(deviceID))
        return read
    }

    func addPropertyListener(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        withLock { listeners.append((deviceID, address.mSelector, block)) }
        record(.addPropertyListener(deviceID))
        return noErr
    }

    @discardableResult
    func removePropertyListener(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        withLock {
            if let index = listeners.firstIndex(where: {
                $0.deviceID == deviceID && $0.selector == address.mSelector
            }) {
                listeners.remove(at: index)
            }
        }
        record(.removePropertyListener(deviceID))
        return noErr
    }

    func transportInfo(for deviceID: AudioObjectID) -> AudioDeviceTransportInfo? {
        noteRead(.transportInfo(deviceID))
        let configured: AudioDeviceTransportInfo?? = withLock { _transports[deviceID] }
        switch configured {
        case let .some(info):
            return info
        case .none:
            return AudioDeviceTransportInfo(transport: .builtIn)
        }
    }

    func inputStreamFormat(for deviceID: AudioObjectID) -> DeviceStreamFormat? {
        noteRead(.inputStreamFormat(deviceID))
        return DeviceStreamFormat(sampleFormat: .float32, channelCount: 1, sampleRate: 48_000)
    }

    private var _outputStreamFormat: DeviceStreamFormat? = DeviceStreamFormat(
        sampleFormat: .float32,
        channelCount: 2,
        sampleRate: 48_000
    )

    /// What `outputStreamFormat(for:)` reads, for every device; nil reads as
    /// a device with no usable output format. Float32 stereo at 48 kHz by
    /// default.
    var outputStreamFormatRead: DeviceStreamFormat? {
        get { withLock { _outputStreamFormat } }
        set { withLock { _outputStreamFormat = newValue } }
    }

    private var _outputFormatReads: [AudioObjectID] = []

    /// The devices `outputStreamFormat(for:)` was read for, in order: one for
    /// each publisher start that got as far as its format read.
    var outputFormatReads: [AudioObjectID] {
        withLock { _outputFormatReads }
    }

    func outputStreamFormat(for deviceID: AudioObjectID) -> DeviceStreamFormat? {
        withLock { _outputFormatReads.append(deviceID) }
        noteRead(.outputStreamFormat(deviceID))
        return outputStreamFormatRead
    }

    func maximumBufferFrameSize(for deviceID: AudioObjectID) -> Int? {
        4_096
    }

    func tapUID(_ tapID: AudioObjectID) -> (status: OSStatus, uid: String?) {
        noteRead(.tapUID(tapID))
        return (noErr, "fake-tap")
    }

    func tapFormat(_ tapID: AudioObjectID) -> (status: OSStatus, format: AudioStreamBasicDescription) {
        noteRead(.tapFormat(tapID))
        var format = AudioStreamBasicDescription()
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        format.mBitsPerChannel = 32
        // The published tap is a mono mixdown.
        format.mChannelsPerFrame = tapID == Self.publishedTapID ? 1 : 2
        format.mSampleRate = 48_000
        return (noErr, format)
    }

    func processObjectID(for pid: pid_t) -> (status: OSStatus, objectID: AudioObjectID) {
        noteRead(.processObjectID)
        return (noErr, 77)
    }

    func defaultInputDeviceID() -> AudioObjectID? {
        noteRead(.defaultInputDeviceID)
        return currentDefaultInputID
    }

    func defaultOutputDeviceID() -> AudioObjectID? {
        noteRead(.defaultOutputDeviceID)
        return currentDefaultOutputID
    }

    func deviceUID(for deviceID: AudioObjectID) -> String? {
        deviceID == currentDefaultOutputID ? defaultOutputUID : nil
    }

    func outputDevices() -> [AudioDevice]? {
        listedOutputDevices
    }

    func deviceIDList() -> (status: OSStatus, deviceIDs: [AudioObjectID]) {
        withLock { _deviceListStatus == noErr ? (noErr, _devices.map(\.id)) : (_deviceListStatus, []) }
    }

    func readDeviceUID(_ deviceID: AudioObjectID) -> (status: OSStatus, uid: String?) {
        guard let uid = withLock({ _devices.first { $0.id == deviceID }?.uid }) else {
            return (kAudioHardwareBadObjectError, nil)
        }
        return (noErr, uid)
    }

    func inputStreamCount(of deviceID: AudioObjectID) -> (status: OSStatus, count: Int) {
        inputStreamCountRead
    }
}
