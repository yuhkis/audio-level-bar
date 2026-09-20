import Foundation

/// What the system playback meter is to do next, and whether the quiet
/// window is holding that back.
///
/// The owner turns monitoring on and off, rebuilds the meter when the output
/// changes, and hears back when a rebuild or stop issued before a window
/// armed was abandoned on its lifecycle queue. While the window holds, each
/// of those only records what is owed, and however many rebuilds were asked
/// for, the evaluation that admits starts acts once. A release that admits
/// stops only leaves a meter that is to be rebuilt running, and keeps the
/// rebuild owed: the full release's rebuild releases it first anyway, and a
/// tap destroyed right after a default-output switch is what the window
/// exists to avoid. It carries out a pending stop. A stop that is owed stays
/// a stop when an abandoned rebuild reports afterwards.
///
/// The owner checks that monitoring is available, and reads the output,
/// before it acts on `.start`.
public struct SystemOutputIntent: Equatable {
    public enum Pending: Equatable {
        case rebuild
        case stop
    }

    public enum Event: Equatable {
        /// Monitoring was turned on, the output changed, the user retried, or
        /// the publication finished: rebuild the meter for the current output.
        /// `holding` is whether starts are held.
        case rebuild(holding: Bool)
        /// Monitoring was turned off. `holding` is whether the window holds
        /// stops too.
        case stop(holding: Bool)
        /// A rebuild issued before a window armed stopped before its next HAL
        /// call. What it built stays until the next rebuild or stop.
        case interrupted(monitoringEnabled: Bool)
        /// A stop issued before a window armed left the meter in place.
        case stopInterrupted(monitoringEnabled: Bool)
        /// The meter's aggregate device or tapped output died, or its levels
        /// stopped arriving. Its levels are already closed; it is rebuilt,
        /// once, after the window and its spacing. A pending stop stays a
        /// stop.
        case invalidated(monitoringEnabled: Bool)
        /// An evaluation the window does not hold. With `startsHeld`, a
        /// release that admits stops only: a pending rebuild stays owed until
        /// starts are admitted, and nothing is issued for it. Without
        /// `rebuildDue`, an invalidated meter's spacing has not passed: a
        /// pending rebuild stays owed, and nothing is issued for it yet.
        /// `rebuildDue` has no default, so no caller can drop the spacing by
        /// leaving it out.
        case release(startsHeld: Bool, rebuildDue: Bool)
    }

    public enum Action: Equatable {
        /// Rebuild the meter now.
        case start
        /// Stop the meter now.
        case stop
        case none
    }

    /// The rebuild or stop the window is holding back. The owner ignores the
    /// meter's callbacks while one is pending, because the tap still running
    /// belongs to the previous output or setting.
    public private(set) var pending: Pending?

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .rebuild(let holding):
            guard !holding else {
                pending = .rebuild
                return .none
            }
            pending = nil
            return .start

        case .stop(let holding):
            guard !holding else {
                pending = .stop
                return .none
            }
            pending = nil
            return .stop

        case .interrupted(let monitoringEnabled), .invalidated(let monitoringEnabled):
            // Runs again, once, after the window. A pending stop stays a stop,
            // and with monitoring off nothing is to be rebuilt.
            if monitoringEnabled, pending == nil {
                pending = .rebuild
            }
            return .none

        case .stopInterrupted(let monitoringEnabled):
            // Issued again, once, after the window. With monitoring on again,
            // the rebuild that is pending or already issued releases what the
            // stop left.
            if !monitoringEnabled, pending == nil {
                pending = .stop
            }
            return .none

        case let .release(startsHeld, rebuildDue):
            switch pending {
            case .rebuild? where startsHeld:
                // The tap on the previous output or setting keeps running,
                // its callbacks ignored, as it did while the window held. The
                // rebuild waits for a release that admits starts, and
                // releases it then.
                return .none
            case .rebuild? where !rebuildDue:
                // An invalidated meter is rebuilt no sooner than its spacing
                // allows. Its levels are closed, and the rebuild releases it
                // first, so nothing is stopped ahead of it.
                return .none
            case .rebuild?:
                pending = nil
                return .start
            case .stop?:
                pending = nil
                return .stop
            case nil:
                return .none
            }
        }
    }
}
