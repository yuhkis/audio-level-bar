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
        var failures: [(uid: String, status: OSStatus)] = []
        var skip: Skip?
    }

    /// Reports what reclamation would destroy without touching anything.
    static func survey() -> Outcome {
        run(destroying: false)
    }

    /// Destroys every stranded tap belonging to this app.
    static func reclaim() -> Outcome {
        run(destroying: true)
    }

    private static func run(destroying: Bool) -> Outcome {
        var outcome = Outcome()

        guard #available(macOS 14.2, *) else {
            outcome.skip = .attributionUnavailable
            return outcome
        }

        // The safety argument for destroying a tap rests entirely on this
        // check. With no other copy of this app running, no live process of
        // ours can own a tap, so every tap Core Audio attributes to one of our
        // bundle identifiers is by definition stranded. Skip the moment that
        // premise fails rather than guess which tap is in use.
        let others = AudioLevelBarIdentity.otherRunningInstanceIdentifiers()
        guard others.isEmpty else {
            outcome.skip = .anotherInstanceRunning(others)
            return outcome
        }

        let taps = AudioResourceInventory.processTaps()
        guard taps.allSatisfy(\.attributionIsAuthoritative) else {
            outcome.skip = .attributionUnavailable
            return outcome
        }

        let stranded = taps.filter { $0.ownership != nil }
        outcome.candidateUIDs = stranded.map(\.uid)
        guard destroying else {
            return outcome
        }

        for tap in stranded {
            let status = AudioHardwareDestroyProcessTap(tap.objectID)
            if status == noErr || status == kAudioHardwareBadObjectError {
                outcome.destroyedUIDs.append(tap.uid)
            } else {
                outcome.failures.append((uid: tap.uid, status: status))
            }
        }
        return outcome
    }
}
