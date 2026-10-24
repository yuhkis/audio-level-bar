import Foundation

/// Whether the running system playback meter is still delivering levels, and
/// how far apart the rebuilds it asks for are spaced.
///
/// The meter's tap and private aggregate device can die, or stop delivering,
/// with the default output's ID unchanged, as across sleep and wake: then no
/// poll sees a change and nothing would rebuild it. Two signals reach the
/// owner, and neither makes a HAL call. The meter's listeners on the
/// aggregate device and on the tapped output report an invalidation. On the
/// main thread, the owner feeds each level it shows here and asks, at every
/// evaluation, whether levels have stopped arriving.
///
/// A level arrives at least four times a second while the IO runs, and a
/// silent buffer still arrives as a level of -inf dB, so silence is never
/// stale. No level for `staleDisplayAfter` shows the meter starting again; no
/// level for `rebuildAfterSilence` counts as an invalidation. The owner then
/// arms the quiet window and owes a rebuild, which the evaluation after the
/// window carries out no earlier than `rebuildNotBefore`: 2, 4, then 8 s after
/// the invalidation, as `MeterSession` spaces the microphone meter's
/// restarts, and back to 2 s once the meter has run `stableRunDuration`
/// without one.
///
/// The rebuilds are capped. The `maximumConsecutiveInvalidations`th
/// invalidation in a row, with no run of `stableRunDuration` between them,
/// is not rebuilt: an output that keeps dying or reconfiguring under the
/// meter would otherwise have a tap and an aggregate device created and
/// destroyed on it every 8 s for as long as it does. The owner then shows the
/// meter failed with Retry, and issues nothing for it, neither a rebuild nor
/// a stop, until the user retries or turns monitoring on, or the output
/// device changes (`startOver()`).
///
/// Sleep suspends all of it. From the system's will-sleep to its did-wake
/// the Mac's dark wakes still run the owner's timers, while the output
/// delivers nothing and the HAL reconfigures the built-in devices; counted,
/// that silence rebuilt the meter every 12 s and gave up before the wake. So
/// while asleep no silence is checked, an invalidation is neither counted
/// nor spaced, and no rebuild is due. The wake starts the count over and
/// owes one rebuild, due as soon as the quiet window the owner arms for it
/// releases (`didWake()`).
///
/// Times are on the owner's lifecycle clock.
public struct SystemOutputRecovery: Equatable {
    public static let staleDisplayAfter: TimeInterval = 2
    public static let rebuildAfterSilence: TimeInterval = 4
    public static let maximumRetryDelay: TimeInterval = MeterSession.maximumRetryDelay
    public static let stableRunDuration: TimeInterval = MeterSession.stableRunDuration
    /// The invalidation in a row that is no longer rebuilt, as
    /// `MeterSession` stops starting the microphone meter after as many
    /// failed attempts.
    public static let maximumConsecutiveInvalidations = MeterSession.maximumStartAttempts

    public enum Check: Equatable {
        case none
        /// No level for `staleDisplayAfter`: reset the levels and show the
        /// meter starting. Reported once per silence.
        case showStale
        /// No level for `rebuildAfterSilence`: treat it as an invalidation.
        /// The owner reports it with `invalidated(at:)`.
        case rebuild
    }

    private enum Phase: Equatable {
        /// No start has reported, or the meter was stopped, replaced or
        /// invalidated since.
        case idle
        case running(since: TimeInterval, lastLevelAt: TimeInterval, shownStale: Bool)
    }

    private var phase: Phase = .idle
    /// Between the system's will-sleep and its did-wake.
    public private(set) var isAsleep = false
    /// Invalidations since the meter last ran `stableRunDuration` without
    /// one.
    public private(set) var consecutiveInvalidations = 0
    /// The latest invalidation's earliest rebuild time. A stop, an abandoned
    /// build or a moved output keeps it, so an invalidation that lands while
    /// a build is on its way is still spaced; only an issued rebuild and a
    /// reset clear it. nil when no invalidation is waiting, or when the
    /// rebuilds are exhausted.
    public private(set) var rebuildNotBefore: TimeInterval?

    public init() {}

    /// Whether the invalidations in a row reached
    /// `maximumConsecutiveInvalidations`. No rebuild is due until
    /// `startOver()`.
    public var rebuildsExhausted: Bool {
        consecutiveInvalidations >= Self.maximumConsecutiveInvalidations
    }

    /// Whether levels are being watched.
    public var isWatching: Bool {
        phase != .idle
    }

    /// The meter reported that it started at `time`.
    public mutating func started(at time: TimeInterval) {
        phase = .running(since: time, lastLevelAt: time, shownStale: false)
    }

    /// A level was shown at `time`, whatever its value.
    public mutating func level(at time: TimeInterval) {
        guard case let .running(since, _, _) = phase else {
            return
        }
        phase = .running(since: since, lastLevelAt: time, shownStale: false)
    }

    /// The meter was stopped, or a start ended without reporting it started.
    /// Levels are not watched until the next start. The backoff count and the
    /// spacing stay: a listener that fires on the meter's own build, and so
    /// abandons that build, must not bring the next rebuild forward.
    public mutating func stopped() {
        phase = .idle
    }

    /// A rebuild was issued. Levels are watched again once it reports it
    /// started, and the spacing it waited for is spent.
    public mutating func rebuildIssued() {
        phase = .idle
        rebuildNotBefore = nil
    }

    /// A listener reported the meter invalidated at `time`, or `check(at:)`
    /// returned `.rebuild`.
    public mutating func invalidated(at time: TimeInterval) {
        guard !isAsleep else {
            // Owed to the wake's rebuild: neither counted nor spaced.
            phase = .idle
            return
        }
        if case let .running(since, _, _) = phase, time - since >= Self.stableRunDuration {
            consecutiveInvalidations = 0
        }
        consecutiveInvalidations += 1
        phase = .idle
        rebuildNotBefore = rebuildsExhausted
            ? nil
            : time + Self.backoffDelay(occurrence: consecutiveInvalidations)
    }

    /// Monitoring was turned off.
    public mutating func reset() {
        let asleep = isAsleep
        self = SystemOutputRecovery()
        isAsleep = asleep
    }

    /// The system is going to sleep. Levels are not watched, invalidations
    /// are not counted, and no rebuild is due until `didWake()`.
    public mutating func willSleep() {
        isAsleep = true
        phase = .idle
    }

    /// The system woke. Whatever the meter held may not have survived the
    /// sleep, so the owner owes it one rebuild: the invalidations in a row
    /// count from zero, rebuilds that gave up start over, and the rebuild is
    /// due with no spacing. Levels are watched again once it reports it
    /// started.
    public mutating func didWake() {
        isAsleep = false
        phase = .idle
        consecutiveInvalidations = 0
        rebuildNotBefore = nil
    }

    /// The user retried or turned monitoring on, or the output device
    /// changed: the invalidations in a row count from zero again, so the
    /// rebuild owed is due and the next invalidation is rebuilt, spaced from
    /// 2 s. The spacing an earlier invalidation set stays until a rebuild is
    /// issued.
    public mutating func startOver() {
        consecutiveInvalidations = 0
    }

    /// coreaudiod restarted. What the meter held went with it, so its levels
    /// and spacing are forgotten, but rebuilds that were exhausted stay
    /// exhausted: a restart is neither a retry nor another output.
    public mutating func serviceRestarted() {
        let exhausted = rebuildsExhausted
        let asleep = isAsleep
        self = SystemOutputRecovery()
        isAsleep = asleep
        if exhausted {
            consecutiveInvalidations = Self.maximumConsecutiveInvalidations
        }
    }

    /// Whether levels have stopped arriving by `time`.
    public mutating func check(at time: TimeInterval) -> Check {
        guard !isAsleep, case let .running(since, lastLevelAt, shownStale) = phase else {
            return .none
        }
        let silence = time - lastLevelAt
        if silence >= Self.rebuildAfterSilence {
            return .rebuild
        }
        if silence >= Self.staleDisplayAfter, !shownStale {
            phase = .running(since: since, lastLevelAt: lastLevelAt, shownStale: true)
            return .showStale
        }
        return .none
    }

    /// Whether an owed rebuild may be issued at `time`: never while the
    /// rebuilds are exhausted or the system is asleep.
    public func rebuildIsDue(at time: TimeInterval) -> Bool {
        guard !rebuildsExhausted, !isAsleep else {
            return false
        }
        guard let rebuildNotBefore else {
            return true
        }
        return time >= rebuildNotBefore
    }

    /// 2, 4, then 8 seconds for the first, second, and later occurrences.
    private static func backoffDelay(occurrence: Int) -> TimeInterval {
        min(pow(2, Double(occurrence)), maximumRetryDelay)
    }
}
