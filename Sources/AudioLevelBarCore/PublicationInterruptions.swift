import Foundation

/// How many of the processed microphone's publications in a row a quiet
/// window may interrupt before the owner stops publishing by itself.
///
/// A publication makes its lifecycle calls one after another on the main
/// thread, and stops before its next call when a listener advances the quiet
/// window's generation. What it created is kept, and the first release after
/// the window rolls it back; a release that admits starts then publishes
/// afresh. Nothing else ends that cycle. If every publication were
/// interrupted, for example by a default-device notification the HAL posted
/// around the app's own creates, which is not known to happen, the app would
/// create and destroy a public aggregate device at every window for as long
/// as it ran. Repeated destroys and creates of a public aggregate device are
/// themselves something coreaudiod has handled badly.
///
/// So the interruptions in a row are counted, and the
/// `maximumConsecutiveInterruptions`th ends them: once what that publication
/// kept has been rolled back, the owner publishes nothing more, shows the
/// processed microphone failed with Retry, and writes a `give-up` line. A
/// publication that completed, the user's Retry, and switching the processed
/// microphone off start the count over (`startOver()`).
public struct PublicationInterruptions: Equatable {
    /// The interrupted publication in a row after which no further
    /// publication is issued.
    public static let maximumConsecutiveInterruptions = 3

    /// Publications a quiet window interrupted since the last one that
    /// completed.
    public private(set) var consecutiveInterruptions = 0

    public init() {}

    /// Whether the interruptions in a row reached
    /// `maximumConsecutiveInterruptions`. Nothing is published until
    /// `startOver()`.
    public var isExhausted: Bool {
        consecutiveInterruptions >= Self.maximumConsecutiveInterruptions
    }

    /// A quiet window interrupted a publication.
    ///
    /// - Returns: Whether this interruption ended the publications.
    @discardableResult
    public mutating func interrupted() -> Bool {
        let wasExhausted = isExhausted
        consecutiveInterruptions += 1
        return isExhausted && !wasExhausted
    }

    /// A publication completed, or the user retried or switched the
    /// processed microphone off: the interruptions count from zero again.
    public mutating func startOver() {
        consecutiveInterruptions = 0
    }
}
