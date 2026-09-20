import AudioLevelBarCore
import CoreAudio
import Foundation

/// Destroys process taps this app left behind when a previous run ended
/// without cleaning up.
///
/// A process tap outlives the process that made it, and macOS restores the
/// non-private ones across reboots, so a run that dies before its teardown —
/// a crash, a force quit, a hang the user gives up on — strands a tap forever.
/// Normal termination tears its own tap down, so this is the only thing that
/// removes the ones abnormal termination leaves behind; without it they
/// accumulate.
///
/// Which taps are stranded is `TapReclaimPlan`'s decision. A tap an existing
/// aggregate device lists is not, nor is the tap of a published device an
/// earlier run left behind while that device exists: another app may still be
/// recording from it, with the tap as its only input.
enum OrphanedProcessTapReclaimer {
    enum Skip: Equatable {
        /// Core Audio reports the creating bundle only from macOS 26. Without
        /// it, ownership rests on the tap's name, which another app could also
        /// use, so reclamation would risk destroying someone else's tap.
        case attributionUnavailable
        /// Another copy of this app is running and its taps are in use.
        case anotherInstanceRunning([String])
    }

    struct Outcome {
        var candidateUIDs: [String] = []
        var destroyedUIDs: [String] = []
        /// Candidates `TapReclaimPlan` kept: listed by an existing aggregate
        /// device, under an earlier publication that still exists, or held
        /// back while an aggregate device of this app runs or a tap list
        /// cannot be read. Every candidate is held back when the device list,
        /// or a listed device's transport, cannot be read.
        var heldBackUIDs: [String] = []
        /// Whether the aggregate devices could not be listed.
        var aggregatesUnread = false
        /// Taps that could have been destroyed and were not, because a quiet
        /// window armed after the reclaim was issued. The owner reclaims them
        /// after the window.
        var interruptedUIDs: [String] = []
        var failures: [(uid: String, status: OSStatus)] = []
        var skip: Skip?
    }

    /// Where the process taps, the aggregate devices and the other running
    /// instances are read from. A test substitutes its own.
    struct Inventory {
        var otherRunningInstances: () -> [String]
        var processTaps: () -> [AudioResourceInventory.ProcessTap]
        /// nil when the device list, or a listed device's transport, could
        /// not be read.
        var aggregateDevices: () -> [AudioResourceInventory.AggregateDevice]?

        static let live = Inventory(
            otherRunningInstances: { AudioLevelBarIdentity.otherRunningInstanceIdentifiers() },
            processTaps: { AudioResourceInventory.processTaps() },
            aggregateDevices: { AudioResourceInventory.aggregateDevices() }
        )
    }

    /// Reports what reclamation would destroy without touching anything.
    static func survey(
        scope: TapReclaimScope = .everyTapOfThisApp,
        inventory: Inventory = .live
    ) -> Outcome {
        run(scope: scope, destroyingWith: nil, inventory: inventory)
    }

    /// Destroys the stranded taps `TapReclaimPlan` allows. Each destroy
    /// writes a `reclaimed-tap destroy-begin` line and a `reclaimed-tap
    /// destroy` line carrying `reason` and `generation`: the quiet window's
    /// generation the owner's evaluation issued the cleanup in, or nil
    /// outside the app's lifecycle.
    ///
    /// - Parameter mayDestroy: Asked immediately before each destroy, after
    ///   the inventory's reads, which can wait in coreaudiod: whether no
    ///   quiet window has armed since the reclaim was issued. When it says
    ///   no, that destroy and the ones after it are not made, a
    ///   `reclaimed-tap interrupt-stop` line names the tap the first of them
    ///   was for, and `interruptedUIDs` lists what is left. Always yes for
    ///   the `--reclaim-taps` command, which runs outside the app.
    static func reclaim(
        scope: TapReclaimScope,
        reason: String,
        generation: UInt64?,
        mayDestroy: @escaping () -> Bool = { true },
        halCalls: any HALLifecycleCalls,
        inventory: Inventory = .live
    ) -> Outcome {
        run(
            scope: scope,
            destroyingWith: Destroyer(
                halCalls: halCalls,
                reason: reason,
                generation: generation,
                mayDestroy: mayDestroy
            ),
            inventory: inventory
        )
    }

    private struct Destroyer {
        let halCalls: any HALLifecycleCalls
        let reason: String
        let generation: UInt64?
        let mayDestroy: () -> Bool
    }

    private static func run(
        scope: TapReclaimScope,
        destroyingWith destroyer: Destroyer?,
        inventory: Inventory
    ) -> Outcome {
        var outcome = Outcome()

        guard #available(macOS 14.2, *) else {
            outcome.skip = .attributionUnavailable
            return outcome
        }

        // With another copy of this app running, a live process of ours can
        // own a tap, and nothing tells its taps apart from stranded ones.
        let others = inventory.otherRunningInstances()
        guard others.isEmpty else {
            outcome.skip = .anotherInstanceRunning(others)
            return outcome
        }

        let taps = inventory.processTaps()
        guard taps.allSatisfy(\.attributionIsAuthoritative) else {
            outcome.skip = .attributionUnavailable
            return outcome
        }

        let candidates = taps.filter { tap in
            switch tap.ownership {
            case nil, .foreign?:
                return false
            case .publishedMicrophone?, .legacyPublishedMicrophone?:
                return true
            case .systemOutputMeter?:
                return scope == .everyTapOfThisApp
            }
        }
        outcome.candidateUIDs = candidates.map(\.uid)
        guard !candidates.isEmpty else {
            return outcome
        }

        guard let aggregates = inventory.aggregateDevices() else {
            // An aggregate device that could not be read may list a tap, or
            // be a published device a consumer records from through it: a
            // failed read is not an absent device.
            outcome.aggregatesUnread = true
            outcome.heldBackUIDs = outcome.candidateUIDs
            return outcome
        }
        let reclaimable = Set(
            TapReclaimPlan.reclaimable(
                taps: candidates.compactMap { tap in
                    tap.ownership.map { ReclaimableTap(uid: tap.uid, ownership: $0) }
                },
                aggregates: aggregates.map { aggregate in
                    ExistingAggregate(
                        uid: aggregate.uid,
                        ownership: aggregate.ownership,
                        tapUIDs: aggregate.tapUIDs,
                        isRunningSomewhere: aggregate.isRunningSomewhere
                    )
                },
                scope: scope
            )
        )
        outcome.heldBackUIDs = candidates.map(\.uid).filter { !reclaimable.contains($0) }

        guard let destroyer else {
            return outcome
        }
        let stranded = candidates.filter { reclaimable.contains($0.uid) }
        for (index, tap) in stranded.enumerated() {
            guard destroyer.mayDestroy() else {
                HALLifecycleLog.record(
                    .reclaimedTap,
                    .interruptStop,
                    id: tap.objectID,
                    generation: destroyer.generation,
                    reason: destroyer.reason,
                    tapUID: tap.uid
                )
                outcome.interruptedUIDs = stranded[index...].map(\.uid)
                break
            }
            HALLifecycleLog.begin(
                .reclaimedTap,
                .destroy,
                id: tap.objectID,
                generation: destroyer.generation,
                reason: destroyer.reason,
                tapUID: tap.uid
            )
            let status = destroyer.halCalls.destroyProcessTap(tap.objectID)
            HALLifecycleLog.record(
                .reclaimedTap,
                .destroy,
                id: tap.objectID,
                status: status,
                generation: destroyer.generation,
                reason: destroyer.reason,
                tapUID: tap.uid
            )
            if status == noErr || status == kAudioHardwareBadObjectError {
                outcome.destroyedUIDs.append(tap.uid)
            } else {
                outcome.failures.append((uid: tap.uid, status: status))
            }
        }
        return outcome
    }
}
