import AVFoundation
import Foundation

extension AudioState {
    /// What `AudioState` reaches Core Audio, the lifecycle clock, the main
    /// run loop and microphone permission through.
    ///
    /// `live()` is what the app runs. A test builds one from fakes that never
    /// reach coreaudiod, a clock and a scheduler it drives, and a microphone
    /// permission it chooses, so that the owner's lifecycle wiring can be
    /// exercised without opening a device or asking for permission.
    struct Dependencies {
        /// The poll's reads and the control writes, and `AudioState`'s own
        /// reads of the device lists, the defaults, their controls and the
        /// default output's UID.
        var audioSystem: any AudioHALWorkerSystem
        /// The lifecycle calls of the meters, the capture, the publication
        /// and the system notifications, and the reads made just before them.
        var halCalls: any HALLifecycleCalls
        /// The lifecycle clock. It must not count time asleep; see
        /// `AudioState.lifecycleNow()`.
        var now: () -> TimeInterval
        var scheduler: any AudioStateScheduler
        var microphoneAuthorization: any MicrophoneAuthorization
        /// Makes the processed microphone's Apple voice-processing capture
        /// engine.
        var makeVoiceProcessingEngine: () -> any VoiceProcessingCaptureEngine
        /// Where the launch cleanup reads the process taps and aggregate
        /// devices an earlier run may have left.
        var tapReclaimInventory: OrphanedProcessTapReclaimer.Inventory
        /// Where sleep and wake are observed for the log.
        var powerNotificationCenter: NotificationCenter

        /// The app's: one `CoreAudioSystem` behind both the poll and the
        /// lifecycle calls, the system uptime, the main queue and run loop,
        /// `AVCaptureDevice`, `AVAudioEngine`, the live inventory and the
        /// workspace notification center.
        static func live() -> Dependencies {
            let audioSystem = CoreAudioSystem()
            return Dependencies(
                audioSystem: audioSystem,
                halCalls: CoreAudioHALLifecycleCalls(audioSystem: audioSystem),
                // `systemUptime` stops while the Mac sleeps; `Date` and
                // `ContinuousClock` keep counting, so neither may replace it.
                now: { ProcessInfo.processInfo.systemUptime },
                scheduler: MainRunLoopScheduler(),
                microphoneAuthorization: SystemMicrophoneAuthorization(),
                makeVoiceProcessingEngine: { AVAudioVoiceProcessingEngine() },
                tapReclaimInventory: .live,
                powerNotificationCenter: PowerStateLog.defaultCenter
            )
        }
    }
}

/// Where `AudioState` schedules its own work on the main thread.
protocol AudioStateScheduler {
    /// `DispatchQueue.main.async`.
    func async(_ body: @escaping () -> Void)
    /// `DispatchQueue.main.asyncAfter`, `delay` seconds from now.
    func asyncAfter(_ delay: TimeInterval, execute item: DispatchWorkItem)
    /// A repeating `Timer` on the main run loop in the common modes.
    ///
    /// - Returns: What invalidates it.
    func repeating(
        every interval: TimeInterval,
        tolerance: TimeInterval,
        _ body: @escaping () -> Void
    ) -> () -> Void
}

/// The app's scheduler: the main queue and the main run loop.
struct MainRunLoopScheduler: AudioStateScheduler {
    func async(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }

    func asyncAfter(_ delay: TimeInterval, execute item: DispatchWorkItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func repeating(
        every interval: TimeInterval,
        tolerance: TimeInterval,
        _ body: @escaping () -> Void
    ) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            body()
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

/// The microphone permission `AudioState` checks and asks for.
protocol MicrophoneAuthorization {
    /// `AVCaptureDevice.authorizationStatus(for: .audio)`.
    func status() -> AVAuthorizationStatus
    /// `AVCaptureDevice.requestAccess(for: .audio)`. `completion` may run on
    /// any thread.
    func requestAccess(_ completion: @escaping (Bool) -> Void)
}

/// The system's microphone permission.
struct SystemMicrophoneAuthorization: MicrophoneAuthorization {
    func status() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }
}
