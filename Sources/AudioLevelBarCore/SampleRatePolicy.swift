import Foundation

/// Which sample rates a device may report for the processed microphone and
/// the microphone meter to open it at.
///
/// A rate read from the HAL sizes buffers and is converted to integers on a
/// lifecycle queue. A rate that is infinite, NaN, zero, or absurdly large would
/// trap in that conversion or allocate an enormous buffer while the published
/// device may be in use. Real hardware reports rates well inside this range;
/// anything outside it is treated as an unsupported format.
public enum SampleRatePolicy {
    /// From telephone-band 8 kHz to 768 kHz, the highest rate current audio
    /// interfaces offer.
    public static let usableRange: ClosedRange<Double> = 8_000...768_000

    /// Whether `sampleRate` is finite and inside `usableRange`.
    public static func isUsable(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite && usableRange.contains(sampleRate)
    }

    /// The frames a buffer holding `duration` seconds at `sampleRate` needs,
    /// clamped to `minimum`...`maximum`, or nil when the rate is not usable,
    /// `duration` is not a positive finite time, or the product does not fit
    /// an `Int`. No conversion here can trap.
    public static func bufferFrames(
        sampleRate: Double,
        duration: TimeInterval,
        minimum: Int,
        maximum: Int
    ) -> Int? {
        guard
            isUsable(sampleRate),
            duration.isFinite,
            duration > 0,
            let frames = Int(exactly: (sampleRate * duration).rounded(.up))
        else {
            return nil
        }
        return min(max(frames, minimum), maximum)
    }

    /// The integer rate WebRTC noise suppression is created with, or nil when
    /// the rate is not usable or does not convert exactly.
    public static func webRTCSampleRate(_ sampleRate: Double) -> UInt32? {
        guard isUsable(sampleRate) else {
            return nil
        }
        return UInt32(exactly: sampleRate.rounded())
    }
}

/// What the capture path passes on for a sample that is not a finite number.
public enum SampleSanitizer {
    /// `sample`, or 0 for a NaN or an infinity, which would otherwise pass
    /// through the gain or the limiter into the published device.
    @inlinable
    @inline(__always)
    public static func finiteOrZero(_ sample: Float) -> Float {
        sample.isFinite ? sample : 0
    }
}
