import Foundation

/// The cleanup of what an earlier run left behind: a published device and
/// orphaned process taps.
///
/// It runs once, from the first evaluation after launch whose release admits
/// starts, and before anything else that evaluation issues. Never inside the
/// launch window, where a headset connecting at login may still be
/// reconfiguring, and never after this run could have built a tap of its own,
/// which the reclaim would take for a leftover: starts stay held until it has
/// run.
///
/// The published device goes first, because its tap is its only input. If a
/// consuming app still has that device open, or removing it fails, no tap is
/// reclaimed, since the tap under it could be the one the consumer records
/// from. The reclaim is owed instead, and runs for the published microphone's
/// taps once a later teardown of the publication completes.
///
/// The cleanup's destroys are held by the quiet window like any other: each
/// is compared against the generation the evaluation that issued it saw. One
/// that a window holds back leaves the cleanup owed as it was before. The
/// owner reports no outcome for a stale removal that was held back, and
/// `reclaimInterrupted(_:)` for a reclaim. Starts then stay held, and the
/// release after the window runs the cleanup again from the start: what is
/// already gone is not found again.
public struct LaunchCleanup: Equatable {
    public enum Phase: Equatable {
        /// Nothing has run yet.
        case owed
        /// The earlier publication could not be removed; its taps wait for a
        /// completed teardown.
        case reclaimOwed
        case done
    }

    /// How removing the earlier run's published device went.
    public enum StaleRemoval: Equatable {
        /// Removed, or there was none.
        case completed
        /// A consuming app has it open, so it was left alone.
        case inUse
        case failed
    }

    public enum Action: Equatable {
        case none
        case reclaim(TapReclaimScope)
    }

    public private(set) var phase: Phase = .owed

    public init() {}

    /// Whether the cleanup has yet to run. Starts are held until it has.
    public var isOwed: Bool {
        phase == .owed
    }

    /// Whether starts are held under `admission`: the quiet window does not
    /// admit them, or the cleanup has yet to run. Outside an evaluation, as
    /// for a rebuild the user asks for, a window can release before the next
    /// evaluation runs the cleanup; a tap built then, not yet listed by its
    /// aggregate device, would be reclaimed as a leftover.
    public func holdsStarts(admission: LifecycleQuietWindow.Admission) -> Bool {
        admission != .full || isOwed
    }

    public mutating func staleRemovalFinished(_ outcome: StaleRemoval) -> Action {
        guard phase == .owed else {
            return .none
        }
        switch outcome {
        case .completed:
            phase = .done
            return .reclaim(.everyTapOfThisApp)
        case .inUse, .failed:
            phase = .reclaimOwed
            return .none
        }
    }

    /// A teardown of the publication completed: the earlier run's device is
    /// gone, and with it the reason its taps were kept.
    public mutating func publicationTeardownCompleted() -> Action {
        guard phase == .reclaimOwed else {
            return .none
        }
        phase = .done
        return .reclaim(.publishedMicrophoneTaps)
    }

    /// The reclaim the last action asked for ended before one of its
    /// destroys, because a quiet window armed after it was issued. It is
    /// owed again as it was before that action: the whole cleanup for every
    /// tap of this app, which keeps starts held until it has run, and a
    /// completed teardown for the published microphone's taps.
    public mutating func reclaimInterrupted(_ scope: TapReclaimScope) {
        guard phase == .done else {
            return
        }
        switch scope {
        case .everyTapOfThisApp:
            phase = .owed
        case .publishedMicrophoneTaps:
            phase = .reclaimOwed
        }
    }
}
