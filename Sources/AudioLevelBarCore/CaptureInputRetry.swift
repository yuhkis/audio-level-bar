import Foundation

/// How often, and for how long, the processed microphone's IOProc capture
/// tries again to open an input that only the read made as it was opened
/// refused.
///
/// The capture reads its input's transport again, uncached, immediately
/// before it creates its IOProc, and once more before it starts it. The owner
/// issues a start only for an input the poll judged open. So a transport
/// that read could not read, or an aggregate member that only that read could
/// not resolve, is most likely a read that failed once, not evidence of
/// Bluetooth: a member that is really absent shows in the poll's own read,
/// which then refuses the input and issues no start. `MeterSession` takes the
/// same result of the microphone meter's open as a failed attempt, and the
/// capture is treated the same way here. The next start on that input waits
/// 2, 4, then 8 s, behind the quiet window the owner arms for the refusal,
/// and the `maximumConsecutiveFailures`th such read in a row on one input
/// ends the retries. An input whose read keeps failing is therefore not
/// opened again at every window for as long as it does, which can create the
/// capture's IOProc and release it again each time. The owner then halts the
/// processed microphone with Retry.
///
/// A Bluetooth refusal by that read is not counted here: it stands as a
/// refusal (`SourceRefusalLatch`).
///
/// Times are on the owner's lifecycle clock.
public struct CaptureInputRetry: Equatable {
    /// The failed read in a row on one input that ends the retries, as many
    /// as `MeterSession` makes start attempts.
    public static let maximumConsecutiveFailures = MeterSession.maximumStartAttempts
    public static let maximumRetryDelay: TimeInterval = MeterSession.maximumRetryDelay

    /// The input the failed reads in a row were made on.
    public private(set) var inputDeviceID: UInt32?
    public private(set) var consecutiveFailures = 0
    /// The earliest time the next start on `inputDeviceID` may be issued, nil
    /// when none waits.
    public private(set) var retryNotBefore: TimeInterval?

    public init() {}

    /// Whether the retries ended.
    public var isExhausted: Bool {
        consecutiveFailures >= Self.maximumConsecutiveFailures
    }

    /// The read made as `deviceID` was opened could not read its transport,
    /// or could not resolve an aggregate member, at `time`. Another input
    /// than the reads before it starts the count over.
    ///
    /// - Returns: Whether this read ended the retries.
    @discardableResult
    public mutating func readFailed(deviceID: UInt32, at time: TimeInterval) -> Bool {
        if deviceID != inputDeviceID {
            self = CaptureInputRetry()
            inputDeviceID = deviceID
        }
        let wasExhausted = isExhausted
        consecutiveFailures += 1
        guard isExhausted else {
            retryNotBefore = time + min(pow(2, Double(consecutiveFailures)), Self.maximumRetryDelay)
            return false
        }
        retryNotBefore = nil
        return !wasExhausted
    }

    /// A start reported that it started, or the user retried or switched the
    /// processed microphone off, or a halt took over: the count and the
    /// spacing are spent.
    public mutating func startOver() {
        self = CaptureInputRetry()
    }

    /// Whether a start on `deviceID` waits for its spacing at `time`. While
    /// it does, nothing is started or restarted, as while starts are held.
    /// Another input does not wait.
    public func holdsStarts(on deviceID: UInt32, at time: TimeInterval) -> Bool {
        guard deviceID == inputDeviceID, let retryNotBefore else {
            return false
        }
        return time < retryNotBefore
    }
}
