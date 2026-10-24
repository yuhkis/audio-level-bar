import AVFoundation
import AudioLevelBarCore
import CoreAudio
import Dispatch
import XCTest
@testable import AudioLevelBar

/// An `AudioState` built from fakes that never reach coreaudiod: the fake HAL
/// lifecycle calls, a fake audio system for the poll and `AudioState`'s own
/// reads, a clock and a scheduler the test drives, a granted microphone
/// permission, fake publisher engines, a tap inventory that is empty unless
/// a test fills it, and a notification center of its own for the system's
/// sleep and wake.
///
/// The test advances the clock, fires the poll timer, fires HAL listeners
/// through the fake, and calls `settle()` to let every lifecycle queue, the
/// main queue and the scheduler run what was issued. A fake call can be held
/// on the queue that makes it, as a coreaudiod that does not answer would;
/// `settle()` then leaves that queue alone until the test releases it.
final class AudioStateHarness {
    static let builtInMicrophone: AudioDeviceID = 41
    static let usbMicrophone: AudioDeviceID = 42
    static let speakers: AudioDeviceID = FakeHALLifecycleCalls.defaultOutputID
    static let usbOutput: AudioDeviceID = 501
    /// A Bluetooth headset with a microphone and an output, not connected
    /// until a test connects it.
    static let headset: AudioDeviceID = 60
    static let publishedAggregate = FakeHALLifecycleCalls.publishedAggregateID
    static let publishedTap = FakeHALLifecycleCalls.publishedTapID
    static let systemOutputAggregate = FakeHALLifecycleCalls.aggregateID
    static let systemOutputTap = FakeHALLifecycleCalls.tapID

    let hal = FakeHALLifecycleCalls()
    let system = FakeAudioSystem()
    let clock = ManualClock(1_000)
    let scheduler: ManualScheduler
    let authorization = FakeMicrophoneAuthorization()
    let lines = HALLineLog()
    let holds = CallHolds()
    let voiceProcessingEngines = VoiceProcessingEngineLog()
    /// Where a test posts the system's sleep and wake.
    let powerNotifications = NotificationCenter()
    /// What the launch cleanup's tap reclaim finds; nothing unless set.
    let earlierRunTaps = EarlierRunTaps()
    let defaults: UserDefaults
    private let suiteName = "io.github.yuhkis.audio-level-bar.tests.\(UUID().uuidString)"
    private(set) var state: AudioState!

    init(
        systemOutputMonitoring: Bool = false,
        processedMicrophone: Bool = false,
        processingMode: MicrophoneProcessingMode = .off,
        appleVoiceProcessingAvailable: Bool = true
    ) {
        scheduler = ManualScheduler(clock: clock)
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(systemOutputMonitoring, forKey: "systemOutputMonitoringEnabled")
        defaults.set(processedMicrophone, forKey: "processedMicrophoneEnabled")
        defaults.set(processingMode.rawValue, forKey: "microphoneProcessingMode")
        defaults.set(appleVoiceProcessingAvailable, forKey: AudioState.experimentalAppleVoiceProcessingKey)

        hal.listedOutputDevices = [FakeAudioSystem.speakersDevice, FakeAudioSystem.usbOutputDevice]
        // The uncached reads Apple voice processing makes see the same
        // default input as the poll.
        hal.currentDefaultInputID = Self.builtInMicrophone
        let holds = holds
        let hal = hal
        // Each engine call lands in the timeline between the HAL calls and
        // lines around it.
        voiceProcessingEngines.prepare = { engine in
            let previous = engine.onCall
            engine.onCall = { call in
                hal.noteLine("fake-voice-processing-engine \(call.rawValue)")
                previous?(call)
            }
        }
        hal.onCall = { call in
            holds.enter(.hal(call))
        }
        system.onDefaultDeviceWrite = { deviceID, direction in
            holds.enter(.defaultDeviceWrite(deviceID))
            if direction == .output {
                // The uncached reads the system playback meter makes see the
                // new default output too.
                hal.currentDefaultOutputID = deviceID
                hal.defaultOutputUID = FakeAudioSystem.uid(of: deviceID)
            }
        }
        let lines = lines
        HALLifecycleLog.observer = { line in
            lines.append(line)
            hal.noteLine(line)
            lines.onLine?(line)
        }

        let clock = clock
        let voiceProcessingEngines = voiceProcessingEngines
        state = AudioState(
            defaults: defaults,
            dependencies: AudioState.Dependencies(
                audioSystem: system,
                halCalls: hal,
                now: { clock.now },
                scheduler: scheduler,
                microphoneAuthorization: authorization,
                makeVoiceProcessingEngine: { voiceProcessingEngines.make() },
                tapReclaimInventory: OrphanedProcessTapReclaimer.Inventory(
                    otherRunningInstances: { [] },
                    // A tap the fake HAL has destroyed is no longer listed.
                    processTaps: { [earlierRunTaps] in
                        earlierRunTaps.taps.filter { !hal.calls.contains(.destroyProcessTap($0.objectID)) }
                    },
                    aggregateDevices: { [] }
                ),
                powerNotificationCenter: powerNotifications
            )
        )
    }

    /// Releases every held call and forgets the log observer and defaults.
    func tearDown() {
        holds.releaseAll()
        HALLifecycleLog.observer = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Driving

    func launch() {
        state.start()
        settle()
    }

    /// Launches, lets the launch window end, and polls after it, so the
    /// microphone meter runs on the built-in microphone.
    func launchAndRelease(file: StaticString = #filePath, line: UInt = #line) {
        launch()
        advance(by: LifecycleQuietWindow.settle + 0.1)
        poll()
        XCTAssertEqual(state.microphoneDisplay, .live, "the meter runs after the launch window", file: file, line: line)
    }

    /// `launchAndRelease()` with the processed microphone on: it publishes
    /// once the meter runs, and stays idle while no app has it open.
    func launchAndPublish(file: StaticString = #filePath, line: UInt = #line) {
        launchAndRelease(file: file, line: line)
        XCTAssertEqual(state.processedMicrophoneState, .publishedIdle, file: file, line: line)
    }

    /// A consuming app opens or closes the published device, as its in-use
    /// listener reports it.
    func setPublishedDeviceInUse(_ inUse: Bool) {
        hal.isRunningSomewhereRead = (noErr, inUse ? 1 : 0)
        hal.fireListener(
            deviceID: Self.publishedAggregate,
            selector: kAudioDevicePropertyDeviceIsRunningSomewhere
        )
    }

    /// Holds the processed microphone capture's `AudioDeviceStart` on its
    /// queue.
    func holdCaptureStart() {
        let captureQueue = state.lifecycleQueuesForTesting.processedMicrophoneCapture.label
        holds.hold { point, queueLabel in
            // The publisher's start runs on the same queue, before it.
            guard case let .hal(.start(deviceID)) = point, !Self.publisherOutputs.contains(deviceID) else {
                return false
            }
            return queueLabel == captureQueue
        }
    }

    /// Waits for each lifecycle queue that holds no call, without running
    /// the main queue.
    func runLifecycleQueues() {
        for queue in state.lifecycleQueuesForTesting.all {
            waitFor(queue)
        }
    }

    func advance(by seconds: TimeInterval) {
        clock.advance(by: seconds)
    }

    /// Fires the poll timer once and settles.
    func poll() {
        scheduler.tick()
        settle()
    }

    /// Runs one evaluation now, synchronously, without a poll: the processing
    /// mode is switched between off and WebRTC, which with the processed
    /// microphone off moves nothing.
    func evaluate() {
        let next: MicrophoneProcessingMode = state.microphoneProcessingMode == .off ? .webRTCLow : .off
        state.setMicrophoneProcessingMode(next)
    }

    /// A HAL system object notification, delivered on the calling thread as
    /// the listener queue would deliver it. The main thread hears of it once
    /// the main queue runs.
    func fireSystemNotification(_ notification: HALSystemNotification) {
        hal.fireListener(deviceID: AudioObjectID(kAudioObjectSystemObject), selector: notification.selector)
    }

    /// Runs `body` inside every call of every voice-processing engine made
    /// from now on, after the harness notes the call and before it returns,
    /// on the main thread.
    func onVoiceProcessingEngineCall(
        _ body: @escaping (FakeVoiceProcessingEngine, FakeVoiceProcessingEngine.Call) -> Void
    ) {
        let previous = voiceProcessingEngines.prepare
        voiceProcessingEngines.prepare = { engine in
            previous?(engine)
            let noted = engine.onCall
            engine.onCall = { [unowned engine] call in
                noted?(call)
                body(engine, call)
            }
        }
    }

    /// A Bluetooth headset connects: the poll's device list and the uncached
    /// output device list show it. It becomes no default.
    func connectHeadset() {
        system.connect(FakeAudioSystem.headsetDevice)
        hal.listedOutputDevices = (hal.listedOutputDevices ?? []) + [FakeAudioSystem.headsetDevice]
    }

    /// The headset disconnects from both lists.
    func disconnectHeadset() {
        system.disconnect(Self.headset)
        hal.listedOutputDevices = hal.listedOutputDevices?.filter { $0.id != Self.headset }
    }

    /// Moves the default output in both the poll's reads and the uncached
    /// reads the system playback meter makes.
    func moveDefaultOutput(to deviceID: AudioDeviceID) {
        system.setDefault(deviceID, for: .output)
        hal.currentDefaultOutputID = deviceID
        hal.defaultOutputUID = system.deviceUID(for: deviceID)
    }

    /// Runs what every lifecycle queue, the main queue and the scheduler were
    /// given, until three passes in a row find nothing new. A queue holding a
    /// call is left alone.
    func settle(file: StaticString = #filePath, line: UInt = #line) {
        var quietPasses = 0
        var last = progress
        for _ in 0..<500 {
            for queue in state.lifecycleQueuesForTesting.all {
                waitFor(queue)
            }
            drainMainQueue()
            let ran = scheduler.runDue()
            let current = progress
            if current == last, !ran {
                quietPasses += 1
                if quietPasses >= 3 {
                    return
                }
            } else {
                quietPasses = 0
                last = current
            }
        }
        XCTFail("the harness did not settle", file: file, line: line)
    }

    /// Runs the main queue only, leaving the lifecycle queues alone.
    func drainMainQueue() {
        var drained = false
        DispatchQueue.main.async {
            drained = true
        }
        while !drained {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// The output devices the processed microphone's publisher may be bound
    /// to here.
    static let publisherOutputs: Set<AudioDeviceID> = [speakers, usbOutput]

    /// The publisher IOProcs created so far, one per publisher start that got
    /// as far as its create.
    var publisherCreates: Int {
        hal.calls.filter { call in
            if case let .createIOProc(id) = call { return Self.publisherOutputs.contains(id) }
            return false
        }.count
    }

    /// The last create, start, stop or destroy call on a publisher output.
    var lastPublisherCall: FakeHALLifecycleCalls.Call? {
        hal.lifecycleCalls.last { call in
            switch call {
            case let .createIOProc(id), let .start(id), let .stop(id), let .destroyIOProc(id):
                return Self.publisherOutputs.contains(id)
            default:
                return false
            }
        }
    }

    private var progress: [Int] {
        [
            hal.timeline.count,
            lines.values.count,
            scheduler.executed,
            voiceProcessingEngines.callCount
        ]
    }

    private func waitFor(_ queue: DispatchQueue) {
        guard !holds.isHolding(queueLabel: queue.label) else {
            return
        }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            done.signal()
        }
        while done.wait(timeout: .now() + 0.005) == .timedOut {
            if holds.isHolding(queueLabel: queue.label) {
                return
            }
        }
    }

    // MARK: Reading

    /// The reasons of every `quiet-window hold` line, in order.
    var holdReasons: [String] {
        lines.values.compactMap { line in
            guard line.hasPrefix("quiet-window hold ") else {
                return nil
            }
            return Self.field("reason", of: line)
        }
    }

    /// The lines that start with `prefix`.
    func lines(withPrefix prefix: String) -> [String] {
        lines.values.filter { $0.hasPrefix(prefix) }
    }

    /// The create, start, stop and destroy calls made after the first
    /// `count` calls.
    func lifecycleCalls(after count: Int) -> [FakeHALLifecycleCalls.Call] {
        Array(hal.calls.dropFirst(count)).filter { !$0.isListenerCall }
    }

    /// The position in the timeline of the first call equal to `call`.
    func timelineIndex(of call: FakeHALLifecycleCalls.Call) -> Int? {
        hal.timeline.firstIndex(of: .call(call))
    }

    /// The position in the timeline of the first line with `prefix`.
    func timelineIndex(ofLineWithPrefix prefix: String) -> Int? {
        hal.timeline.firstIndex { entry in
            if case let .line(text) = entry {
                return text.hasPrefix(prefix)
            }
            return false
        }
    }

    static func field(_ name: String, of line: String) -> String? {
        line.split(separator: " ")
            .first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    // MARK: Messages

    static var microphoneStallMessage: String {
        localized("Core Audio has not finished starting the microphone level meter. If other audio apps have stopped responding too, Core Audio itself is not answering, and only restarting the Mac recovers it.")
    }

    static var processedMicrophoneStallMessage: String {
        localized("Core Audio has not finished starting or stopping the processed microphone. If other audio apps have stopped responding too, Core Audio itself is not answering, and only restarting the Mac recovers it.")
    }

    static var systemOutputStallMessage: String {
        localized("Core Audio has not finished starting or stopping system playback level monitoring. If other audio apps have stopped responding too, Core Audio itself is not answering, and only restarting the Mac recovers it.")
    }

    static var systemOutputRebuildsExhaustedMessage: String {
        localized("System playback level monitoring stopped because the output kept stopping or reconfiguring. Choose Retry to start it again. It also starts again when the output device changes.")
    }

    static var microphoneTransportUnreadMessage: String {
        localized("The input device’s connection type could not be read, so the microphone level meter could not start.")
    }
}

/// The poll's and `AudioState`'s reads, and the control writes, for a small
/// fixed set of devices: a built-in and a USB microphone, and built-in and
/// USB outputs.
final class FakeAudioSystem: AudioHALWorkerSystem, @unchecked Sendable {
    static let builtInMicrophoneDevice = AudioDevice(
        id: AudioStateHarness.builtInMicrophone,
        name: "Microphone",
        uid: "builtin-microphone",
        inputChannelCount: 1,
        outputChannelCount: 0,
        transport: .builtIn
    )
    static let usbMicrophoneDevice = AudioDevice(
        id: AudioStateHarness.usbMicrophone,
        name: "USB Microphone",
        uid: "usb-microphone",
        inputChannelCount: 1,
        outputChannelCount: 0,
        transport: .usb
    )
    static let speakersDevice = AudioDevice(
        id: AudioStateHarness.speakers,
        name: "Speakers",
        uid: "output",
        inputChannelCount: 0,
        outputChannelCount: 2,
        transport: .builtIn
    )
    static let usbOutputDevice = AudioDevice(
        id: AudioStateHarness.usbOutput,
        name: "USB Output",
        uid: "usb-output",
        inputChannelCount: 0,
        outputChannelCount: 2,
        transport: .usb
    )
    static let headsetDevice = AudioDevice(
        id: AudioStateHarness.headset,
        name: "Headset",
        uid: "headset",
        inputChannelCount: 1,
        outputChannelCount: 2,
        transport: .bluetooth
    )

    private let lock = NSLock()
    private var devices = [builtInMicrophoneDevice, usbMicrophoneDevice, speakersDevice, usbOutputDevice]
    private var defaultInput: AudioDeviceID? = AudioStateHarness.builtInMicrophone
    private var defaultOutput: AudioDeviceID? = AudioStateHarness.speakers
    private var _writeStatus: OSStatus = noErr
    private var _polledTransportInfo: [AudioDeviceID: AudioDeviceTransportInfo] = [:]
    private var _forgottenLayoutCaches = 0
    private var _onDefaultDeviceWrite: ((AudioDeviceID, AudioDirection) -> Void)?
    private var _onMainThreadUIDRead: ((AudioDeviceID) -> Void)?
    private var _onMainThreadDeviceListRead: (() -> Void)?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Adds `device` to the device list.
    func connect(_ device: AudioDevice) {
        withLock { devices.append(device) }
    }

    /// Removes the device from the device list.
    func disconnect(_ deviceID: AudioDeviceID) {
        withLock { devices.removeAll { $0.id == deviceID } }
    }

    func setDefault(_ deviceID: AudioDeviceID?, for direction: AudioDirection) {
        withLock {
            switch direction {
            case .input:
                defaultInput = deviceID
            case .output:
                defaultOutput = deviceID
            }
        }
    }

    /// What the poll reads as `deviceID`'s transport and sub-devices, in place
    /// of the device's own transport alone: an aggregate's composition, for
    /// instance. nil goes back to the device's own transport.
    func setPolledTransportInfo(_ info: AudioDeviceTransportInfo?, for deviceID: AudioDeviceID) {
        withLock { _polledTransportInfo[deviceID] = info }
    }

    /// What every default-device write returns; `noErr` unless set.
    var writeStatus: OSStatus {
        get { withLock { _writeStatus } }
        set { withLock { _writeStatus = newValue } }
    }

    var forgottenLayoutCaches: Int {
        withLock { _forgottenLayoutCaches }
    }

    /// Runs on the HAL worker's queue inside each default-device write,
    /// before it takes effect.
    var onDefaultDeviceWrite: ((AudioDeviceID, AudioDirection) -> Void)? {
        get { withLock { _onDefaultDeviceWrite } }
        set { withLock { _onDefaultDeviceWrite = newValue } }
    }

    /// Runs inside a device list read made on the main thread, as the one
    /// `AudioState` makes after a publication or its teardown.
    var onMainThreadDeviceListRead: (() -> Void)? {
        get { withLock { _onMainThreadDeviceListRead } }
        set { withLock { _onMainThreadDeviceListRead = newValue } }
    }

    /// Runs inside a UID read made on the main thread.
    var onMainThreadUIDRead: ((AudioDeviceID) -> Void)? {
        get { withLock { _onMainThreadUIDRead } }
        set { withLock { _onMainThreadUIDRead = newValue } }
    }

    static func uid(of deviceID: AudioDeviceID) -> String? {
        [builtInMicrophoneDevice, usbMicrophoneDevice, speakersDevice, usbOutputDevice, headsetDevice]
            .first { $0.id == deviceID }?
            .uid
    }

    private func device(_ deviceID: AudioDeviceID) -> AudioDevice? {
        withLock { devices.first { $0.id == deviceID } }
    }

    func defaultDevice(for direction: AudioDirection) -> AudioDeviceID? {
        withLock { direction == .input ? defaultInput : defaultOutput }
    }

    func devices(for direction: AudioDirection) -> [AudioDevice] {
        if Thread.isMainThread, let hook = onMainThreadDeviceListRead {
            hook()
        }
        return withLock { devices.filter { direction == .input ? $0.hasInput : $0.hasOutput } }
    }

    func deviceIDs() -> [AudioDeviceID]? {
        withLock { devices.map(\.id) }
    }

    func transport(for deviceID: AudioDeviceID) -> AudioDeviceTransport? {
        device(deviceID)?.transport
    }

    func transportInfo(
        for deviceID: AudioDeviceID,
        transportOf: (AudioDeviceID) -> AudioDeviceTransport?
    ) -> AudioDeviceTransportInfo? {
        guard deviceID != kAudioObjectUnknown else {
            return nil
        }
        if let polled = withLock({ _polledTransportInfo[deviceID] }) {
            return polled
        }
        return transportOf(deviceID).map { AudioDeviceTransportInfo(transport: $0) }
    }

    func deviceUID(for deviceID: AudioDeviceID) -> String? {
        if Thread.isMainThread, let hook = onMainThreadUIDRead {
            hook(deviceID)
        }
        return device(deviceID)?.uid
    }

    func controls(for deviceID: AudioDeviceID, direction: AudioDirection) -> AudioControlSnapshot {
        AudioControlSnapshot(volume: 0.5, volumeIsAdjustable: true, isMuted: false, muteIsAdjustable: true)
    }

    func forgetControlLayoutCache() {
        withLock { _forgottenLayoutCaches += 1 }
    }

    func setDefaultDevice(_ deviceID: AudioDeviceID, for direction: AudioDirection) -> OSStatus {
        onDefaultDeviceWrite?(deviceID, direction)
        let status = writeStatus
        if status == noErr {
            setDefault(deviceID, for: direction)
        }
        return status
    }

    func setVolume(_ volume: Float, deviceID: AudioDeviceID, direction: AudioDirection) -> OSStatus {
        noErr
    }

    func setMuted(_ muted: Bool, deviceID: AudioDeviceID, direction: AudioDirection) -> OSStatus {
        noErr
    }
}

/// Process taps an earlier run of the app left behind, as the launch
/// cleanup's inventory lists them.
final class EarlierRunTaps: @unchecked Sendable {
    private let lock = NSLock()
    private var listed: [AudioResourceInventory.ProcessTap] = []

    var taps: [AudioResourceInventory.ProcessTap] {
        lock.lock()
        defer { lock.unlock() }
        return listed
    }

    /// Lists a stranded tap of the published microphone under `objectID`.
    func strand(_ objectID: AudioObjectID, uid: String) {
        lock.lock()
        listed.append(
            AudioResourceInventory.ProcessTap(
                objectID: objectID,
                uid: uid,
                name: "tap",
                ownership: .publishedMicrophone,
                bundleIDs: [],
                attributionIsAuthoritative: true,
                restoresAcrossReboot: false,
                targets: []
            )
        )
        lock.unlock()
    }
}

/// A lifecycle clock the test advances.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ start: TimeInterval) {
        value = start
    }

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

/// `AudioState`'s main-thread work, run when the test says: queued work in
/// order, delayed work once the clock has reached it, and the poll timer on
/// each tick.
final class ManualScheduler: AudioStateScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: ManualClock
    private var queued: [() -> Void] = []
    private var delayed: [(at: TimeInterval, item: DispatchWorkItem)] = []
    private var pollTimer: (() -> Void)?
    private var _executed = 0

    init(clock: ManualClock) {
        self.clock = clock
    }

    /// How many queued or delayed items have run.
    var executed: Int {
        lock.lock()
        defer { lock.unlock() }
        return _executed
    }

    var isPolling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pollTimer != nil
    }

    func async(_ body: @escaping () -> Void) {
        lock.lock()
        queued.append(body)
        lock.unlock()
    }

    func asyncAfter(_ delay: TimeInterval, execute item: DispatchWorkItem) {
        lock.lock()
        delayed.append((clock.now + delay, item))
        lock.unlock()
    }

    func repeating(
        every interval: TimeInterval,
        tolerance: TimeInterval,
        _ body: @escaping () -> Void
    ) -> () -> Void {
        lock.lock()
        pollTimer = body
        lock.unlock()
        return { [weak self] in
            guard let self else {
                return
            }
            lock.lock()
            pollTimer = nil
            lock.unlock()
        }
    }

    /// Fires the poll timer, if it runs.
    func tick() {
        lock.lock()
        let body = pollTimer
        lock.unlock()
        body?()
    }

    /// Runs queued work, and due delayed work, until none is left. Returns
    /// whether anything ran.
    @discardableResult
    func runDue() -> Bool {
        var ran = false
        while true {
            lock.lock()
            let next: (() -> Void)?
            if !queued.isEmpty {
                next = queued.removeFirst()
            } else if let index = delayed.firstIndex(where: { $0.at <= clock.now }) {
                let item = delayed.remove(at: index).item
                next = { if !item.isCancelled { item.perform() } }
            } else {
                next = nil
            }
            if next != nil {
                _executed += 1
            }
            lock.unlock()
            guard let next else {
                return ran
            }
            next()
            ran = true
        }
    }
}

/// A microphone permission that is granted unless the test says otherwise,
/// and never asks the system.
final class FakeMicrophoneAuthorization: MicrophoneAuthorization, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AVAuthorizationStatus = .authorized

    var current: AVAuthorizationStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    func status() -> AVAuthorizationStatus {
        current
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        completion(current == .authorized)
    }
}

/// Every hal-lifecycle line, in order.
final class HALLineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var _onLine: ((String) -> Void)?

    /// Runs inside the write of every line, on the thread that wrote it,
    /// once the line has been noted. A test fires a HAL listener from here to
    /// advance the generation between two steps of one evaluation, such as
    /// after the `quiet-window release` line and before the steps that
    /// release issues.
    var onLine: ((String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onLine
        }
        set {
            lock.lock()
            _onLine = newValue
            lock.unlock()
        }
    }

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

/// Holds a fake call on the queue that makes it, until the test releases
/// it, as a coreaudiod that does not answer would.
final class CallHolds: @unchecked Sendable {
    enum Point: Equatable {
        case hal(FakeHALLifecycleCalls.Call)
        case defaultDeviceWrite(AudioDeviceID)
    }

    private let lock = NSLock()
    private var predicate: ((Point, _ queueLabel: String) -> Bool)?
    private var heldLabels: [String] = []
    private var _entered: [Point] = []
    private var _onEnter: ((Point) -> Void)?
    private let gate = DispatchSemaphore(value: 0)

    /// Runs inside every fake call, on its queue, before any hold.
    var onEnter: ((Point) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onEnter
        }
        set {
            lock.lock()
            _onEnter = newValue
            lock.unlock()
        }
    }

    /// Holds the next calls `predicate` matches, on whichever queue makes
    /// them, until `releaseAll()`.
    func hold(where predicate: @escaping (Point, _ queueLabel: String) -> Bool) {
        lock.lock()
        self.predicate = predicate
        lock.unlock()
    }

    /// The calls held so far, in the order they were entered.
    var entered: [Point] {
        lock.lock()
        defer { lock.unlock() }
        return _entered
    }

    func isHolding(queueLabel: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return heldLabels.contains(queueLabel)
    }

    /// Stops holding, and lets every held call return.
    func releaseAll() {
        lock.lock()
        predicate = nil
        let count = heldLabels.count
        lock.unlock()
        for _ in 0..<count {
            gate.signal()
        }
    }

    /// Called inside each fake call.
    func enter(_ point: Point) {
        onEnter?(point)
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.lock()
        guard let predicate, predicate(point, label) else {
            lock.unlock()
            return
        }
        heldLabels.append(label)
        _entered.append(point)
        lock.unlock()
        gate.wait()
        lock.lock()
        if let index = heldLabels.firstIndex(of: label) {
            heldLabels.remove(at: index)
        }
        lock.unlock()
    }
}
