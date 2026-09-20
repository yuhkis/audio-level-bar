import Foundation

/// Why the microphone level is shown as `--` rather than measured.
public enum MeterNotMeasuredReason: Equatable {
    case notAuthorized
    case noDevice
    case transportNotRead
    /// A Bluetooth microphone, or an aggregate device with a Bluetooth member
    /// or a member that cannot be resolved.
    case bluetooth
    /// The processed microphone owns the input and reports its level.
    case handedOff

    public init(_ refusal: InputOpenRefusal) {
        switch refusal {
        case .noDevice:
            self = .noDevice
        case .transportNotRead:
            self = .transportNotRead
        // A member that cannot be resolved counts as Bluetooth.
        case .bluetooth, .aggregateWithBluetoothMember, .aggregateWithUnresolvedMember:
            self = .bluetooth
        }
    }
}

/// Decides when the microphone meter starts, stops, or is left alone.
///
/// The owner feeds it the target from each poll and the meter's own events,
/// and performs the action it returns. Restarts are decided here, on the next
/// evaluation, never inside a property listener or the IO callback. While the
/// quiet window holds it never returns an action, but the display follows the
/// new target at once.
///
/// Restarts are spaced here too, whatever the owner does with the quiet
/// window: a failed start, a start refused because the device's transport
/// could not be read, and an invalidation all wait 2, 4, then 8 seconds
/// before the next start on the same device. A device whose listener fires on
/// the meter's own start is therefore never reopened on every poll.
///
/// While a start has not reported back, nothing further is issued for the
/// meter, whatever the target: a stop or a start on another device would only
/// queue behind it, and a start that then hangs would never be seen stalled.
/// The next evaluation after the start reports acts on the target.
///
/// An invalidation that arrives while a start has not reported back is
/// recorded, not applied: the start stays in flight, so a stalled start
/// stays stalled. The invalidation is applied when that start reports it
/// started, with its delay counted from that report, since nothing could be
/// restarted before it; it is dropped when the start reports anything else.
/// A change of target does not drop it.
public struct MeterSession: Equatable {
    public static let maximumStartAttempts = 8
    public static let maximumRetryDelay: TimeInterval = 8
    /// How long the meter has to run on a device, as seen by evaluations,
    /// before the next invalidation starts its backoff over.
    public static let stableRunDuration: TimeInterval = 30
    /// How long a start may go without reporting back, as seen by
    /// evaluations, before the meter counts it as stalled.
    public static let startTimeout: TimeInterval = 10

    public enum Phase: Equatable {
        case stopped
        case starting(UInt32)
        case running(UInt32)
        /// The device's configuration changed under the running meter. It is
        /// started again no earlier than `retryAt`.
        case invalidated(UInt32, retryAt: TimeInterval)
        case failed(UInt32, attempts: Int, retryAt: TimeInterval)
        /// The meter re-read the device's transport and refused to open it
        /// because it involves Bluetooth, or the device ID was unknown. A
        /// transport that could not be read is a failed attempt instead.
        case refused(UInt32, MeterNotMeasuredReason)
        /// A quiet window armed after the start was issued, and the meter
        /// stopped before its next HAL call. Whatever it created stays until
        /// the next start or stop.
        case interrupted(UInt32)
        /// A quiet window armed after a stop was issued, and the meter kept
        /// what it held rather than stop it inside the window. It no longer
        /// reports levels, and the next evaluation after the window stops it
        /// again, or starts the meter on the target, which releases it first.
        case stopInterrupted
        /// The start issued `startTimeout` or more ago has not reported back:
        /// its lifecycle queue is most likely waiting in an unresponsive
        /// coreaudiod. Nothing further is issued for the meter, neither a
        /// stop nor a start, until that start reports.
        case stalled(UInt32)
    }

    public enum Target: Equatable {
        case notMeasured(MeterNotMeasuredReason)
        case device(UInt32)

        public static func input(deviceID: UInt32, decision: InputOpenDecision) -> Target {
            switch decision {
            case .open:
                return .device(deviceID)
            case .refuse(let refusal):
                return .notMeasured(MeterNotMeasuredReason(refusal))
            }
        }
    }

    public enum Display: Equatable {
        case live
        case starting
        case notMeasured(MeterNotMeasuredReason)
    }

    public enum Event: Equatable {
        /// - `holding`: the quiet window holds every lifecycle change.
        /// - `startsHeld`: starts are held, as while the window holds or at a
        ///   release that admits stops only. The evaluation may still stop a
        ///   meter that has nothing to measure or holds a device other than
        ///   the target, but never starts one.
        case evaluate(target: Target, holding: Bool, startsHeld: Bool, now: TimeInterval)
        /// `now` is when the start reported; a pending invalidation's delay
        /// counts from then.
        case started(UInt32, now: TimeInterval)
        case startFailed(UInt32, now: TimeInterval)
        /// A refusal because the transport could not be read counts as a
        /// failed attempt, retried after its delay; the other refusals latch
        /// until the target changes.
        case refusedAtStart(UInt32, InputOpenRefusal, now: TimeInterval)
        case invalidated(UInt32, now: TimeInterval)
        case startInterrupted(UInt32)
        /// The stop the last `.stop` action issued did not reach the HAL.
        case stopInterrupted
        case stopRequested
        /// coreaudiod restarted. Whatever the meter held went with the old
        /// server, and a start in flight belongs to it. The session forgets
        /// both without issuing anything; the next evaluation that admits
        /// starts starts the meter on the target.
        case serviceRestarted
    }

    public enum Action: Equatable {
        case start(UInt32)
        case stop
    }

    public private(set) var phase: Phase = .stopped
    /// The target of the last evaluation; nil before the first.
    public private(set) var target: Target?
    private var failuresBeforeCurrentStart = 0
    /// Invalidations of the current target with no stable run in between.
    private var consecutiveInvalidations = 0
    /// The device an evaluation first saw running, and when.
    private var runningSinceDevice: UInt32?
    private var runningSince: TimeInterval = 0
    /// When the latest start was issued.
    private var startIssuedAt: TimeInterval = 0
    /// When an invalidation arrived for the start in flight, which has not
    /// reported back yet.
    private var pendingInvalidationAt: TimeInterval?

    public init() {}

    public var display: Display {
        switch target {
        case nil:
            return .starting
        case .notMeasured(let reason)?:
            return .notMeasured(reason)
        case .device(let deviceID)?:
            switch phase {
            case .running(let running) where running == deviceID:
                return .live
            case .refused(let refused, let reason) where refused == deviceID:
                return .notMeasured(reason)
            default:
                return .starting
            }
        }
    }

    /// Whether the meter gave up on the device after repeated start failures.
    /// A change of target starts over, and so do a requested stop, which is
    /// how the owner's Retry starts it over, and a coreaudiod restart.
    public var retriesExhausted: Bool {
        guard case .failed(_, let attempts, _) = phase else {
            return false
        }
        return attempts >= Self.maximumStartAttempts
    }

    /// Whether a start was issued and has not reported back, stalled or not.
    /// A stop issued now would only queue behind it.
    public var hasStartInFlight: Bool {
        switch phase {
        case .starting, .stalled:
            return true
        default:
            return false
        }
    }

    /// Whether an invalidation arrived for the start in flight and waits for
    /// that start to report.
    public var hasPendingInvalidation: Bool {
        pendingInvalidationAt != nil
    }

    /// Whether the latest start has not reported back within `startTimeout`.
    public var isStalled: Bool {
        if case .stalled = phase {
            return true
        }
        return false
    }

    /// 2, 4, then 8 seconds for the first, second, and later occurrences.
    private static func backoffDelay(occurrence: Int) -> TimeInterval {
        min(pow(2, Double(occurrence)), maximumRetryDelay)
    }

    public mutating func handle(_ event: Event) -> Action? {
        switch event {
        case let .evaluate(target, holding, startsHeld, now):
            return evaluate(target, holding: holding, startsHeld: startsHeld || holding, now: now)

        case let .started(deviceID, now):
            if startIsInFlight(on: deviceID) {
                if let invalidatedAt = pendingInvalidationAt {
                    // The device reconfigured while the start was on its way,
                    // and its capture gate is already closed: nothing will
                    // be measured until it is started again. A start that
                    // reports long after, from a server that has just
                    // answered again, still waits its delay from now.
                    invalidate(deviceID, at: max(invalidatedAt, now))
                } else {
                    phase = .running(deviceID)
                    failuresBeforeCurrentStart = 0
                    runningSinceDevice = nil
                }
            }
            return nil

        case let .startFailed(deviceID, now):
            if startIsInFlight(on: deviceID) {
                failAttempt(on: deviceID, now: now)
            }
            return nil

        case let .refusedAtStart(deviceID, refusal, now):
            if startIsInFlight(on: deviceID) {
                switch refusal {
                case .transportNotRead, .aggregateWithUnresolvedMember:
                    // Most likely a read that failed once: a transport, a
                    // member list or a member's UID. A start is issued only
                    // for a device the poll judged open, so an aggregate
                    // member that only this read could not resolve is a read
                    // that disagreed with the poll, not evidence of
                    // Bluetooth. A member that is really absent shows in the
                    // poll's own read, which then issues no start. Retried
                    // after its delay, and counted toward the cap, never on
                    // every poll.
                    failAttempt(on: deviceID, now: now)
                case .bluetooth, .aggregateWithBluetoothMember, .noDevice:
                    pendingInvalidationAt = nil
                    phase = .refused(deviceID, MeterNotMeasuredReason(refusal))
                    failuresBeforeCurrentStart = 0
                }
            }
            return nil

        case let .invalidated(deviceID, now):
            switch phase {
            case .starting(let current) where current == deviceID,
                 .stalled(let current) where current == deviceID:
                // The start keeps its phase, so a stall stays a stall and
                // nothing is issued behind it.
                if pendingInvalidationAt == nil {
                    pendingInvalidationAt = now
                }
            case .running(let current) where current == deviceID:
                invalidate(deviceID, at: now)
            default:
                break
            }
            return nil

        case .startInterrupted(let deviceID):
            if startIsInFlight(on: deviceID) {
                // Neither a failure nor an invalidation, so both counts stay.
                pendingInvalidationAt = nil
                phase = .interrupted(deviceID)
            }
            return nil

        case .stopInterrupted:
            // Only the latest action can have been a stop; a start issued
            // since has replaced it and releases what the meter held.
            if phase == .stopped {
                phase = .stopInterrupted
            }
            return nil

        case .stopRequested:
            // A stop issued against a server that has not answered the start
            // would only queue behind it, and start a teardown there once it
            // does. Nothing is issued until the start reports.
            guard !isStalled else {
                return nil
            }
            return issueStop()

        case .serviceRestarted:
            phase = .stopped
            failuresBeforeCurrentStart = 0
            consecutiveInvalidations = 0
            runningSinceDevice = nil
            pendingInvalidationAt = nil
            return nil
        }
    }

    /// A start on `deviceID` that failed or could not read the transport.
    private mutating func failAttempt(on deviceID: UInt32, now: TimeInterval) {
        pendingInvalidationAt = nil
        let attempts = failuresBeforeCurrentStart + 1
        phase = .failed(
            deviceID,
            attempts: attempts,
            retryAt: now + Self.backoffDelay(occurrence: attempts)
        )
        failuresBeforeCurrentStart = 0
    }

    /// The device's configuration changed under the meter at `time`.
    private mutating func invalidate(_ deviceID: UInt32, at time: TimeInterval) {
        pendingInvalidationAt = nil
        consecutiveInvalidations += 1
        phase = .invalidated(
            deviceID,
            retryAt: time + Self.backoffDelay(occurrence: consecutiveInvalidations)
        )
        failuresBeforeCurrentStart = 0
        runningSinceDevice = nil
    }

    private mutating func evaluate(
        _ newTarget: Target,
        holding: Bool,
        startsHeld: Bool,
        now: TimeInterval
    ) -> Action? {
        if let target, target != newTarget {
            forgetOutcomeForPreviousTarget()
        }
        target = newTarget
        // Noticed while the quiet window holds too, so the error shows.
        noteStalledStart(now: now)

        // A start that has not reported back, stalled or not, holds every
        // further action: a stop, or a start on another target, would queue
        // behind it on the lifecycle queue.
        guard !holding, !hasStartInFlight else {
            return nil
        }

        switch newTarget {
        case .notMeasured:
            guard phase != .stopped else {
                return nil
            }
            return issueStop()

        case .device(let deviceID) where startsHeld:
            return stopWithoutStarting(target: deviceID, now: now)

        case .device(let deviceID):
            switch phase {
            case .running(let current) where current == deviceID:
                noteRunning(deviceID, now: now)
                return nil
            case .starting(let current) where current == deviceID:
                return nil
            case .refused(let current, _) where current == deviceID:
                return nil
            case let .invalidated(current, retryAt) where current == deviceID:
                guard now >= retryAt else {
                    return nil
                }
                failuresBeforeCurrentStart = 0
                return issueStart(deviceID, now: now)
            case .interrupted(let current) where current == deviceID:
                return issueStart(deviceID, now: now)
            case let .failed(current, attempts, retryAt) where current == deviceID:
                guard attempts < Self.maximumStartAttempts, now >= retryAt else {
                    return nil
                }
                failuresBeforeCurrentStart = attempts
                return issueStart(deviceID, now: now)
            default:
                failuresBeforeCurrentStart = 0
                consecutiveInvalidations = 0
                return issueStart(deviceID, now: now)
            }
        }
    }

    private mutating func issueStart(_ deviceID: UInt32, now: TimeInterval) -> Action {
        phase = .starting(deviceID)
        startIssuedAt = now
        pendingInvalidationAt = nil
        return .start(deviceID)
    }

    private mutating func issueStop() -> Action {
        phase = .stopped
        failuresBeforeCurrentStart = 0
        consecutiveInvalidations = 0
        runningSinceDevice = nil
        pendingInvalidationAt = nil
        return .stop
    }

    /// An evaluation whose starts are held, for a device target. Whatever the
    /// meter holds, or may still hold, on another device is stopped, and so
    /// is a stop a window interrupted, whose device is not known here. A
    /// meter on the target itself stays as it is until starts are admitted.
    private mutating func stopWithoutStarting(target deviceID: UInt32, now: TimeInterval) -> Action? {
        switch phase {
        case .stopped, .starting, .stalled:
            // Nothing is held, or a start has not reported back: a stop now
            // would only queue behind it.
            return nil
        case .running(let current) where current == deviceID:
            noteRunning(deviceID, now: now)
            return nil
        case .invalidated(let current, _) where current == deviceID,
             .failed(let current, _, _) where current == deviceID,
             .refused(let current, _) where current == deviceID,
             .interrupted(let current) where current == deviceID:
            return nil
        case .running, .invalidated, .failed, .refused, .interrupted, .stopInterrupted:
            return issueStop()
        }
    }

    /// A start that has not reported back within `startTimeout` is stalled.
    private mutating func noteStalledStart(now: TimeInterval) {
        guard
            case .starting(let deviceID) = phase,
            now - startIssuedAt >= Self.startTimeout
        else {
            return
        }
        phase = .stalled(deviceID)
    }

    /// Whether the latest start, stalled or not, is for this device and has
    /// not reported back yet.
    private func startIsInFlight(on deviceID: UInt32) -> Bool {
        switch phase {
        case .starting(let current), .stalled(let current):
            return current == deviceID
        default:
            return false
        }
    }

    /// A run long enough without an invalidation starts the backoff over.
    private mutating func noteRunning(_ deviceID: UInt32, now: TimeInterval) {
        guard runningSinceDevice == deviceID else {
            runningSinceDevice = deviceID
            runningSince = now
            return
        }
        if now - runningSince >= Self.stableRunDuration {
            consecutiveInvalidations = 0
        }
    }

    /// A change of target starts the retry and invalidation counts over and
    /// lifts a refusal or a wait. A failed or invalidated start keeps a phase
    /// other than `.stopped`, so a target with nothing to measure still sends
    /// a stop for whatever it left.
    private mutating func forgetOutcomeForPreviousTarget() {
        consecutiveInvalidations = 0
        // A pending invalidation belongs to the start in flight, not to the
        // target: its capture gate is closed wherever the target goes, even
        // back to the same device. It stays until that start reports.
        switch phase {
        case .failed(let deviceID, _, _):
            phase = .failed(deviceID, attempts: 0, retryAt: -.infinity)
        case .invalidated(let deviceID, _):
            phase = .invalidated(deviceID, retryAt: -.infinity)
        case .refused:
            // The meter refuses before it creates anything.
            phase = .stopped
        default:
            break
        }
    }
}
