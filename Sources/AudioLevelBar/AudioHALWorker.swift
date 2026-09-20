import AudioLevelBarCore
import CoreAudio
import Foundation

/// Reads the periodic Core Audio state on a serial queue and hands the result
/// back to the main thread as one immutable snapshot.
///
/// Every Core Audio read is an IPC round trip to coreaudiod, and a coreaudiod
/// that stops answering blocks its caller indefinitely. Run on the main run
/// loop, the 0.25 s refresh that keeps the meters live would therefore also be
/// the thing that can freeze the UI, the menu, and Quit. Freezing is what leads
/// a user to force quit, and force quitting while the processed microphone
/// holds HAL objects is what wedges Core Audio for every app on the machine.
/// Keeping these reads off the main thread breaks the first link in that chain.
///
/// Values crossing between the queue and main are immutable value types. Swift
/// 5 language mode checks none of this, so it is a discipline rather than a
/// compiler guarantee: nothing here may gain a reference type or a mutable
/// field without revisiting that.
/// The Core Audio reads and writes `AudioHALWorker` makes, so that a test can
/// substitute a fake that never reaches coreaudiod. `CoreAudioSystem` is the
/// production conformance; each requirement is its method of the same name.
protocol AudioHALWorkerSystem: AnyObject {
    func defaultDevice(for direction: AudioDirection) -> AudioDeviceID?
    func devices(for direction: AudioDirection) -> [AudioDevice]
    func deviceIDs() -> [AudioDeviceID]?
    func transport(for deviceID: AudioDeviceID) -> AudioDeviceTransport?
    func transportInfo(
        for deviceID: AudioDeviceID,
        transportOf: (AudioDeviceID) -> AudioDeviceTransport?
    ) -> AudioDeviceTransportInfo?
    func deviceUID(for deviceID: AudioDeviceID) -> String?
    func controls(for deviceID: AudioDeviceID, direction: AudioDirection) -> AudioControlSnapshot
    func forgetControlLayoutCache()
    @discardableResult
    func setDefaultDevice(_ deviceID: AudioDeviceID, for direction: AudioDirection) -> OSStatus
    @discardableResult
    func setVolume(_ volume: Float, deviceID: AudioDeviceID, direction: AudioDirection) -> OSStatus
    @discardableResult
    func setMuted(_ muted: Bool, deviceID: AudioDeviceID, direction: AudioDirection) -> OSStatus
}

extension CoreAudioSystem: AudioHALWorkerSystem {}

final class AudioHALWorker {
    struct Request {
        /// What main currently shows. The worker re-reads the defaults and
        /// compares against these, so a change is detected on the queue and the
        /// matching device lists can be read in the same turn.
        let knownOutputDeviceID: AudioDeviceID
        let knownInputDeviceID: AudioDeviceID
        /// True on the slow cadence, when the lists are refreshed even without
        /// a default-device change.
        let wantsDeviceLists: Bool
        /// Value of the caller's write counter when this poll was issued,
        /// echoed back in the snapshot so a result read before a local write
        /// can be told apart from one read after it.
        let controlWriteEpoch: UInt64
        /// When the caller issued this poll, on its lifecycle clock. Echoed
        /// back so the caller can tell whether a result was read after a
        /// moment it cares about, such as the end of a quiet window.
        let issuedAt: TimeInterval
    }

    struct DeviceLists {
        let output: [AudioDevice]
        /// Already filtered of this app's own published aggregate. The filter
        /// is a pure string test, which is why it is safe to run off main.
        let input: [AudioDevice]
    }

    struct Snapshot {
        let outputDeviceID: AudioDeviceID
        let inputDeviceID: AudioDeviceID
        /// Transport of `inputDeviceID` and, for an aggregate, of its active
        /// sub-devices. nil while no input device exists or its transport could
        /// not be read. Read with the ID in the same turn, so the two always
        /// describe the same device.
        let inputTransportInfo: AudioDeviceTransportInfo?
        /// The same for `outputDeviceID`.
        let outputTransportInfo: AudioDeviceTransportInfo?
        /// Whether `inputDeviceID` is this app's own published processed
        /// microphone, which the meter must never open. nil when there is no
        /// input device or its UID could not be read.
        let inputIsProcessedMicrophone: Bool?
        /// Every Bluetooth or Bluetooth LE device present. A change in this set
        /// is a Bluetooth device connecting or disconnecting.
        let bluetoothDeviceIDs: Set<AudioDeviceID>
        /// Whether this read listed the devices and every listed device has
        /// a transport read. When false, a Bluetooth device whose transport
        /// could not be read may be connected without being in
        /// `bluetoothDeviceIDs`.
        let everyDeviceTransportRead: Bool
        /// Non-nil when the defaults changed, or when the slow cadence asked
        /// for them. Publishing lists together with the IDs they contain is
        /// what keeps the device pickers from briefly holding a selection that
        /// is not in their list.
        let deviceLists: DeviceLists?
        /// Always read for the device IDs in this same snapshot, never for
        /// whatever main happened to be showing.
        let outputControls: AudioControlSnapshot?
        let inputControls: AudioControlSnapshot?
        /// Echoed from the request. See `Request.controlWriteEpoch`.
        let controlWriteEpoch: UInt64
        /// Echoed from the request. See `Request.issuedAt`.
        let issuedAt: TimeInterval
    }

    /// The outcome of a write plus the controls read back afterwards.
    ///
    /// The read-back rides along because a write and its verification have to
    /// be one queue turn. Mute has no other source of truth: the button's
    /// visible state comes from reading the device back, not from what was
    /// requested, so splitting them would let a poll land in between and show
    /// the pre-write value.
    struct WriteResult {
        let accepted: Bool
        let controls: AudioControlSnapshot?
    }

    private let audioSystem: any AudioHALWorkerSystem
    /// Internal so a test can wait for it.
    let queue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.hal",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    /// Guarded by `stateLock`. The poll in flight, and whether it has been
    /// noted slow.
    private var pollWatch = HALPollWatch()
    /// Read only for the log lines' `gen=`.
    private let holdGeneration: LifecycleHoldGeneration
    /// The lifecycle clock the requests' `issuedAt` is on.
    private let now: () -> TimeInterval
    /// Which device and direction a volume write is for.
    private struct VolumeTarget: Hashable {
        let deviceID: AudioDeviceID
        let direction: AudioDirection
    }

    /// Guarded by `stateLock`. The latest requested volume per device and
    /// direction, read by the work item at execution time rather than
    /// captured when it was enqueued, with the ticket of the request that set
    /// it. Keyed by device as well as direction, so that a backlog queued for
    /// one device never writes a value meant for another: the default device
    /// can change, and its slider be dragged, while writes for the previous
    /// one still wait on the queue.
    private var requestedVolume: [VolumeTarget: (volume: Float, ticket: UInt64)] = [:]
    /// Guarded by `stateLock`.
    private var lastVolumeTicket: UInt64 = 0

    /// Queue-confined. The transport of every listed device, read once per
    /// device ID; see `DeviceTransportCache`. The meter does not rely on this
    /// cache: it re-reads the exact device before opening it.
    private var transportCache = DeviceTransportCache()
    /// Queue-confined. The last input device whose ownership was read, so the
    /// UID is read once per default input rather than once per poll.
    private var processedMicrophoneOwnership: (deviceID: AudioDeviceID, owned: Bool)?

    /// - Parameter now: The owner's lifecycle clock, the one `Request.issuedAt`
    ///   is on. No default: a second clock would let the poll watch subtract
    ///   times read from two clocks.
    init(
        audioSystem: any AudioHALWorkerSystem,
        holdGeneration: LifecycleHoldGeneration,
        now: @escaping () -> TimeInterval
    ) {
        self.audioSystem = audioSystem
        self.holdGeneration = holdGeneration
        self.now = now
    }

    /// Whether a poll has been issued and has not returned to the main thread
    /// yet.
    var isPollInFlight: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pollWatch.isInFlight
    }

    /// Enqueues one poll, or drops it when the previous one has not returned.
    ///
    /// A repeating `Timer` throttles itself: a fire date that passes while the
    /// run loop is blocked fires once on catch-up rather than queueing every
    /// missed tick. A queue coalesces nothing, so without this flag a slow HAL
    /// would let ticks pile up and keep issuing reads long after it recovered.
    ///
    /// The flag is tested here, before `async`, rather than inside the work
    /// item — `DispatchQueue.async` never blocks the caller, so a check on the
    /// queue would happily let the backlog form first.
    ///
    /// A tick dropped more than `HALPollWatch.slowAfter` after the poll in
    /// flight was issued writes `hal-poll slow`, once per poll, and such a
    /// poll writes `hal-poll recovered` immediately before its result is
    /// applied. The request's `issuedAt` is the time of the tick. A dropped
    /// request that asked for the device lists is remembered; see
    /// `takeOwedDeviceLists()`.
    ///
    /// - Returns: What became of the poll: issued, dropped, or dropped while
    ///   the poll in flight was noted slow, which the owner holds the quiet
    ///   window for.
    @discardableResult
    func poll(
        _ request: Request,
        completion: @escaping (Snapshot) -> Void
    ) -> HALPollWatch.Issue {
        stateLock.lock()
        let issue = pollWatch.issue(at: request.issuedAt, wantsDeviceLists: request.wantsDeviceLists)
        stateLock.unlock()
        switch issue {
        case .issued:
            break
        case .dropped:
            return issue
        case let .droppedWhileSlow(issuedAgo):
            HALLifecycleLog.pollSlow(issuedAgo: issuedAgo, generation: holdGeneration.current)
            return issue
        }

        queue.async { [self] in
            let snapshot = read(request)
            DispatchQueue.main.async {
                self.stateLock.lock()
                let slowElapsed = self.pollWatch.returned(at: self.now())
                self.stateLock.unlock()
                if let slowElapsed {
                    HALLifecycleLog.pollRecovered(
                        elapsed: slowElapsed,
                        generation: self.holdGeneration.current
                    )
                }
                completion(snapshot)
            }
        }
        return issue
    }

    /// Main thread. Whether a poll that asked for the device lists was
    /// dropped since the last one that carried them, clearing it. The owner
    /// issues a poll with the lists when this is true.
    func takeOwedDeviceLists() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pollWatch.takeOwedDeviceLists()
    }

    /// coreaudiod restarted, and device IDs may have been reissued. Drops what
    /// the worker cached by ID, on its queue, so the next poll reads every
    /// transport, the input's ownership and the control layouts afresh.
    func forgetCachesAfterServiceRestart() {
        queue.async { [self] in
            transportCache = DeviceTransportCache()
            processedMicrophoneOwnership = nil
            audioSystem.forgetControlLayoutCache()
        }
    }

    func setDefaultDevice(
        _ deviceID: AudioDeviceID,
        direction: AudioDirection,
        completion: @escaping (WriteResult) -> Void
    ) {
        let queuedAt = now()
        queue.async { [self] in
            let startedAt = now()
            let status = audioSystem.setDefaultDevice(deviceID, for: direction)
            logControlWrite(
                .defaultDevice,
                deviceID: deviceID,
                direction: direction,
                status: status,
                queuedAt: queuedAt,
                startedAt: startedAt
            )
            // Read back the device that is actually current now, which is the
            // requested one on success and the previous one on rejection.
            let currentID = audioSystem.defaultDevice(for: direction)
                ?? AudioDeviceID(kAudioObjectUnknown)
            let controls = currentID == kAudioObjectUnknown
                ? nil
                : audioSystem.controls(for: currentID, direction: direction)
            DispatchQueue.main.async {
                completion(WriteResult(accepted: status == noErr, controls: controls))
            }
        }
    }

    /// Writes the most recently requested volume for this device and
    /// direction.
    ///
    /// A drag emits a write per mouse sample. Each work item reads the latest
    /// request for its own device at execution time instead of the value
    /// captured when it was enqueued, so a backlog collapses to repeated
    /// writes of that device's final value rather than replaying a stale sweep
    /// after the HAL recovers. The entry is dropped once the item that carried
    /// the latest request has written it.
    func setVolume(
        _ volume: Float,
        deviceID: AudioDeviceID,
        direction: AudioDirection,
        completion: @escaping (WriteResult) -> Void
    ) {
        let key = VolumeTarget(deviceID: deviceID, direction: direction)
        stateLock.lock()
        lastVolumeTicket &+= 1
        let ticket = lastVolumeTicket
        requestedVolume[key] = (volume, ticket)
        stateLock.unlock()

        let queuedAt = now()
        queue.async { [self] in
            stateLock.lock()
            let target = requestedVolume[key]?.volume ?? volume
            stateLock.unlock()

            let startedAt = now()
            let status = audioSystem.setVolume(
                target,
                deviceID: deviceID,
                direction: direction
            )
            logControlWrite(
                .volume,
                deviceID: deviceID,
                direction: direction,
                status: status,
                queuedAt: queuedAt,
                startedAt: startedAt
            )
            stateLock.lock()
            if requestedVolume[key]?.ticket == ticket {
                requestedVolume[key] = nil
            }
            stateLock.unlock()
            let controls = audioSystem.controls(for: deviceID, direction: direction)
            DispatchQueue.main.async {
                completion(WriteResult(accepted: status == noErr, controls: controls))
            }
        }
    }

    func setMuted(
        _ muted: Bool,
        deviceID: AudioDeviceID,
        direction: AudioDirection,
        completion: @escaping (WriteResult) -> Void
    ) {
        let queuedAt = now()
        queue.async { [self] in
            let startedAt = now()
            let status = audioSystem.setMuted(
                muted,
                deviceID: deviceID,
                direction: direction
            )
            logControlWrite(
                .mute,
                deviceID: deviceID,
                direction: direction,
                status: status,
                queuedAt: queuedAt,
                startedAt: startedAt
            )
            let controls = audioSystem.controls(for: deviceID, direction: direction)
            DispatchQueue.main.async {
                completion(WriteResult(accepted: status == noErr, controls: controls))
            }
        }
    }

    /// Runs only on `queue`, immediately after a control write returned.
    /// The transport comes from what the worker has already read, so the
    /// line costs no HAL call.
    private func logControlWrite(
        _ kind: HALLifecycleLog.ControlWrite,
        deviceID: AudioDeviceID,
        direction: AudioDirection,
        status: OSStatus,
        queuedAt: TimeInterval,
        startedAt: TimeInterval
    ) {
        HALLifecycleLog.controlWrite(
            kind,
            id: deviceID,
            direction: direction == .input ? "input" : "output",
            transport: transportCache[deviceID]?.logName ?? "unread",
            status: status,
            queued: startedAt - queuedAt,
            elapsed: now() - startedAt,
            generation: holdGeneration.current
        )
    }

    private func read(_ request: Request) -> Snapshot {
        let outputDeviceID = audioSystem.defaultDevice(for: .output)
            ?? AudioDeviceID(kAudioObjectUnknown)
        let inputDeviceID = audioSystem.defaultDevice(for: .input)
            ?? AudioDeviceID(kAudioObjectUnknown)

        let defaultsChanged = outputDeviceID != request.knownOutputDeviceID
            || inputDeviceID != request.knownInputDeviceID

        let deviceLists: DeviceLists?
        if request.wantsDeviceLists || defaultsChanged {
            deviceLists = DeviceLists(
                output: audioSystem.devices(for: .output),
                input: audioSystem.devices(for: .input).filter {
                    !PublicProcessedMicrophoneDevice.ownsAggregateDeviceUID($0.uid)
                }
            )
        } else {
            deviceLists = nil
        }

        // A failed list read (nil) keeps the cache as it was.
        let deviceIDs = audioSystem.deviceIDs()
        transportCache.update(listing: deviceIDs) { audioSystem.transport(for: $0) }
        if
            let deviceIDs,
            let ownership = processedMicrophoneOwnership,
            !deviceIDs.contains(ownership.deviceID)
        {
            processedMicrophoneOwnership = nil
        }
        let bluetoothDeviceIDs = transportCache.bluetoothDeviceIDs
        let everyDeviceTransportRead = deviceIDs.map { listed in
            listed.allSatisfy { transportCache[$0] != nil }
        } ?? false

        return Snapshot(
            outputDeviceID: outputDeviceID,
            inputDeviceID: inputDeviceID,
            inputTransportInfo: audioSystem.transportInfo(
                for: inputDeviceID,
                transportOf: cachedTransport
            ),
            outputTransportInfo: audioSystem.transportInfo(
                for: outputDeviceID,
                transportOf: cachedTransport
            ),
            inputIsProcessedMicrophone: processedMicrophoneOwnership(of: inputDeviceID),
            bluetoothDeviceIDs: bluetoothDeviceIDs,
            everyDeviceTransportRead: everyDeviceTransportRead,
            deviceLists: deviceLists,
            outputControls: outputDeviceID == kAudioObjectUnknown
                ? nil
                : audioSystem.controls(for: outputDeviceID, direction: .output),
            inputControls: inputDeviceID == kAudioObjectUnknown
                ? nil
                : audioSystem.controls(for: inputDeviceID, direction: .input),
            controlWriteEpoch: request.controlWriteEpoch,
            issuedAt: request.issuedAt
        )
    }

    /// Runs only on `queue`.
    private func cachedTransport(_ deviceID: AudioDeviceID) -> AudioDeviceTransport? {
        transportCache[deviceID] ?? audioSystem.transport(for: deviceID)
    }

    /// Runs only on `queue`.
    private func processedMicrophoneOwnership(of deviceID: AudioDeviceID) -> Bool? {
        guard deviceID != kAudioObjectUnknown else {
            return nil
        }
        if
            let ownership = processedMicrophoneOwnership,
            ownership.deviceID == deviceID
        {
            return ownership.owned
        }
        guard let uid = audioSystem.deviceUID(for: deviceID) else {
            return nil
        }
        let owned = PublicProcessedMicrophoneDevice.ownsAggregateDeviceUID(uid)
        processedMicrophoneOwnership = (deviceID, owned)
        return owned
    }
}
