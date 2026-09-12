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
        /// Transport of `inputDeviceID`, nil while no input device exists.
        /// Read every poll so the Bluetooth pause reacts to a device change
        /// on the next tick instead of waiting for a list refresh.
        let inputTransport: AudioDeviceTransport?
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

    private let audioSystem: CoreAudioSystem
    private let queue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.hal",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var isPollInFlight = false
    /// Latest requested volume per direction, read by the work item at
    /// execution time rather than captured when it was enqueued.
    private var requestedVolume: [AudioDirection: Float] = [:]

    init(audioSystem: CoreAudioSystem) {
        self.audioSystem = audioSystem
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
    /// - Returns: false when the poll was dropped.
    @discardableResult
    func poll(
        _ request: Request,
        completion: @escaping (Snapshot) -> Void
    ) -> Bool {
        stateLock.lock()
        guard !isPollInFlight else {
            stateLock.unlock()
            return false
        }
        isPollInFlight = true
        stateLock.unlock()

        queue.async { [self] in
            let snapshot = read(request)
            DispatchQueue.main.async {
                self.stateLock.lock()
                self.isPollInFlight = false
                self.stateLock.unlock()
                completion(snapshot)
            }
        }
        return true
    }

    func setDefaultDevice(
        _ deviceID: AudioDeviceID,
        direction: AudioDirection,
        completion: @escaping (WriteResult) -> Void
    ) {
        queue.async { [self] in
            let accepted = audioSystem.setDefaultDevice(deviceID, for: direction)
            // Read back the device that is actually current now, which is the
            // requested one on success and the previous one on rejection.
            let currentID = audioSystem.defaultDevice(for: direction)
                ?? AudioDeviceID(kAudioObjectUnknown)
            let controls = currentID == kAudioObjectUnknown
                ? nil
                : audioSystem.controls(for: currentID, direction: direction)
            DispatchQueue.main.async {
                completion(WriteResult(accepted: accepted, controls: controls))
            }
        }
    }

    /// Writes the most recently requested volume for this direction.
    ///
    /// A drag emits a write per mouse sample. Each work item reads the latest
    /// request at execution time instead of the value captured when it was
    /// enqueued, so a backlog collapses to repeated writes of the final value
    /// rather than replaying a stale sweep after the HAL recovers.
    func setVolume(
        _ volume: Float,
        deviceID: AudioDeviceID,
        direction: AudioDirection,
        completion: @escaping (WriteResult) -> Void
    ) {
        stateLock.lock()
        requestedVolume[direction] = volume
        stateLock.unlock()

        queue.async { [self] in
            stateLock.lock()
            let target = requestedVolume[direction] ?? volume
            stateLock.unlock()

            let accepted = audioSystem.setVolume(
                target,
                deviceID: deviceID,
                direction: direction
            )
            let controls = audioSystem.controls(for: deviceID, direction: direction)
            DispatchQueue.main.async {
                completion(WriteResult(accepted: accepted, controls: controls))
            }
        }
    }

    func setMuted(
        _ muted: Bool,
        deviceID: AudioDeviceID,
        direction: AudioDirection,
        completion: @escaping (WriteResult) -> Void
    ) {
        queue.async { [self] in
            let accepted = audioSystem.setMuted(
                muted,
                deviceID: deviceID,
                direction: direction
            )
            let controls = audioSystem.controls(for: deviceID, direction: direction)
            DispatchQueue.main.async {
                completion(WriteResult(accepted: accepted, controls: controls))
            }
        }
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

        return Snapshot(
            outputDeviceID: outputDeviceID,
            inputDeviceID: inputDeviceID,
            inputTransport: inputDeviceID == kAudioObjectUnknown
                ? nil
                : audioSystem.transport(for: inputDeviceID),
            deviceLists: deviceLists,
            outputControls: outputDeviceID == kAudioObjectUnknown
                ? nil
                : audioSystem.controls(for: outputDeviceID, direction: .output),
            inputControls: inputDeviceID == kAudioObjectUnknown
                ? nil
                : audioSystem.controls(for: inputDeviceID, direction: .input),
            controlWriteEpoch: request.controlWriteEpoch
        )
    }
}
