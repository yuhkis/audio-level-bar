import Foundation

/// Notices a lifecycle call that has not reported back.
///
/// The owner records each call it issues to a lifecycle queue, and each
/// report that the call, or the queue behind it, has come back. A call that
/// goes `timeout` or more without reporting is stalled: its queue is most
/// likely waiting in an unresponsive coreaudiod, and the owner issues nothing
/// further to that queue until it reports. Evaluations read the clock, so
/// the owner passes the same uptime clock the quiet window uses.
public struct LifecycleCallWatch: Equatable {
    /// The same timeout as a microphone meter start.
    public static let timeout: TimeInterval = MeterSession.startTimeout

    /// When the call still outstanding was issued; nil when none is.
    public private(set) var issuedAt: TimeInterval?
    /// Whether the owner has already been told the outstanding call stalled.
    public private(set) var stallNoted = false
    private var latestToken: UInt64 = 0

    public init() {}

    /// Records a call issued at `now`. It replaces any call still outstanding,
    /// and its timeout starts over. The token identifies it to
    /// `report(token:)`.
    @discardableResult
    public mutating func issue(now: TimeInterval) -> UInt64 {
        latestToken &+= 1
        issuedAt = now
        stallNoted = false
        return latestToken
    }

    /// The latest call reported back.
    public mutating func report() {
        issuedAt = nil
        stallNoted = false
    }

    /// The call issued with `token` reported back. A report for a call that a
    /// later one replaced is ignored: the later call may still be waiting.
    public mutating func report(token: UInt64) {
        guard token == latestToken else {
            return
        }
        report()
    }

    public var isOutstanding: Bool {
        issuedAt != nil
    }

    /// Whether the outstanding call has gone `timeout` or more without
    /// reporting.
    public func isStalled(now: TimeInterval, timeout: TimeInterval = LifecycleCallWatch.timeout) -> Bool {
        guard let issuedAt else {
            return false
        }
        return now - issuedAt >= timeout
    }

    /// True the first time the outstanding call is seen stalled, so the
    /// owner logs it once.
    public mutating func noteStall(now: TimeInterval) -> Bool {
        guard !stallNoted, isStalled(now: now) else {
            return false
        }
        stallNoted = true
        return true
    }
}
