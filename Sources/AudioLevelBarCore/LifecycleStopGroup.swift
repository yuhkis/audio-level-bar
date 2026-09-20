import Foundation

/// Runs Quit's stops on their lifecycle queues and waits for them for as long
/// as they keep making progress, within a hard ceiling.
///
/// At Quit the main thread waits for the meters and the capture to stop and
/// destroy what they hold, rather than leave their IOProcs, taps and
/// aggregate devices to process exit. A lifecycle queue can be stuck behind a
/// HAL call that an unresponsive coreaudiod never answers, so the wait must
/// end: a hung server must not hang Quit, or the user reaches for force quit.
/// A fixed total cannot tell a stuck server from a queue that is slow but
/// still getting answers, so each stop reports progress immediately before
/// each HAL call it makes, and the wait goes on while some queue has done so
/// within `idleTimeout`, never beyond `ceiling`.
///
/// The stops run at `.userInteractive`, enforced over their queue's own
/// quality of service, because the waiting main thread donates none.
///
/// The work must not wait for the thread that waits here.
public final class LifecycleStopGroup: @unchecked Sendable {
    /// Where a stop has got to. Reported immediately before the HAL call it
    /// names, so its time is when the call before it returned.
    public enum Phase: String, Equatable {
        /// Handed to its queue, which has not reached it.
        case queued
        case removeListeners = "remove-listeners"
        case readIsRunning = "read-is-running"
        case stopIOProc = "stop-ioproc"
        case destroyIOProc = "destroy-ioproc"
        case destroyAggregate = "destroy-aggregate"
        case destroyTap = "destroy-tap"
        /// Returned.
        case done

        public init(_ step: LifecycleTeardown.Step) {
            switch step {
            case .readIsRunning:
                self = .readIsRunning
            case .stop:
                self = .stopIOProc
            case .destroyIOProc:
                self = .destroyIOProc
            case .destroyAggregate:
                self = .destroyAggregate
            case .destroyProcessTap:
                self = .destroyTap
            }
        }
    }

    /// Handed to a stop's work, which calls `report(_:)` immediately before
    /// each HAL call.
    public struct Progress {
        fileprivate let record: (Phase) -> Void

        public func report(_ phase: Phase) {
            record(phase)
        }
    }

    public struct Outcome: Equatable {
        /// Every stop returned.
        public let completed: Bool
        /// The phase of each stop that had not returned, by label.
        public let pending: [String: Phase]
        /// Seconds the wait took.
        public let waited: TimeInterval

        /// `label:phase` for each pending stop, sorted, comma-separated.
        public var pendingDescription: String {
            pending
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value.rawValue)" }
                .joined(separator: ",")
        }
    }

    private let group = DispatchGroup()
    private let lock = NSLock()
    private var phases: [String: Phase] = [:]
    /// When a stop last reported progress, on `now()`.
    private var lastProgressAt: TimeInterval?

    public init() {}

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Runs `work` on `queue` at `.userInteractive` and counts it until it
    /// returns. `label` names the stop in the outcome and must be unique in
    /// the group.
    public func run(label: String, on queue: DispatchQueue, _ work: @escaping (Progress) -> Void) {
        lock.lock()
        phases[label] = .queued
        lock.unlock()
        group.enter()
        let progress = Progress { [self] phase in
            record(label, phase)
        }
        let item = DispatchWorkItem(qos: .userInteractive, flags: .enforceQoS) { [self] in
            work(progress)
            record(label, .done)
            group.leave()
        }
        queue.async(execute: item)
    }

    private func record(_ label: String, _ phase: Phase) {
        let time = Self.now()
        lock.lock()
        phases[label] = phase
        lastProgressAt = time
        lock.unlock()
    }

    /// Waits until everything given to `run` has returned, while some stop
    /// has reported progress within `idleTimeout`, and for at most `ceiling`
    /// seconds. The wait's own start counts as progress.
    public func wait(idleTimeout: TimeInterval, ceiling: TimeInterval) -> Outcome {
        let start = Self.now()
        while true {
            let deadline = min(start + ceiling, latestProgress(notBefore: start) + idleTimeout)
            let remaining = max(0, deadline - Self.now())
            if group.wait(timeout: .now() + remaining) == .success {
                return outcome(completed: true, start: start)
            }
            let now = Self.now()
            if now - start >= ceiling || now - latestProgress(notBefore: start) >= idleTimeout {
                return outcome(completed: false, start: start)
            }
        }
    }

    private func latestProgress(notBefore start: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return max(start, lastProgressAt ?? start)
    }

    private func outcome(completed: Bool, start: TimeInterval) -> Outcome {
        lock.lock()
        let pending = completed ? [:] : phases.filter { $0.value != .done }
        lock.unlock()
        return Outcome(completed: completed, pending: pending, waited: Self.now() - start)
    }
}
