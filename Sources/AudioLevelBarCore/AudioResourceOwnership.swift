import Foundation

/// Identifiers this app publishes into Core Audio.
///
/// Passed in rather than hard-coded so the classification stays testable and so
/// the app keeps a single definition of each identifier.
public struct AudioResourceNamespace: Sendable, Equatable {
    /// UID of the aggregate device published as the processed microphone.
    public let publishedMicrophoneUID: String
    /// UIDs earlier builds published the same device under. Recognized so an
    /// aggregate left behind by one of those builds can still be attributed.
    public let legacyPublishedMicrophoneUIDs: [String]
    /// Prefix of the private aggregate the system output meter creates per run.
    public let privateTapAggregateUIDPrefix: String
    /// Description name of the processed microphone's process tap.
    public let publishedMicrophoneTapName: String
    /// Description name of the system output meter's process tap.
    public let systemOutputMeterTapName: String
    /// Every bundle identifier this app has shipped under, current first.
    ///
    /// Core Audio records the creating bundle on each tap and reports it back
    /// through `CATapDescription.bundleIDs`, which makes this the one piece of
    /// tap attribution the app does not have to trust a name for.
    public let bundleIdentifiers: [String]

    public init(
        publishedMicrophoneUID: String,
        legacyPublishedMicrophoneUIDs: [String],
        privateTapAggregateUIDPrefix: String,
        publishedMicrophoneTapName: String,
        systemOutputMeterTapName: String,
        bundleIdentifiers: [String]
    ) {
        self.publishedMicrophoneUID = publishedMicrophoneUID
        self.legacyPublishedMicrophoneUIDs = legacyPublishedMicrophoneUIDs
        self.privateTapAggregateUIDPrefix = privateTapAggregateUIDPrefix
        self.publishedMicrophoneTapName = publishedMicrophoneTapName
        self.systemOutputMeterTapName = systemOutputMeterTapName
        self.bundleIdentifiers = bundleIdentifiers
    }
}

/// Who a Core Audio object belongs to.
///
/// The distinction that matters for cleanup is `foreign` versus everything
/// else: destroying another app's aggregate device or tap would break that app,
/// so a sweep must never act on one.
public enum AudioResourceOwnership: String, Sendable, Equatable {
    /// The processed microphone this build publishes.
    case publishedMicrophone
    /// The processed microphone under an identifier an earlier build used.
    case legacyPublishedMicrophone
    /// A per-run private aggregate, or the tap, belonging to the system output
    /// meter.
    case systemOutputMeter
    /// Created by something else. Never a cleanup target.
    case foreign

    /// True when this app may destroy the object.
    public var isOwnedByThisApp: Bool {
        self != .foreign
    }
}

public enum AudioResourceClassifier {
    /// Classifies an aggregate device by its UID.
    ///
    /// UIDs are the reliable attribution: this app chooses them, and the
    /// published one is a fixed string no other app has reason to use.
    public static func ownership(
        ofAggregateUID uid: String,
        in namespace: AudioResourceNamespace
    ) -> AudioResourceOwnership {
        if uid == namespace.publishedMicrophoneUID {
            return .publishedMicrophone
        }
        if namespace.legacyPublishedMicrophoneUIDs.contains(uid) {
            return .legacyPublishedMicrophone
        }
        if uid.hasPrefix(namespace.privateTapAggregateUIDPrefix) {
            return .systemOutputMeter
        }
        return .foreign
    }

    /// Classifies a process tap.
    ///
    /// `bundleIDs` is the authority: Core Audio records which bundle created a
    /// tap, so a match there identifies the tap as this app's even when the
    /// creating process is long gone. The name only refines *which* of this
    /// app's taps it is, and is never enough on its own — names are not unique,
    /// and acting on a name match alone could destroy another app's tap.
    ///
    /// Returns nil when no bundle identifier matches, whatever the name says.
    public static func ownership(
        ofTapWithBundleIDs bundleIDs: [String],
        name: String,
        in namespace: AudioResourceNamespace
    ) -> AudioResourceOwnership? {
        let isOurs = bundleIDs.contains { namespace.bundleIdentifiers.contains($0) }
        guard isOurs else {
            return nil
        }
        switch name {
        case namespace.systemOutputMeterTapName:
            return .systemOutputMeter
        case namespace.publishedMicrophoneTapName:
            return isCurrentBundle(bundleIDs, in: namespace)
                ? .publishedMicrophone
                : .legacyPublishedMicrophone
        default:
            // Ours by bundle, but from a build whose tap names this version
            // does not know. Still safe to attribute, and still a cleanup
            // candidate.
            return isCurrentBundle(bundleIDs, in: namespace)
                ? .publishedMicrophone
                : .legacyPublishedMicrophone
        }
    }

    /// Classifies a tap when the creating bundle is not available.
    ///
    /// Core Audio only reports `bundleIDs` on macOS 26 and later. Below that
    /// the name is all there is, and a name match is not proof: another app can
    /// use the same string. Callers must treat this as provisional and must not
    /// destroy anything on its basis alone.
    public static func provisionalOwnership(
        ofTapName name: String,
        in namespace: AudioResourceNamespace
    ) -> AudioResourceOwnership? {
        switch name {
        case namespace.publishedMicrophoneTapName:
            return .publishedMicrophone
        case namespace.systemOutputMeterTapName:
            return .systemOutputMeter
        default:
            return nil
        }
    }

    private static func isCurrentBundle(
        _ bundleIDs: [String],
        in namespace: AudioResourceNamespace
    ) -> Bool {
        guard let current = namespace.bundleIdentifiers.first else {
            return false
        }
        return bundleIDs.contains(current)
    }
}
