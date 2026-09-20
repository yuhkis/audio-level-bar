import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// The HAL worker's control writes and polls, through a fake that never
/// reaches coreaudiod.
final class AudioHALWorkerTests: XCTestCase {
    private let timeout: TimeInterval = 5

    override func tearDown() {
        HALLifecycleLog.observer = nil
        super.tearDown()
    }

    func testQueuedWritesForADeviceNeverReceiveAnotherDevicesValue() {
        let system = BlockingAudioSystem()
        system.blocksFirstVolumeWrite = true
        let worker = AudioHALWorker(audioSystem: system, holdGeneration: LifecycleHoldGeneration(), now: { 0 })
        let speakers: AudioDeviceID = 51
        let headset: AudioDeviceID = 52
        let written = expectation(description: "every write completed")
        written.expectedFulfillmentCount = 4

        // The first write holds the queue, as a slow HAL call would.
        worker.setVolume(0.1, deviceID: speakers, direction: .output) { _ in written.fulfill() }
        XCTAssertEqual(system.firstVolumeWriteStarted.wait(timeout: .now() + timeout), .success)
        worker.setVolume(0.2, deviceID: speakers, direction: .output) { _ in written.fulfill() }
        worker.setVolume(0.3, deviceID: speakers, direction: .output) { _ in written.fulfill() }
        // The default output moves and its slider is dragged while the
        // speakers' writes still wait.
        worker.setVolume(0.9, deviceID: headset, direction: .output) { _ in written.fulfill() }
        system.releaseFirstVolumeWrite.signal()
        wait(for: [written], timeout: timeout)

        let writes = system.volumeWrites
        XCTAssertEqual(writes.filter { $0.deviceID == speakers }.map(\.volume), [0.1, 0.3, 0.3])
        XCTAssertEqual(writes.filter { $0.deviceID == headset }.map(\.volume), [0.9])
    }

    func testAWriteAfterTheBacklogDrainedWritesItsOwnValue() {
        let system = BlockingAudioSystem()
        let worker = AudioHALWorker(audioSystem: system, holdGeneration: LifecycleHoldGeneration(), now: { 0 })
        let speakers: AudioDeviceID = 51

        let first = expectation(description: "first write")
        worker.setVolume(0.7, deviceID: speakers, direction: .input) { _ in first.fulfill() }
        wait(for: [first], timeout: timeout)
        let second = expectation(description: "second write")
        worker.setVolume(0.4, deviceID: speakers, direction: .output) { _ in second.fulfill() }
        wait(for: [second], timeout: timeout)

        XCTAssertEqual(system.volumeWrites.map(\.volume), [0.7, 0.4])
        XCTAssertEqual(system.volumeWrites.map(\.direction), [.input, .output])
    }

    func testControlWritesAreLoggedWithTheirStatusWhenTheyFinish() {
        let lines = observeLines(withPrefix: "control-write ")
        let system = BlockingAudioSystem()
        system.muteStatus = kAudioHardwareUnknownPropertyError
        let generation = LifecycleHoldGeneration()
        generation.advance()
        let worker = AudioHALWorker(audioSystem: system, holdGeneration: generation, now: { 5 })

        let muted = expectation(description: "mute written")
        worker.setMuted(true, deviceID: 51, direction: .input) { result in
            XCTAssertFalse(result.accepted)
            muted.fulfill()
        }
        wait(for: [muted], timeout: timeout)
        let selected = expectation(description: "default written")
        worker.setDefaultDevice(52, direction: .output) { result in
            XCTAssertTrue(result.accepted)
            selected.fulfill()
        }
        wait(for: [selected], timeout: timeout)
        let volume = expectation(description: "volume written")
        worker.setVolume(0.5, deviceID: 53, direction: .output) { _ in volume.fulfill() }
        wait(for: [volume], timeout: timeout)

        XCTAssertEqual(lines.values, [
            "control-write mute id=51 direction=input transport=unread status=\(kAudioHardwareUnknownPropertyError) queued=0.00 elapsed=0.00 gen=1",
            "control-write default id=52 direction=output transport=unread status=0 queued=0.00 elapsed=0.00 gen=1",
            "control-write volume id=53 direction=output transport=unread status=0 queued=0.00 elapsed=0.00 gen=1"
        ])
    }

    func testASlowPollIsLoggedOnceWhileTicksAreDroppedAndAgainWhenItReturns() {
        let lines = observeLines(withPrefix: "hal-poll ")
        let system = BlockingAudioSystem()
        system.blocksPolls = true
        let clock = Clock()
        let worker = AudioHALWorker(
            audioSystem: system,
            holdGeneration: LifecycleHoldGeneration(),
            now: { clock.value }
        )

        let applied = expectation(description: "slow poll applied")
        XCTAssertEqual(worker.poll(request(issuedAt: 10)) { _ in applied.fulfill() }, .issued)
        XCTAssertEqual(system.pollStarted.wait(timeout: .now() + timeout), .success)
        XCTAssertTrue(worker.isPollInFlight)
        XCTAssertEqual(worker.poll(request(issuedAt: 10.25)) { _ in XCTFail("dropped") }, .dropped)
        XCTAssertEqual(lines.values, [], "a poll in flight for 0.25 s is not slow")
        XCTAssertEqual(
            worker.poll(request(issuedAt: 10.75, wantsDeviceLists: true)) { _ in XCTFail("dropped") },
            .droppedWhileSlow(issuedAgo: 0.75),
            "the owner holds the quiet window for this one"
        )
        XCTAssertEqual(worker.poll(request(issuedAt: 11)) { _ in XCTFail("dropped") }, .dropped)
        XCTAssertEqual(lines.values, ["hal-poll slow issued-ago=0.75 gen=0"])

        clock.value = 11.5
        system.blocksPolls = false
        system.releasePoll.signal()
        wait(for: [applied], timeout: timeout)
        XCTAssertFalse(worker.isPollInFlight)
        XCTAssertEqual(lines.values, [
            "hal-poll slow issued-ago=0.75 gen=0",
            "hal-poll recovered elapsed=1.50 gen=0"
        ])

        XCTAssertTrue(worker.takeOwedDeviceLists(), "the dropped device-list poll is owed")
        XCTAssertFalse(worker.takeOwedDeviceLists())

        let fast = expectation(description: "fast poll applied")
        XCTAssertEqual(worker.poll(request(issuedAt: 11.5)) { _ in fast.fulfill() }, .issued)
        wait(for: [fast], timeout: timeout)
        XCTAssertEqual(lines.values.count, 2, "a fast poll writes nothing")
    }

    // MARK: Helpers

    private func request(issuedAt: TimeInterval, wantsDeviceLists: Bool = false) -> AudioHALWorker.Request {
        AudioHALWorker.Request(
            knownOutputDeviceID: AudioDeviceID(kAudioObjectUnknown),
            knownInputDeviceID: AudioDeviceID(kAudioObjectUnknown),
            wantsDeviceLists: wantsDeviceLists,
            controlWriteEpoch: 0,
            issuedAt: issuedAt
        )
    }

    private func observeLines(withPrefix prefix: String) -> LineLog {
        let log = LineLog()
        HALLifecycleLog.observer = { line in
            if line.hasPrefix(prefix) {
                log.append(line)
            }
        }
        return log
    }
}

private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0

    var value: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}

/// A fake audio system whose first volume write, or whose polls, can block
/// until released.
private final class BlockingAudioSystem: AudioHALWorkerSystem, @unchecked Sendable {
    struct VolumeWrite {
        let volume: Float
        let deviceID: AudioDeviceID
        let direction: AudioDirection
    }

    let firstVolumeWriteStarted = DispatchSemaphore(value: 0)
    let releaseFirstVolumeWrite = DispatchSemaphore(value: 0)
    let pollStarted = DispatchSemaphore(value: 0)
    let releasePoll = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var writes: [VolumeWrite] = []
    private var _blocksFirstVolumeWrite = false
    private var _blocksPolls = false
    private var _muteStatus: OSStatus = noErr

    var volumeWrites: [VolumeWrite] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    var blocksFirstVolumeWrite: Bool {
        get { withLock { _blocksFirstVolumeWrite } }
        set { withLock { _blocksFirstVolumeWrite = newValue } }
    }

    /// Whether a poll's first read waits for `releasePoll`.
    var blocksPolls: Bool {
        get { withLock { _blocksPolls } }
        set { withLock { _blocksPolls = newValue } }
    }

    var muteStatus: OSStatus {
        get { withLock { _muteStatus } }
        set { withLock { _muteStatus = newValue } }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func defaultDevice(for direction: AudioDirection) -> AudioDeviceID? {
        if direction == .output, blocksPolls {
            pollStarted.signal()
            releasePoll.wait()
        }
        return nil
    }

    func devices(for direction: AudioDirection) -> [AudioDevice] { [] }
    func deviceIDs() -> [AudioDeviceID]? { [] }
    func transport(for deviceID: AudioDeviceID) -> AudioDeviceTransport? { .builtIn }
    func transportInfo(
        for deviceID: AudioDeviceID,
        transportOf: (AudioDeviceID) -> AudioDeviceTransport?
    ) -> AudioDeviceTransportInfo? { nil }
    func deviceUID(for deviceID: AudioDeviceID) -> String? { nil }
    func controls(for deviceID: AudioDeviceID, direction: AudioDirection) -> AudioControlSnapshot {
        AudioControlSnapshot(volume: nil, volumeIsAdjustable: false, isMuted: nil, muteIsAdjustable: false)
    }
    func forgetControlLayoutCache() {}
    func setDefaultDevice(_ deviceID: AudioDeviceID, for direction: AudioDirection) -> OSStatus { noErr }
    func setMuted(_ muted: Bool, deviceID: AudioDeviceID, direction: AudioDirection) -> OSStatus { muteStatus }

    func setVolume(_ volume: Float, deviceID: AudioDeviceID, direction: AudioDirection) -> OSStatus {
        lock.lock()
        let blocks = _blocksFirstVolumeWrite && writes.isEmpty
        writes.append(VolumeWrite(volume: volume, deviceID: deviceID, direction: direction))
        lock.unlock()
        if blocks {
            firstVolumeWriteStarted.signal()
            releaseFirstVolumeWrite.wait()
        }
        return noErr
    }
}
