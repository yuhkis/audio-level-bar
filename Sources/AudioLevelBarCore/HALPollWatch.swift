import Foundation

/// Whether the periodic HAL poll is in flight, and whether it is taking long
/// enough to say so in the log.
///
/// The poll is dropped while the previous one has not returned. A dropped
/// tick is silent by itself, so a poll stuck behind an unresponsive
/// coreaudiod, or behind a control write on the same queue, would leave no
/// trace: the quiet window would simply not release. This notes such a poll
/// once, when a tick is dropped more than `slowAfter` after it was issued,
/// and again when it returns. The owner holds the quiet window for such a
/// poll: while it waits, nothing the poll would have seen can arm the window.
///
/// A dropped poll that asked for the device lists, as a device-list
/// notification's does, is remembered: the Bluetooth device set is read with
/// the lists, and without them a headset that arrived while a poll was in
/// flight would not be seen for up to two seconds more. The owner issues it
/// once the poll in flight has returned.
///
/// All times are on the caller's lifecycle clock.
public struct HALPollWatch: Equatable {
    /// How long a poll may be in flight before a dropped tick is noted.
    public static let slowAfter: TimeInterval = 0.5

    /// What became of a poll the caller issued.
    public enum Issue: Equatable {
        /// No poll was in flight; this one is.
        case issued
        /// A poll is still in flight, and this one is dropped.
        case dropped
        /// As `dropped`, and the poll in flight has taken `issuedAgo` seconds,
        /// more than `slowAfter`. Reported once per poll.
        case droppedWhileSlow(issuedAgo: TimeInterval)
    }

    /// When the poll in flight was issued, or nil.
    public private(set) var inFlightIssuedAt: TimeInterval?
    private var slowNoted = false
    /// Whether a dropped poll asked for the device lists.
    public private(set) var deviceListsOwed = false

    public init() {}

    public var isInFlight: Bool {
        inFlightIssuedAt != nil
    }

    /// A poll issued at `now`. `wantsDeviceLists` is whether it asks for the
    /// device lists; a poll issued while one is owed carries them.
    public mutating func issue(at now: TimeInterval, wantsDeviceLists: Bool = false) -> Issue {
        guard let issuedAt = inFlightIssuedAt else {
            inFlightIssuedAt = now
            slowNoted = false
            if wantsDeviceLists {
                deviceListsOwed = false
            }
            return .issued
        }
        if wantsDeviceLists {
            deviceListsOwed = true
        }
        let issuedAgo = now - issuedAt
        guard !slowNoted, issuedAgo > Self.slowAfter else {
            return .dropped
        }
        slowNoted = true
        return .droppedWhileSlow(issuedAgo: issuedAgo)
    }

    /// The poll in flight returned at `now`. Returns the seconds it took when
    /// it was noted slow or took longer than `slowAfter`, and nil otherwise or
    /// when no poll was in flight.
    public mutating func returned(at now: TimeInterval) -> TimeInterval? {
        guard let issuedAt = inFlightIssuedAt else {
            return nil
        }
        let elapsed = now - issuedAt
        let wasSlow = slowNoted || elapsed > Self.slowAfter
        inFlightIssuedAt = nil
        slowNoted = false
        return wasSlow ? elapsed : nil
    }

    /// Whether a dropped poll asked for the device lists, clearing it. The
    /// owner issues a poll with the lists when this is true.
    public mutating func takeOwedDeviceLists() -> Bool {
        defer { deviceListsOwed = false }
        return deviceListsOwed
    }
}
