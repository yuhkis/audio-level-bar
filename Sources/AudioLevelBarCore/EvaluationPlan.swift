import Foundation

/// The order of the steps in one lifecycle evaluation.
///
/// The owner's evaluation is the one place that starts and stops the
/// microphone meter and carries out what the quiet window held back. Each
/// step reads state the step before it may have changed, so what a step
/// does is decided when it runs; which steps run, and in what order, is
/// decided here.
///
/// - The cleanup of what an earlier run left behind runs once, at the first
///   evaluation that admits starts, before every other step, so it destroys
///   nothing inside a window and nothing this run built.
/// - The processed microphone goes before the meter, because whether its
///   engines hold the input decides the meter's target.
/// - While the window holds, the steps that could publish, retry a
///   teardown, or rebuild or stop the system playback meter are left out.
/// - While starts are held, publication is left out. The plans and the
///   system playback step see the admission and issue stops only.
/// - An evaluation that releases the window notes the release first and
///   takes it last, so everything it issues sees the window released, and a
///   change carried past the window's cap opens the next window only after
///   this evaluation has acted.
public enum EvaluationPlan {
    public enum Step: Equatable {
        /// Log the release of the window that has ended.
        case noteRelease
        /// Remove the published device an earlier run left behind, then
        /// reclaim its orphaned process taps. See `LaunchCleanup`.
        case cleanUpAfterEarlierRun
        case updateProcessedMicrophoneState
        /// A Retry on a switched-off processed microphone that a window held
        /// back, if one is owed. A teardown, so a stops-only release runs it.
        case retryDisabledProcessedMicrophoneTeardown
        case performProcessedMicrophonePlan
        case evaluateMicrophoneMeter
        case publishMicrophoneDisplay
        /// Publish the processed microphone once the meter runs, if that is
        /// waiting. Publication rebuilds the system playback meter itself
        /// when it succeeds, so it goes before the system playback step.
        case publishProcessedMicrophone
        /// Carry out the system playback rebuild or stop the window held.
        case applySystemOutputIntent
        /// Take the release; a carried change becomes the next window.
        case takeRelease
    }

    /// - Parameters:
    ///   - admission: What the quiet window admits at this evaluation.
    ///   - windowArmed: Whether a window is armed and its release not yet
    ///     taken.
    ///   - launchCleanupOwed: Whether the cleanup of an earlier run's
    ///     leftovers has yet to run.
    public static func steps(
        admission: LifecycleQuietWindow.Admission,
        windowArmed: Bool,
        launchCleanupOwed: Bool
    ) -> [Step] {
        let holding = admission == .hold
        let releasing = !holding && windowArmed
        var steps: [Step] = []
        if releasing {
            steps.append(.noteRelease)
        }
        if admission == .full, launchCleanupOwed {
            steps.append(.cleanUpAfterEarlierRun)
        }
        steps.append(.updateProcessedMicrophoneState)
        if !holding {
            steps.append(.retryDisabledProcessedMicrophoneTeardown)
        }
        steps.append(contentsOf: [
            .performProcessedMicrophonePlan,
            .evaluateMicrophoneMeter,
            .publishMicrophoneDisplay
        ])
        if admission == .full {
            steps.append(.publishProcessedMicrophone)
        }
        if !holding {
            steps.append(.applySystemOutputIntent)
        }
        if releasing {
            steps.append(.takeRelease)
        }
        return steps
    }
}
