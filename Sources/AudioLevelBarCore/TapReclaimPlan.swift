import Foundation

/// A process tap attributed to this app, as tap reclamation sees it.
public struct ReclaimableTap: Equatable {
    public var uid: String
    public var ownership: AudioResourceOwnership

    public init(uid: String, ownership: AudioResourceOwnership) {
        self.uid = uid
        self.ownership = ownership
    }
}

/// An aggregate device that exists, as tap reclamation sees it.
public struct ExistingAggregate: Equatable {
    public var uid: String
    public var ownership: AudioResourceOwnership
    /// The UIDs of the process taps it lists, or nil when they could not be
    /// read.
    public var tapUIDs: [String]?
    public var isRunningSomewhere: Bool

    public init(
        uid: String,
        ownership: AudioResourceOwnership,
        tapUIDs: [String]?,
        isRunningSomewhere: Bool
    ) {
        self.uid = uid
        self.ownership = ownership
        self.tapUIDs = tapUIDs
        self.isRunningSomewhere = isRunningSomewhere
    }
}

public enum TapReclaimScope: Equatable {
    /// Every tap of this app. Only where this process cannot hold a tap of
    /// its own: at launch, before anything this run builds, and from the
    /// separate reclaim command.
    case everyTapOfThisApp
    /// The published microphone's taps only, from a running instance whose
    /// system playback meter may hold a live tap of its own. That meter's
    /// aggregate device is private, visible only to the process that made
    /// it, so one listed here is this instance's own and references only its
    /// own tap.
    case publishedMicrophoneTaps
}

/// Decides which of this app's process taps may be destroyed as left behind
/// by an earlier run.
///
/// No other instance of the app running is necessary, but not enough, to call
/// a tap stranded. A tap an existing aggregate device lists is in use by that
/// device. A published device an earlier run left behind can still be
/// recording in another app, with its tap as its only input: destroying that
/// tap would take the consumer's running device apart under it. So:
/// - nothing is reclaimed while any aggregate device's tap list cannot be
///   read, since it could list any tap;
/// - nothing is reclaimed while an aggregate device of this app has IO
///   running, except this instance's own system playback meter in the
///   published-taps scope;
/// - a tap an existing aggregate device lists is never reclaimed;
/// - the published microphone's taps wait while an earlier publication's
///   aggregate device exists at all, running or not;
/// - another app's tap is never reclaimed.
public enum TapReclaimPlan {
    public static func reclaimable(
        taps: [ReclaimableTap],
        aggregates: [ExistingAggregate],
        scope: TapReclaimScope
    ) -> [String] {
        guard aggregates.allSatisfy({ $0.tapUIDs != nil }) else {
            return []
        }
        let runningAggregateOfThisApp = aggregates.contains { aggregate in
            aggregate.ownership.isOwnedByThisApp
                && aggregate.isRunningSomewhere
                && !(scope == .publishedMicrophoneTaps && aggregate.ownership == .systemOutputMeter)
        }
        guard !runningAggregateOfThisApp else {
            return []
        }

        let listed = Set(aggregates.flatMap { $0.tapUIDs ?? [] })
        let earlierPublicationExists = aggregates.contains { isPublication($0.ownership) }
        return taps
            .filter { tap in
                guard tap.ownership.isOwnedByThisApp else {
                    return false
                }
                if scope == .publishedMicrophoneTaps, !isPublication(tap.ownership) {
                    return false
                }
                if listed.contains(tap.uid) {
                    return false
                }
                return !(earlierPublicationExists && isPublication(tap.ownership))
            }
            .map(\.uid)
    }

    private static func isPublication(_ ownership: AudioResourceOwnership) -> Bool {
        ownership == .publishedMicrophone || ownership == .legacyPublishedMicrophone
    }
}
