import CoreAudio
import Foundation

/// Copies the first channel out of an IOProc's input buffer list.
///
/// The processed microphone is mono. Channel 0 is the first sample of each
/// frame in the first buffer: every `mNumberChannels`-th sample when that
/// buffer is interleaved, and every sample when it is not, which is the same
/// rule with a stride of one. The copy is allocation-free and lock-free, so it
/// can run on the HAL IO thread.
///
/// A sample that is not finite (NaN or an infinity, or a Float64 too large
/// for Float32) is written as 0. A driver or aggregate glitch can deliver
/// one, and passed on it would reach the gain, the limiter and noise
/// suppression, whose recursive state it can poison for the rest of the
/// session.
public enum AudioBufferChannelCopy {
    /// Writes channel 0 into `destination` as Float32, with every sample that
    /// is not finite as 0, and returns the number of frames written, never
    /// more than `capacity`. Returns 0 for an empty list, a buffer without
    /// data, or no capacity.
    public static func copyFirstChannel(
        _ list: UnsafePointer<AudioBufferList>,
        format: PCMSampleFormat,
        into destination: UnsafeMutablePointer<Float>,
        capacity: Int
    ) -> Int {
        guard capacity > 0, list.pointee.mNumberBuffers > 0 else {
            return 0
        }
        let buffer = list.pointee.mBuffers
        guard let data = buffer.mData else {
            return 0
        }

        let stride = max(1, Int(buffer.mNumberChannels))
        let bytesPerFrame = format.bytesPerSample * stride
        let frameCount = min(Int(buffer.mDataByteSize) / bytesPerFrame, capacity)
        guard frameCount > 0 else {
            return 0
        }

        switch format {
        case .float32:
            let samples = data.assumingMemoryBound(to: Float32.self)
            for frame in 0..<frameCount {
                destination[frame] = SampleSanitizer.finiteOrZero(samples[frame * stride])
            }
        case .float64:
            let samples = data.assumingMemoryBound(to: Float64.self)
            for frame in 0..<frameCount {
                // Converted first: a finite Float64 beyond Float32's range
                // becomes an infinity.
                destination[frame] = SampleSanitizer.finiteOrZero(Float(samples[frame * stride]))
            }
        }
        return frameCount
    }
}
