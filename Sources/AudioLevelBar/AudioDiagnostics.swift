import AudioLevelBarCore
import CoreAudio
import Foundation

enum AudioDiagnostics {
    /// Exit code used when the HAL itself is unresponsive, so a script can tell
    /// that apart from an ordinary failure.
    private static let halUnresponsiveExitCode: Int32 = 2

    static func run() {
        print("Audio Level Bar diagnostics")

        // Probe before touching anything else. Every later call would block
        // forever against a wedged coreaudiod, and a diagnostics tool that
        // hangs cannot report the one fact that matters most.
        guard reportHALProbe() else {
            exit(halUnresponsiveExitCode)
        }

        let audioSystem = CoreAudioSystem()
        printDirection(.output, name: "Output", audioSystem: audioSystem)
        printDirection(.input, name: "Input", audioSystem: audioSystem)
        printControlReadCost(audioSystem: audioSystem)
        printAggregateDevices()
        printProcessTaps()
    }

    /// Destroys stranded process taps and reports what happened.
    ///
    /// The app does this after every launch, once the launch quiet window
    /// admits starts. This entry point exists so the sweep can be run and
    /// checked on its own, without restarting the app.
    static func runTapReclamation() {
        print("Audio Level Bar tap reclamation")

        guard reportHALProbe() else {
            exit(halUnresponsiveExitCode)
        }

        let outcome = OrphanedProcessTapReclaimer.reclaim(
            scope: .everyTapOfThisApp,
            reason: "reclaim-command",
            generation: nil,
            halCalls: CoreAudioHALLifecycleCalls(audioSystem: CoreAudioSystem())
        )

        switch outcome.skip {
        case .attributionUnavailable:
            print(
                """

                Not reclaiming: the creating bundle cannot be read.
                  Core Audio reports which bundle created a tap only on macOS 26
                  and later. Destroying taps on the strength of their name alone
                  could break another app's tap that uses the same name.
                """
            )
            return
        case let .anotherInstanceRunning(identifiers):
            print(
                """

                Not reclaiming: another Audio Level Bar is running
                  (\(identifiers.joined(separator: ", ")))
                  A tap the running instance is using cannot be told apart from
                  one that was left behind. Quit the app and run this again.
                """
            )
            return
        case nil:
            break
        }

        if outcome.candidateUIDs.isEmpty {
            print("\nNo taps were left behind")
            return
        }

        print("\nCandidates: \(outcome.candidateUIDs.count)")
        for uid in outcome.destroyedUIDs {
            print("  Destroyed: \(uid)")
        }
        for uid in outcome.heldBackUIDs {
            print("  Held back: \(uid)")
        }
        for failure in outcome.failures {
            print("  Failed: \(failure.uid) (status \(failure.status))")
        }
        if outcome.aggregatesUnread {
            print(
                """

                Every candidate was held back: the device list, or the transport
                  of a listed device, could not be read, so an aggregate device
                  that lists one of these taps could not be ruled out.
                """
            )
        } else if !outcome.heldBackUIDs.isEmpty {
            print(
                """

                Held back taps are not destroyed while an aggregate device lists
                  them, while an earlier published device still exists, or while
                  an aggregate device of this app is running. Another app may
                  still be recording through one of them.
                """
            )
        }
        print(
            "\nDestroyed \(outcome.destroyedUIDs.count), "
                + "held back \(outcome.heldBackUIDs.count), "
                + "failed \(outcome.failures.count)"
        )
    }

    /// Returns false when the HAL did not answer and no further call should be
    /// attempted.
    private static func reportHALProbe() -> Bool {
        switch AudioResourceInventory.probeHAL() {
        case let .responsive(elapsed):
            print(String(format: "\nHAL: responsive (%.0f ms)", elapsed * 1000))
            return true
        case let .failed(status):
            print("\nHAL: answered with an error (status \(status))")
            return true
        case let .unresponsive(elapsed):
            print(String(format: "\nHAL: no answer within %.0f seconds", elapsed))
            print(
                """
                  Core Audio has stopped answering every app on this Mac. This
                  is not specific to Audio Level Bar. coreaudiod cannot be
                  restarted while SIP is enabled, so recovery takes a restart of
                  the Mac. The remaining checks would block in the same place and
                  are skipped.
                """
            )
            return false
        }
    }

    private static func printDirection(
        _ direction: AudioDirection,
        name: String,
        audioSystem: CoreAudioSystem
    ) {
        let defaultID = audioSystem.defaultDevice(for: direction)
        let devices = audioSystem.devices(for: direction)
        print("\n\(name) devices: \(devices.count)")

        for device in devices {
            let marker = device.id == defaultID ? "*" : " "
            let controls = audioSystem.controls(for: device.id, direction: direction)
            let volume = controls.volume.map {
                String(format: "%.0f%%", $0 * 100)
            } ?? "not reported"
            let adjustability = controls.volumeIsAdjustable ? "adjustable" : "read-only"
            let channels = direction == .input
                ? device.inputChannelCount
                : device.outputChannelCount
            // Mute is reported separately from volume: a device can accept one
            // and refuse the other, and the mute button's presence depends on
            // this rather than on volume adjustability.
            let mute: String
            switch (controls.isMuted, controls.muteIsAdjustable) {
            case (nil, _):
                mute = "mute: unsupported"
            case let (muted?, true):
                mute = "mute: \(muted ? "on" : "off") (adjustable)"
            case let (muted?, false):
                mute = "mute: \(muted ? "on" : "off") (read-only)"
            }
            print(
                "\(marker) \(device.name) [\(device.uid)] id \(device.id) — "
                    + "\(channels) ch, \(volume), \(adjustability), \(mute)"
            )
        }
    }

    /// Times a control read on the default output device.
    ///
    /// The app polls this every 0.25 s, so its cost sets how long the UI can be
    /// stuck behind Core Audio. The first read discovers which elements carry a
    /// control — 33 property probes per selector — and later reads reuse that,
    /// so printing both numbers shows the cache working and gives a baseline to
    /// compare against when the HAL is misbehaving.
    private static func printControlReadCost(audioSystem: CoreAudioSystem) {
        guard let deviceID = audioSystem.defaultDevice(for: .output) else {
            return
        }

        func measure() -> Double {
            let start = DispatchTime.now()
            _ = audioSystem.controls(for: deviceID, direction: .output)
            return Double(
                DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            ) / 1_000_000
        }

        // The device list read above already primed the layout cache for this
        // device, so drop it to time an honest first read.
        audioSystem.forgetControlLayouts()
        let cold = measure()
        let warm = (0..<8).map { _ in measure() }.reduce(0, +) / 8

        print(
            String(
                format: "\nDefault output device control read: first %.1f ms, later %.1f ms",
                cold,
                warm
            )
        )
        print("  The app does this for both directions every 0.25 s")
    }

    private static func printAggregateDevices() {
        guard let aggregates = AudioResourceInventory.aggregateDevices() else {
            print("\nAggregate devices: the device list, or a device's transport, could not be read")
            return
        }
        print("\nAggregate devices: \(aggregates.count)")

        if aggregates.isEmpty {
            print("  (none)")
            return
        }

        for aggregate in aggregates {
            let inUse = aggregate.isRunningSomewhere ? ", in use" : ""
            print(
                "  [\(label(for: aggregate.ownership))] \(aggregate.name) "
                    + "[\(aggregate.uid)] id \(aggregate.objectID)\(inUse)"
            )
        }

        // A private aggregate belongs to the process that made it and dies with
        // that process, so this app's own system output meter aggregate is
        // normally invisible here and cannot be orphaned. Say so, otherwise its
        // absence reads as a missing check.
        print(
            "  Note: the system output meter's aggregate device is private, and "
                + "macOS destroys it when its creating process exits, so it is "
                + "normally not listed here"
        )
        reportOrphans(aggregates)
    }

    private static func reportOrphans(
        _ aggregates: [AudioResourceInventory.AggregateDevice]
    ) {
        let ours = aggregates.filter { $0.ownership.isOwnedByThisApp }
        guard !ours.isEmpty else {
            return
        }
        let running = ProcessInfo.processInfo.processName
        print(
            "  Seen from this process (\(running)), \(ours.count) of the "
                + "devices above belong to Audio Level Bar"
        )
        for aggregate in ours where aggregate.ownership == .legacyPublishedMicrophone {
            print(
                "  ⚠️ A published microphone with the old UID is still here: "
                    + "\(aggregate.uid) — turning the processed microphone on "
                    + "once reclaims it"
            )
        }
    }

    private static func printProcessTaps() {
        guard #available(macOS 14.2, *) else {
            print("\nProcess taps: cannot be listed below macOS 14.2")
            return
        }

        let taps = AudioResourceInventory.processTaps()
        print("\nProcess taps: \(taps.count)")

        if taps.isEmpty {
            print("  (none)")
            return
        }

        for tap in taps {
            let owner = tap.ownership.map(label(for:)) ?? "another app"
            let targets = tap.targets
                .map { target -> String in
                    guard let pid = target.pid else {
                        return "object \(target.processObjectID) unresolved"
                    }
                    return "pid \(pid)\(target.isAlive ? "" : " exited")"
                }
                .joined(separator: ", ")
            let restore = tap.restoresAcrossReboot ? ", restored after reboot" : ""
            print("  [\(owner)] \(tap.name) [\(tap.uid)] id \(tap.objectID)\(restore)")
            let bundles = tap.attributionIsAuthoritative
                ? (tap.bundleIDs.isEmpty
                    ? "(none listed)"
                    : tap.bundleIDs.joined(separator: ", "))
                : "(unavailable below macOS 26; the attribution above rests on the name alone)"
            print("      Created by bundle: \(bundles)")
            print("      Target processes: \(targets.isEmpty ? "(none listed)" : targets)")
        }

        let ours = taps.filter { $0.ownership != nil }
        let idle = ours.filter { $0.targets.isEmpty }
        guard !idle.isEmpty else {
            return
        }
        print(
            "\n  ⚠️ \(idle.count) of this app's taps are left with no target process."
        )
        print(
            "     No audio will ever pass through them again. They do not go away"
        )
        print(
            "     when the creating process exits, and macOS restores the ones with\n     processRestoreEnabled after a reboot."
        )
        let byBundle = Dictionary(grouping: idle) { $0.bundleIDs.joined(separator: ",") }
        for (bundle, taps) in byBundle.sorted(by: { $0.key < $1.key }) {
            print("     \(taps.count): \(bundle)")
        }
    }

    private static func label(for ownership: AudioResourceOwnership) -> String {
        switch ownership {
        case .publishedMicrophone:
            return "processed microphone"
        case .legacyPublishedMicrophone:
            return "processed microphone (old UID)"
        case .systemOutputMeter:
            return "system output meter"
        case .foreign:
            return "another app"
        }
    }
}
