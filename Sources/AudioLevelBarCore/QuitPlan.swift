import Foundation

/// The order of Quit's teardown, and how long Quit defers it while the quiet
/// window holds. Quit is one of the lifecycle paths the quiet window does not
/// hold; the others are the immediate stop of an IOProc whose open aggregate
/// device gains a Bluetooth sub-device (`AggregateMembershipPolicy`), and the
/// stop of Apple voice processing before the app's own picker writes a
/// default device.
///
/// When Quit arrives while the window holds, a Bluetooth device or a default
/// device has just changed, and coreaudiod may still be reconfiguring it. The
/// menu bar item goes at once, so the app visibly quits, but the teardown
/// waits until 3 s have passed since the last change the window noted, a
/// change carried past its cap included, and never more than
/// `deferralMaximum` after the Quit request
/// (`deferral(now:windowEnd:deadline:)`). Only that maximum is fixed at the
/// request. Each time the deferral comes due, the window is read again, and a
/// change noted meanwhile moves the teardown later, up to the maximum. A
/// window that has settled and only waits for a poll issued after its end
/// defers nothing: no change has been noted for 3 s.
///
/// The teardown then runs these steps. The level gates of the microphone
/// meter, the system playback meter and the IOProc capture close first, from
/// the main thread, so no IO thread processes anything while the process
/// exits. The processing engines stop next: the publisher engine renders into
/// the muted process tap the publication captures, so it stops before the
/// publication is withdrawn, and the IOProc capture's release is handed to
/// its lifecycle queue at the same point. The publication is withdrawn next,
/// refused while a consuming app holds it. The meters' stops are then handed
/// to their lifecycle queues, and Quit waits for every queued stop while some
/// stop has finished a HAL call within `lifecycleStopIdleTimeout`, and for at
/// most `lifecycleStopCeiling`, so a queue stuck behind a HAL call that an
/// unresponsive coreaudiod never answers cannot hang Quit.
///
/// The wait's bounds count from the wait's own start, after the deferral and
/// after the synchronous main-thread steps before it. A window armed before
/// Quit, during the deferral or during the teardown neither extends nor
/// shortens them, and a window armed during the teardown does not interrupt
/// it: the deferral is where Quit gives way to the window, and a longer wait
/// would only let a stuck coreaudiod hold Quit longer. The time
/// from the Quit request to the exit is therefore at most `deferralMaximum`,
/// plus the main-thread steps, which have no bound of their own, plus
/// `lifecycleStopCeiling`.
public enum QuitPlan {
    public enum Step: Equatable {
        /// Close the level gates of the meters and the IOProc capture.
        case closeLevelGates
        /// Stop the publisher and voice-processing engines on the main
        /// thread, and hand the IOProc capture's release to its queue.
        case stopProcessingEngines
        /// Withdraw the published device, unless a consuming app holds it.
        case withdrawPublication
        /// Hand the microphone meter's stop to its lifecycle queue.
        case stopMicrophoneMeter
        /// Hand the system playback meter's stop to its lifecycle queue.
        case stopSystemOutputMeter
        /// Wait for every stop handed to a lifecycle queue. See
        /// `LifecycleStopGroup.wait(idleTimeout:ceiling:)`.
        case waitForLifecycleStops(idleTimeout: TimeInterval, ceiling: TimeInterval)
    }

    /// How long the wait goes on with no stop reporting progress. Progress
    /// is reported before each HAL call, so this is how long one call may
    /// take before Quit gives up on it. A healthy Bluetooth configuration
    /// change can keep a single stop or destroy waiting for about 1.5 s, so
    /// the bound sits well above that: a bound below it would read a
    /// server that is slow but answering as one that is not answering, and
    /// exit with a call still inside coreaudiod. A server that does not
    /// answer at all still ends the wait here.
    public static let lifecycleStopIdleTimeout: TimeInterval = 3
    /// The longest the wait goes on while stops keep reporting progress:
    /// room for a queue's calls to wait out a chained pair of configuration
    /// changes, one after another.
    public static let lifecycleStopCeiling: TimeInterval = 8
    /// The longest Quit defers its teardown for a quiet window, from the Quit
    /// request.
    public static let deferralMaximum: TimeInterval = 3

    public static let steps: [Step] = [
        .closeLevelGates,
        .stopProcessingEngines,
        .withdrawPublication,
        .stopMicrophoneMeter,
        .stopSystemOutputMeter,
        .waitForLifecycleStops(idleTimeout: lifecycleStopIdleTimeout, ceiling: lifecycleStopCeiling)
    ]

    /// Below this many seconds a deferral is not worth scheduling, and the
    /// teardown runs.
    public static let deferralResolution: TimeInterval = 0.01

    /// How many more seconds Quit's teardown waits at `now`.
    ///
    /// - Parameters:
    ///   - windowEnd: When the quiet window stops holding Quit, from
    ///     `windowEnd(now:settleEnd:outstandingDefaultWrites:generationUnseen:)`;
    ///     nil when no window is armed.
    ///   - deadline: `deferralMaximum` after the Quit request, fixed then.
    /// - Returns: The time left until the earlier of `windowEnd` and
    ///   `deadline`, or 0 once that is below `deferralResolution`.
    public static func deferral(
        now: TimeInterval,
        windowEnd: TimeInterval?,
        deadline: TimeInterval
    ) -> TimeInterval {
        guard let windowEnd else {
            return 0
        }
        let remaining = min(windowEnd, deadline) - now
        return remaining < deferralResolution ? 0 : remaining
    }

    /// When the quiet window stops holding Quit.
    ///
    /// - Parameters:
    ///   - settleEnd: `LifecycleQuietWindow.settleEnd`: 3 s after the last
    ///     change noted, a carried one included. Not `releaseTime`, which the
    ///     cap brings forward while changes keep coming.
    ///   - outstandingDefaultWrites: Default-device writes the owner issued
    ///     whose completion has not run. The default is about to move, so
    ///     Quit waits until its deadline.
    ///   - generationUnseen: A listener advanced the generation and the owner
    ///     has not armed the window for it yet: counted as a change at `now`.
    /// - Returns: nil when nothing holds Quit; `.infinity` while a write is
    ///   outstanding.
    public static func windowEnd(
        now: TimeInterval,
        settleEnd: TimeInterval?,
        outstandingDefaultWrites: Int,
        generationUnseen: Bool
    ) -> TimeInterval? {
        guard outstandingDefaultWrites == 0 else {
            return .infinity
        }
        guard generationUnseen else {
            return settleEnd
        }
        return max(settleEnd ?? now, now + LifecycleQuietWindow.settle)
    }
}

/// Where Quit has got to, so that the teardown runs exactly once however the
/// termination callbacks arrive.
///
/// The owner calls `request(deferral:)` from `applicationShouldTerminate`,
/// `deferralEnded(remaining:)` each time a deferral it scheduled comes due,
/// and `willTerminate()` from `applicationWillTerminate`, which also covers a
/// termination that never asked.
public struct QuitSequence: Equatable {
    public enum Phase: Equatable {
        /// Quit has not been requested.
        case running
        /// The teardown waits for the deferral.
        case deferring
        /// The teardown has run.
        case tornDown
    }

    /// What the owner does for a Quit request.
    public enum Request: Equatable {
        /// Tear down now, and terminate now.
        case tearDownNow
        /// Tear down after `delay` seconds, then let termination proceed.
        case deferTeardown(delay: TimeInterval)
        /// A teardown is already deferred. Nothing changes: its deadline
        /// stays what the first request fixed.
        case alreadyDeferred
        /// The teardown has run. Terminate now.
        case alreadyTornDown
    }

    /// What the owner does when a deferral it scheduled comes due.
    public enum DeferralEnd: Equatable {
        /// Tear down now, then let termination proceed.
        case tearDown
        /// A change noted since moved the window's end: wait `delay` more.
        case deferAgain(delay: TimeInterval)
        /// Nothing is deferred any more.
        case nothing
    }

    public private(set) var phase: Phase = .running

    public init() {}

    /// A Quit request. `deferral` is read only for the first request.
    public mutating func request(deferral: () -> TimeInterval) -> Request {
        switch phase {
        case .running:
            let delay = deferral()
            guard delay > 0 else {
                phase = .tornDown
                return .tearDownNow
            }
            phase = .deferring
            return .deferTeardown(delay: delay)
        case .deferring:
            return .alreadyDeferred
        case .tornDown:
            return .alreadyTornDown
        }
    }

    /// A deferral the owner scheduled came due. `remaining` is how much
    /// longer the teardown waits now, read only while deferring.
    public mutating func deferralEnded(remaining: () -> TimeInterval) -> DeferralEnd {
        guard phase == .deferring else {
            return .nothing
        }
        let delay = remaining()
        guard delay <= 0 else {
            return .deferAgain(delay: delay)
        }
        phase = .tornDown
        return .tearDown
    }

    /// The application is terminating. Returns whether the teardown has not
    /// run yet, so the owner runs it now.
    public mutating func willTerminate() -> Bool {
        guard phase != .tornDown else {
            return false
        }
        phase = .tornDown
        return true
    }
}
