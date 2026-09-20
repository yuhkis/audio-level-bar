import CoreAudio
import Foundation

/// The sample formats the level math reads: native-endian linear PCM float.
public enum PCMSampleFormat: Equatable {
    case float32
    case float64

    public init?(formatID: AudioFormatID, flags: AudioFormatFlags, bitsPerChannel: UInt32) {
        guard
            formatID == kAudioFormatLinearPCM,
            flags & kAudioFormatFlagIsFloat != 0,
            flags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian
        else {
            return nil
        }

        switch bitsPerChannel {
        case 32:
            self = .float32
        case 64:
            self = .float64
        default:
            return nil
        }
    }

    /// Also rejects a description whose frame size does not match whole
    /// samples of that width, interleaved or not, so an unexpected packing is
    /// reported rather than metered as noise.
    public init?(_ description: AudioStreamBasicDescription) {
        self.init(
            formatID: description.mFormatID,
            flags: description.mFormatFlags,
            bitsPerChannel: description.mBitsPerChannel
        )

        if description.mBytesPerFrame != 0, description.mChannelsPerFrame != 0 {
            let isNonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let samplesPerFrame = isNonInterleaved ? 1 : Int(description.mChannelsPerFrame)
            guard Int(description.mBytesPerFrame) == samplesPerFrame * bytesPerSample else {
                return nil
            }
        }
    }

    public var bytesPerSample: Int {
        switch self {
        case .float32:
            return MemoryLayout<Float32>.size
        case .float64:
            return MemoryLayout<Float64>.size
        }
    }
}

/// Accumulates RMS and peak over the samples of successive AudioBufferLists.
///
/// Every sample in every buffer counts, so interleaved and non-interleaved
/// layouts of the same audio give the same result. The work is allocation-free
/// and lock-free.
public struct LevelAccumulator {
    private var sumOfSquares: Double = 0
    private var peak: Double = 0
    public private(set) var sampleCount = 0

    public init() {}

    public mutating func add(_ list: UnsafePointer<AudioBufferList>, format: PCMSampleFormat) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        for buffer in buffers {
            guard let data = buffer.mData else {
                continue
            }
            // A partial trailing sample is dropped.
            let count = Int(buffer.mDataByteSize) / format.bytesPerSample
            switch format {
            case .float32:
                let samples = data.assumingMemoryBound(to: Float32.self)
                for index in 0..<count {
                    accumulate(Double(samples[index]))
                }
            case .float64:
                let samples = data.assumingMemoryBound(to: Float64.self)
                for index in 0..<count {
                    accumulate(samples[index])
                }
            }
            sampleCount += count
        }
    }

    /// The levels of everything added since the last take, or nil when no
    /// sample was added. Resets the accumulator either way.
    public mutating func take() -> (rmsDecibels: Float, peakDecibels: Float)? {
        defer {
            self = LevelAccumulator()
        }
        guard sampleCount > 0 else {
            return nil
        }
        let rms = (sumOfSquares / Double(sampleCount)).squareRoot()
        return (
            rmsDecibels: MeterScale.decibels(amplitude: Float(rms)),
            peakDecibels: MeterScale.decibels(amplitude: Float(peak))
        )
    }

    @inline(__always)
    private mutating func accumulate(_ sample: Double) {
        // A non-finite sample counts as silence rather than poisoning the
        // whole window.
        guard sample.isFinite else {
            return
        }
        let amplitude = abs(sample)
        sumOfSquares += amplitude * amplitude
        if amplitude > peak {
            peak = amplitude
        }
    }
}

public enum AudioBufferLevels {
    /// How many samples, across all channels, make up one metering window.
    public static func windowSampleCount(
        sampleRate: Double,
        channelCount: Int,
        seconds: Double = 0.1
    ) -> Int {
        let samples = sampleRate * Double(channelCount) * seconds
        guard samples.isFinite, samples >= 1 else {
            return 1
        }
        return Int(min(samples.rounded(), Double(Int32.max)))
    }

    public static func levels(
        _ list: UnsafePointer<AudioBufferList>,
        format: PCMSampleFormat
    ) -> (rmsDecibels: Float, peakDecibels: Float)? {
        var accumulator = LevelAccumulator()
        accumulator.add(list, format: format)
        return accumulator.take()
    }
}
