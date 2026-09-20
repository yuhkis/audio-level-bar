import Foundation

/// Paces HAL resource lifecycle changes after device or default changes.
///
/// A Bluetooth device that connects or disconnects, or a default device that
/// changes, sets off configuration changes inside coreaudiod. Creating,
/// starting, stopping or destroying an IOProc, tap or aggregate device while
/// those are still settling is what the window avoids: after each change it
/// holds for `settle` seconds after the last change, never longer than `cap`
/// seconds after the first, and then releases.
///
/// The cap is hard. A change noted before the cap extends the window, even
/// when its settle period had already run out and the release was not taken
/// yet. Only a change noted at or after the cap is carried into the next
/// window, which opens when the owner takes the release. Changes that never
/// stop therefore still let the owner act at least every `cap` seconds, as
/// long as polls keep applying; with no poll issued at or after the window's
/// end applied, the window holds stops too.
///
/// Acting is split by `admission(at:freshestSnapshotIssuedAt:outstandingDefaultWrites:)`.
/// Starting late is safe, and starting inside a configuration change is the
/// hazard, so a release forced by the cap, or with a change carried past it,
/// admits stops only. Starts wait for a full release: `settle` seconds with no
/// change, and no default-device write of the owner's outstanding. Either
/// release also waits for a poll issued at or after the window's end to have
/// applied. No evaluation admits starts while a default-device write is
/// outstanding, armed or not.
///
/// The owner feeds a monotonic clock such as
/// `ProcessInfo.processInfo.systemUptime`. The window only defers; it never
/// decides a teardown by itself.
public struct LifecycleQuietWindow: Equatable {
    public static let settle: TimeInterval = 3
    public static let cap: TimeInterval = 15

    /// What an evaluation may issue.
    public enum Admission: Equatable {
        /// Nothing: no create, start, stop or destroy.
        case hold
        /// Stops, destroys and owed teardowns. No create, start, publication,
        /// processing start or restart.
        case stopsOnly
        /// Everything.
        case full
    }

    public private(set) var firstChange: TimeInterval?
    public private(set) var lastChange: TimeInterval?
    /// The first and last change noted at or after the armed window's cap and
    /// before its release was taken. They become the next window when the
    /// release is taken.
    public private(set) var carriedFirstChange: TimeInterval?
    public private(set) var carriedLastChange: TimeInterval?

    public init() {}

    /// Whether a change has been noted and its release not yet taken.
    public var isArmed: Bool {
        lastChange != nil
    }

    /// Whether a change is waiting to open the next window once the release
    /// of the current one is taken.
    public var hasCarriedChange: Bool {
        carriedLastChange != nil
    }

    /// When the armed window ends. nil when the window is not armed.
    public var releaseTime: TimeInterval? {
        guard let firstChange, let lastChange else {
            return nil
        }
        return Self.releaseTime(first: firstChange, last: lastChange)
    }

    /// When `settle` seconds will have passed since the last change noted, a
    /// change carried past the cap included. Unlike `releaseTime`, the cap
    /// does not bring it forward: a release the cap forces admits stops only
    /// until then. nil when the window is not armed.
    public var settleEnd: TimeInterval? {
        guard let lastChange else {
            return nil
        }
        return max(lastChange, carriedLastChange ?? lastChange) + Self.settle
    }

    public mutating func noteChange(at now: TimeInterval) {
        guard let firstChange, let lastChange else {
            self.firstChange = now
            self.lastChange = now
            return
        }

        let now = max(now, carriedLastChange ?? lastChange)
        if carriedLastChange != nil || now >= firstChange + Self.cap {
            // The window has reached its cap and its release is owed. This
            // change opens the window after it.
            if carriedFirstChange == nil {
                carriedFirstChange = now
            }
            carriedLastChange = now
            return
        }
        // Before the cap a change holds again, even once the settle period
        // has run out and the release is still untaken, so nothing starts on
        // a topology that has just changed.
        self.lastChange = now
    }

    public func isHolding(at now: TimeInterval) -> Bool {
        guard let lastChange, let releaseTime else {
            return false
        }
        // A carried change exists only once the window has reached its cap.
        guard carriedLastChange == nil else {
            return false
        }
        return max(now, lastChange) < releaseTime
    }

    /// What an evaluation at `now` may issue.
    ///
    /// - Parameters:
    ///   - freshestSnapshotIssuedAt: When the newest poll that has applied was
    ///     issued, on the same clock; nil before the first. A release waits
    ///     until a poll issued at or after the window's end has applied, so
    ///     it never acts on a topology read before a change it has not seen.
    ///     With no such poll, the window keeps holding, past the cap too.
    ///   - outstandingDefaultWrites: Default-device writes the owner has
    ///     issued whose completion has not run. They hold the window until
    ///     its cap, so a write that waits behind a slow poll cannot let a
    ///     stale poll release the window just before the default moves, and
    ///     past the cap they still admit stops only. A window disarmed while
    ///     one is outstanding admits stops only too.
    public func admission(
        at now: TimeInterval,
        freshestSnapshotIssuedAt: TimeInterval?,
        outstandingDefaultWrites: Int
    ) -> Admission {
        guard let firstChange, let lastChange, let releaseTime else {
            // A carried window whose release was taken before a pick can
            // disarm with that pick's write still waiting behind the HAL
            // queue. Nothing starts just before the default moves.
            return outstandingDefaultWrites > 0 ? .stopsOnly : .full
        }
        let now = max(now, lastChange)
        if isHolding(at: now) {
            return .hold
        }
        if outstandingDefaultWrites > 0, now < firstChange + Self.cap {
            return .hold
        }
        guard let freshestSnapshotIssuedAt, freshestSnapshotIssuedAt >= releaseTime else {
            return .hold
        }
        if hasCarriedChange || now - lastChange < Self.settle || outstandingDefaultWrites > 0 {
            return .stopsOnly
        }
        return .full
    }

    /// What an evaluation on the owner's thread may issue, given the window's
    /// own `admission` and the generation that thread has armed the window
    /// for.
    ///
    /// A listener advances the generation on its own queue before the owner's
    /// thread hears of the change. Until the owner has armed the window for
    /// that advance, the window alone still reads unarmed, and a start the
    /// owner issued then would take the advanced generation and pass every
    /// check. A generation the owner has not seen therefore holds; the owner
    /// arms the window for it.
    public static func admission(
        _ windowAdmission: Admission,
        generationSeenByOwner: UInt64,
        currentGeneration: UInt64
    ) -> Admission {
        generationSeenByOwner == currentGeneration ? windowAdmission : .hold
    }

    /// Takes the release of the armed window, at or after its end. The owner
    /// calls it only at an evaluation `admission` did not hold, after that
    /// evaluation has acted.
    ///
    /// A change carried past the cap then becomes the armed window. A release
    /// the cap forced within `settle` seconds of the last change keeps that
    /// change's remaining settle period as the armed window, so the starts
    /// the release held back still wait for it. Otherwise the window is
    /// disarmed.
    public mutating func takeRelease(at now: TimeInterval) -> Bool {
        guard let lastChange, let releaseTime else {
            return false
        }
        let now = max(now, lastChange)
        guard carriedLastChange != nil || now >= releaseTime else {
            return false
        }
        if carriedLastChange != nil {
            firstChange = carriedFirstChange
            self.lastChange = carriedLastChange
        } else if now - lastChange < Self.settle {
            firstChange = lastChange
        } else {
            firstChange = nil
            self.lastChange = nil
        }
        carriedFirstChange = nil
        carriedLastChange = nil
        return true
    }

    private static func releaseTime(first: TimeInterval, last: TimeInterval) -> TimeInterval {
        min(last + settle, first + cap)
    }
}

/// The parts of the audio device topology whose changes arm the quiet window.
public struct AudioTopology: Equatable {
    public var defaultInput: UInt32
    public var defaultOutput: UInt32
    public var bluetoothDeviceIDs: Set<UInt32>

    public init(defaultInput: UInt32, defaultOutput: UInt32, bluetoothDeviceIDs: Set<UInt32>) {
        self.defaultInput = defaultInput
        self.defaultOutput = defaultOutput
        self.bluetoothDeviceIDs = bluetoothDeviceIDs
    }

    /// The first topology the app sees arms nothing. After that, a change of
    /// either default device or of the set of Bluetooth devices present does.
    /// A non-Bluetooth device arriving or leaving without a default change
    /// does not.
    public static func armsQuietWindow(previous: AudioTopology?, current: AudioTopology) -> Bool {
        guard let previous else {
            return false
        }
        return previous.defaultInput != current.defaultInput
            || previous.defaultOutput != current.defaultOutput
            || previous.bluetoothDeviceIDs != current.bluetoothDeviceIDs
    }
}

/// Default-device writes the owner has issued and whose completion has not
/// run yet, with the control-write epoch each was issued at.
///
/// A poll issued before such a write still reads the previous default for
/// that direction. The owner neither publishes that device nor reacts to it,
/// and while any write is outstanding the quiet window holds, up to its cap.
public struct DefaultDeviceWrites<Direction: Hashable>: Equatable {
    private var epochs: [Direction: [UInt64]] = [:]

    public init() {}

    /// Writes outstanding in every direction.
    public var count: Int {
        epochs.values.reduce(0) { $0 + $1.count }
    }

    public mutating func begin(_ direction: Direction, epoch: UInt64) {
        epochs[direction, default: []].append(epoch)
    }

    /// Called first thing in the write's completion, accepted or not.
    public mutating func end(_ direction: Direction, epoch: UInt64) {
        guard var pending = epochs[direction], let index = pending.firstIndex(of: epoch) else {
            return
        }
        pending.remove(at: index)
        epochs[direction] = pending.isEmpty ? nil : pending
    }

    /// Whether a poll issued at `snapshotEpoch` was read before a default
    /// write for `direction` that is still outstanding.
    public func snapshotPredatesOutstandingWrite(
        _ direction: Direction,
        snapshotEpoch: UInt64
    ) -> Bool {
        epochs[direction]?.contains { snapshotEpoch < $0 } ?? false
    }
}
