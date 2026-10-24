import Foundation

/// How often, and for how long, the processed microphone tries again to start
/// when the output its publisher is bound to reads no usable hardware
/// format.
///
/// An output being reconfigured or removed reads 0 Hz or no channels, and
/// the start waits that out behind a quiet window. An output that keeps
/// reading that way, with nothing else changing, would otherwise have the
/// capture's IOProc, or Apple voice processing's engine, built and released
/// against it after every window for as long as it does. So the retries on
/// one output are spaced 2, 4, then 8 s apart, and the
/// `maximumConsecutiveFailures`th unusable read in a row on that output ends
/// them. The owner then shows the processed microphone failed with Retry and
/// issues nothing for it, neither a start nor a stop, until the user retries
/// or switches it off, or the poll shows another default output or another
/// output the publisher would be bound to.
///
/// Times are on the owner's lifecycle clock.
public struct PublisherOutputRetry: Equatable {
    /// The unusable read in a row on one output that ends the retries.
    public static let maximumConsecutiveFailures = 4
    public static let maximumRetryDelay: TimeInterval = MeterSession.maximumRetryDelay

    /// What the retries let the processed microphone's plan do now.
    public enum Gate: Equatable {
        /// No retry is waiting.
        case open
        /// A retry waits for its spacing: nothing is started or restarted,
        /// as while starts are held.
        case spaced
        /// The retries ended: nothing is started, restarted or stopped.
        case exhausted
    }

    /// The output the unusable reads in a row were made on.
    public private(set) var outputDeviceID: UInt32?
    public private(set) var consecutiveFailures = 0
    /// The earliest time the next start may be issued, nil when none waits.
    public private(set) var retryNotBefore: TimeInterval?
    /// The default output the poll showed when the retries ended.
    private var exhaustedDefaultOutput: PublisherOutputCandidate?
    /// The output the poll would have bound the publisher to then.
    private var exhaustedChoice: PublisherOutputChoice?

    public init() {}

    /// Whether the retries ended.
    public var isExhausted: Bool {
        consecutiveFailures >= Self.maximumConsecutiveFailures
    }

    /// A start's publisher output, `deviceID`, read no usable format at
    /// `time`. A different output than the reads before it starts the count
    /// over.
    ///
    /// - Parameter survey: What the poll shows now, kept when the retries
    ///   end so that a change of output can be told.
    /// - Returns: Whether this read ended the retries.
    @discardableResult
    public mutating func outputUnavailable(
        deviceID: UInt32,
        at time: TimeInterval,
        survey: PublisherOutputSurvey
    ) -> Bool {
        if deviceID != outputDeviceID {
            self = PublisherOutputRetry()
            outputDeviceID = deviceID
        }
        let wasExhausted = isExhausted
        consecutiveFailures += 1
        guard isExhausted else {
            retryNotBefore = time + min(pow(2, Double(consecutiveFailures)), Self.maximumRetryDelay)
            return false
        }
        retryNotBefore = nil
        guard !wasExhausted else {
            return false
        }
        exhaustedDefaultOutput = survey.defaultOutput
        exhaustedChoice = PublisherOutputPolicy.choose(survey)
        return true
    }

    /// A start reported that it started, or the user retried or switched the
    /// processed microphone off, or another halt took over: the count and
    /// the spacing are spent.
    public mutating func startOver() {
        self = PublisherOutputRetry()
    }

    public func gate(at time: TimeInterval) -> Gate {
        if isExhausted {
            return .exhausted
        }
        if let retryNotBefore, time < retryNotBefore {
            return .spaced
        }
        return .open
    }

    /// Whether retries that ended still stand for what the poll shows now:
    /// the same default output, with the same transport, and the same output
    /// the publisher would be bound to. False when they have not ended.
    public func exhaustionStands(for survey: PublisherOutputSurvey) -> Bool {
        isExhausted
            && survey.defaultOutput == exhaustedDefaultOutput
            && PublisherOutputPolicy.choose(survey) == exhaustedChoice
    }
}
