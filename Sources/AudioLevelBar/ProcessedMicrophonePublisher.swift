import AudioLevelBarCore
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// What the publisher's IOProc block reads on the HAL IO thread: the ring
/// buffer the capture writes, preallocated mono storage, and, when the ring's
/// sample rate is not the output's, a sample-rate converter.
///
/// The block does not retain it. `ProcessedMicrophoneDeviceCapture` owns it
/// and releases it only after the IOProc has been destroyed.
///
/// Each IO cycle zeroes every output buffer, then, while the gate is open,
/// writes the mono signal into every channel of every output stream. With the
/// gate closed it writes silence: the owner closes it, on the main thread,
/// before it withdraws the muted public tap, so that once the tap is gone the
/// output device receives nothing but silence from this process, even while
/// the IOProc's stop still waits on the lifecycle queue. A cycle already
/// under way when the gate closes finishes with what it read.
final class ProcessedMicrophonePublisherContext: @unchecked Sendable {
    private let ringBuffer: ProcessedMicrophoneRingBuffer
    private let capacityFrames: Int
    /// The mono signal at the output's sample rate.
    private let mono: UnsafeMutablePointer<Float>
    private let monoList: UnsafeMutableAudioBufferListPointer
    /// The ring's frames handed to the converter, at the ring's sample rate.
    private let converterInput: UnsafeMutablePointer<Float>?
    private let converterInputList: UnsafeMutableAudioBufferListPointer?
    private let converterInputCapacity: Int
    private let converter: AudioConverterRef?
    /// 1 while the ring is rendered, 0 once closed. The IO thread only reads
    /// it.
    private var gate: Int32 = 1

    /// nil when either sample rate is not one `SampleRatePolicy` accepts, or
    /// a converter between them could not be made.
    ///
    /// - Parameter maximumFrames: The largest IO buffer the output may ask
    ///   for, in frames. A larger request is rendered as far as this and
    ///   silent beyond it.
    init?(
        ringBuffer: ProcessedMicrophoneRingBuffer,
        inputSampleRate: Double,
        outputSampleRate: Double,
        maximumFrames: Int
    ) {
        guard
            SampleRatePolicy.isUsable(inputSampleRate),
            SampleRatePolicy.isUsable(outputSampleRate),
            maximumFrames > 0
        else {
            return nil
        }
        self.ringBuffer = ringBuffer
        capacityFrames = maximumFrames
        mono = .allocate(capacity: maximumFrames)
        mono.initialize(repeating: 0, count: maximumFrames)
        monoList = AudioBufferList.allocate(maximumBuffers: 1)

        guard inputSampleRate != outputSampleRate else {
            converterInput = nil
            converterInputList = nil
            converterInputCapacity = 0
            converter = nil
            return
        }
        var inputDescription = Self.monoFloatDescription(sampleRate: inputSampleRate)
        var outputDescription = Self.monoFloatDescription(sampleRate: outputSampleRate)
        var newConverter: AudioConverterRef?
        guard
            AudioConverterNew(&inputDescription, &outputDescription, &newConverter) == noErr,
            let newConverter
        else {
            mono.deinitialize(count: maximumFrames)
            mono.deallocate()
            free(monoList.unsafeMutablePointer)
            return nil
        }
        converter = newConverter
        // Enough input for one output buffer at the highest ratio the policy
        // allows, with room for the converter's filter.
        let ratio = inputSampleRate / outputSampleRate
        converterInputCapacity = Int((Double(maximumFrames) * ratio).rounded(.up)) + 1_024
        let input = UnsafeMutablePointer<Float>.allocate(capacity: converterInputCapacity)
        input.initialize(repeating: 0, count: converterInputCapacity)
        converterInput = input
        converterInputList = AudioBufferList.allocate(maximumBuffers: 1)
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
        if let converterInput {
            converterInput.deinitialize(count: converterInputCapacity)
            converterInput.deallocate()
        }
        if let converterInputList {
            free(converterInputList.unsafeMutablePointer)
        }
        mono.deinitialize(count: capacityFrames)
        mono.deallocate()
        free(monoList.unsafeMutablePointer)
    }

    /// Whether the ring is resampled on its way to the output.
    var converts: Bool {
        converter != nil
    }

    /// HAL IO thread only. No allocation, lock or dispatch.
    func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        var frameCount = 0
        for buffer in buffers {
            guard let data = buffer.mData else {
                continue
            }
            data.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
            let channels = max(Int(buffer.mNumberChannels), 1)
            frameCount = max(frameCount, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        }
        guard OSAtomicAdd32Barrier(0, &gate) != 0 else {
            return
        }
        let frames = min(frameCount, capacityFrames)
        guard frames > 0 else {
            return
        }
        let produced = produceMono(frameCount: frames)
        guard produced > 0 else {
            return
        }
        for buffer in buffers {
            guard let data = buffer.mData else {
                continue
            }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let bufferFrames = min(produced, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let output = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<bufferFrames {
                let sample = mono[frame]
                for channel in 0..<channels {
                    output[frame * channels + channel] = sample
                }
            }
        }
    }

    /// Stops rendering the ring. True when this call closed an open gate.
    @discardableResult
    func close() -> Bool {
        OSAtomicCompareAndSwap32Barrier(1, 0, &gate)
    }

    /// Fills `mono` with `frameCount` frames at the output's rate, and
    /// returns how many it wrote.
    private func produceMono(frameCount: Int) -> Int {
        guard let converter else {
            _ = readRing(into: mono, list: monoList, frameCount: frameCount)
            return frameCount
        }
        monoList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(mono)
        )
        var packets = UInt32(frameCount)
        let status = AudioConverterFillComplexBuffer(
            converter,
            Self.supplyConverterInput,
            Unmanaged.passUnretained(self).toOpaque(),
            &packets,
            monoList.unsafeMutablePointer,
            nil
        )
        return status == noErr ? Int(packets) : 0
    }

    /// Reads up to `frameCount` frames of the ring into `storage`, silence
    /// where the ring has none, and returns how many were the ring's.
    private func readRing(
        into storage: UnsafeMutablePointer<Float>,
        list: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) -> Int {
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(storage)
        )
        return ringBuffer.read(into: list.unsafeMutablePointer, frameCount: frameCount)
    }

    /// The converter's input: as many of the ring's frames as it asks for, up
    /// to the storage allocated for them, silence where the ring has none, so
    /// that the converter never runs dry within a cycle.
    private static let supplyConverterInput: AudioConverterComplexInputDataProc = {
        _, packetCount, data, _, userData in
        guard let userData else {
            packetCount.pointee = 0
            return kAudioConverterErr_UnspecifiedError
        }
        let context = Unmanaged<ProcessedMicrophonePublisherContext>
            .fromOpaque(userData)
            .takeUnretainedValue()
        guard let input = context.converterInput, let list = context.converterInputList else {
            packetCount.pointee = 0
            return kAudioConverterErr_UnspecifiedError
        }
        let frames = min(Int(packetCount.pointee), context.converterInputCapacity)
        _ = context.readRing(into: input, list: list, frameCount: frames)
        let supplied = UnsafeMutableAudioBufferListPointer(data)
        supplied[0] = list[0]
        packetCount.pointee = UInt32(frames)
        return noErr
    }

    private static func monoFloatDescription(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
