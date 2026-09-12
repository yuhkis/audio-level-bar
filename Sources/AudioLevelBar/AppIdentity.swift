import AppKit
import Foundation

enum AudioLevelBarIdentity {
    static let bundleIdentifier = "io.github.yuhkis.audio-level-bar"

    static let statusItemAutosaveName = "\(bundleIdentifier).status-item"

    /// Until a status item is given an autosave name of its own, AppKit saves
    /// its position under a generic identifier, in this same defaults domain.
    /// A position saved that way is still worth carrying forward.
    static let legacyStatusItemAutosaveNames = [
        "Item-0",
    ]

    /// Bundle identifiers of other running copies of this app, excluding this
    /// process.
    ///
    /// Unlike `activateConflictingInstanceIfPresent()` this only looks; it is
    /// safe to call when bringing another window forward would be wrong.
    static func otherRunningInstanceIdentifiers() -> [String] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return [bundleIdentifier].filter { identifier in
            NSRunningApplication
                .runningApplications(withBundleIdentifier: identifier)
                .contains { $0.processIdentifier != currentPID }
        }
    }

    static func activateConflictingInstanceIfPresent() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID }) {
            existing.activate()
            return true
        }
        return false
    }
}
