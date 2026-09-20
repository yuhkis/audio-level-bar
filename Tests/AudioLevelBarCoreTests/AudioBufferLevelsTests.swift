import CoreAudio
import XCTest
@testable import AudioLevelBarCore

final class AudioBufferLevelsTests: XCTestCase {
    private struct TestBuffer<Sample> {
        var channels: UInt32
        var samples: [Sample]
        /// Added to the byte size, to model a partial trailing sample.
        var extraBytes = 0
        var hasData = true
    }

    private func withBufferList<Sample>(
        _ buffers: [TestBuffer<Sample>],
        _ body: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        var allocations: [UnsafeMutableRawPointer] = []
        defer {
            allocations.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }

        for (index, buffer) in buffers.enumerated() {
            let byteCount = buffer.samples.count * MemoryLayout<Sample>.stride + buffer.extraBytes
            var data: UnsafeMutableRawPointer?
            if buffer.hasData {
                let raw = UnsafeMutableRawPointer.allocate(
                    byteCount: max(byteCount, 1),
                    alignment: MemoryLayout<Sample>.alignment
                )
                raw.initializeMemory(as: UInt8.self, repeating: 0, count: max(byteCount, 1))
                buffer.samples.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress {
                        raw.copyMemory(from: base, byteCount: bytes.count)
                    }
                }
                allocations.append(raw)
                data = raw
            }
            list[index] = AudioBuffer(
                mNumberChannels: buffer.channels,
                mDataByteSize: UInt32(byteCount),
                mData: data
            )
        }

        body(UnsafePointer(list.unsafePointer))
    }

    private func sine(count: Int, period: Int = 48) -> [Float32] {
        (0..<count).map { Float32(sin(2 * Double.pi * Double($0) / Double(period))) }
    }

    func testFullScaleSineIsMinusThreeDecibelsRMS() {
        withBufferList([TestBuffer(channels: 1, samples: sine(count: 4_800))]) { list in
            let levels = AudioBufferLevels.levels(list, format: .float32)
            XCTAssertEqual(levels?.rmsDecibels ?? 0, -3.0103, accuracy: 0.01)
            XCTAssertEqual(levels?.peakDecibels ?? -1, 0, accuracy: 0.001)
        }
    }

    func testHalfScaleDCIsMinusSixDecibels() {
        let samples = [Float32](repeating: 0.5, count: 480)
        withBufferList([TestBuffer(channels: 1, samples: samples)]) { list in
            let levels = AudioBufferLevels.levels(list, format: .float32)
            XCTAssertEqual(levels?.rmsDecibels ?? 0, -6.0206, accuracy: 0.001)
            XCTAssertEqual(levels?.peakDecibels ?? 0, -6.0206, accuracy: 0.001)
        }
    }

    func testNegativeSampleSetsThePeak() {
        withBufferList([TestBuffer<Float32>(channels: 1, samples: [0.1, -0.8, 0.2])]) { list in
            let levels = AudioBufferLevels.levels(list, format: .float32)
            XCTAssertEqual(levels?.peakDecibels ?? 0, 20 * log10(0.8), accuracy: 0.001)
        }
    }

    func testInterleavedAndNonInterleavedLayoutsAgree() {
        let left: [Float32] = [0.1, -0.4, 0.3, 0.05]
        let right: [Float32] = [-0.2, 0.6, 0.0, -0.1]
        let interleaved = zip(left, right).flatMap { [$0, $1] }

        var nonInterleavedLevels: (rmsDecibels: Float, peakDecibels: Float)?
        withBufferList([
            TestBuffer(channels: 1, samples: left),
            TestBuffer(channels: 1, samples: right)
        ]) { list in
            nonInterleavedLevels = AudioBufferLevels.levels(list, format: .float32)
        }

        withBufferList([TestBuffer(channels: 2, samples: interleaved)]) { list in
            var accumulator = LevelAccumulator()
            accumulator.add(list, format: .float32)
            XCTAssertEqual(accumulator.sampleCount, 8)
            let levels = accumulator.take()
            XCTAssertEqual(levels?.rmsDecibels ?? 0, nonInterleavedLevels?.rmsDecibels ?? 1, accuracy: 0.0001)
            XCTAssertEqual(levels?.peakDecibels ?? 0, nonInterleavedLevels?.peakDecibels ?? 1, accuracy: 0.0001)
            XCTAssertEqual(levels?.peakDecibels ?? 0, 20 * log10(0.6), accuracy: 0.001)
        }
    }

    func testFloat64Samples() {
        let samples = [Float64](repeating: 0.5, count: 100) + [Float64](repeating: -0.5, count: 100)
        withBufferList([TestBuffer(channels: 2, samples: samples)]) { list in
            var accumulator = LevelAccumulator()
            accumulator.add(list, format: .float64)
            XCTAssertEqual(accumulator.sampleCount, 200)
            let levels = accumulator.take()
            XCTAssertEqual(levels?.rmsDecibels ?? 0, -6.0206, accuracy: 0.001)
            XCTAssertEqual(levels?.peakDecibels ?? 0, -6.0206, accuracy: 0.001)
        }
    }

    func testBufferWithoutDataIsSkipped() {
        withBufferList([
            TestBuffer<Float32>(channels: 1, samples: [1, 1, 1, 1], hasData: false),
            TestBuffer<Float32>(channels: 1, samples: [0.5, 0.5])
        ]) { list in
            var accumulator = LevelAccumulator()
            accumulator.add(list, format: .float32)
            XCTAssertEqual(accumulator.sampleCount, 2)
            XCTAssertEqual(accumulator.take()?.peakDecibels ?? 0, -6.0206, accuracy: 0.001)
        }
    }

    func testPartialTrailingSampleIsDropped() {
        withBufferList([TestBuffer<Float32>(channels: 1, samples: [0.5, 0.5, 0.5], extraBytes: 2)]) { list in
            var accumulator = LevelAccumulator()
            accumulator.add(list, format: .float32)
            XCTAssertEqual(accumulator.sampleCount, 3)
        }
    }

    func testNoSamplesGiveNoLevels() {
        var empty = LevelAccumulator()
        XCTAssertNil(empty.take())

        withBufferList([TestBuffer<Float32>(channels: 1, samples: [])]) { list in
            XCTAssertNil(AudioBufferLevels.levels(list, format: .float32))
        }
    }

    func testTakeResetsTheAccumulator() {
        withBufferList([TestBuffer<Float32>(channels: 1, samples: [0.5, -0.5])]) { list in
            var accumulator = LevelAccumulator()
            accumulator.add(list, format: .float32)
            XCTAssertNotNil(accumulator.take())
            XCTAssertEqual(accumulator.sampleCount, 0)
            XCTAssertNil(accumulator.take())
        }
    }

    func testNonFiniteSampleCountsAsSilence() {
        withBufferList([TestBuffer<Float32>(channels: 1, samples: [0.5, .nan, 0.5, .infinity])]) { list in
            let levels = AudioBufferLevels.levels(list, format: .float32)
            XCTAssertEqual(levels?.peakDecibels ?? 0, -6.0206, accuracy: 0.001)
            XCTAssertEqual(levels?.rmsDecibels ?? 0, Float(20 * log10(0.5 / 2.0.squareRoot())), accuracy: 0.001)
        }
    }

    func testAccumulatingSeveralListsMatchesOneConcatenatedList() {
        let first: [Float32] = sine(count: 300, period: 37).map { $0 * 0.3 }
        let second: [Float32] = [0.9, -0.2, 0.05, -0.7]
        let third: [Float32] = sine(count: 500, period: 11).map { $0 * 0.1 }

        var accumulator = LevelAccumulator()
        for part in [first, second, third] {
            withBufferList([TestBuffer(channels: 1, samples: part)]) { list in
                accumulator.add(list, format: .float32)
            }
        }
        XCTAssertEqual(accumulator.sampleCount, 804)
        let accumulated = accumulator.take()

        withBufferList([TestBuffer(channels: 1, samples: first + second + third)]) { list in
            let oneShot = AudioBufferLevels.levels(list, format: .float32)
            XCTAssertEqual(accumulated?.rmsDecibels ?? 0, oneShot?.rmsDecibels ?? 1, accuracy: 0.0001)
            XCTAssertEqual(accumulated?.peakDecibels ?? 0, oneShot?.peakDecibels ?? 1, accuracy: 0.0001)
        }
    }

    func testWindowSampleCount() {
        XCTAssertEqual(AudioBufferLevels.windowSampleCount(sampleRate: 48_000, channelCount: 2), 9_600)
        XCTAssertEqual(AudioBufferLevels.windowSampleCount(sampleRate: 44_100, channelCount: 1), 4_410)
        XCTAssertEqual(AudioBufferLevels.windowSampleCount(sampleRate: 24_000, channelCount: 1, seconds: 0.05), 1_200)
        XCTAssertEqual(AudioBufferLevels.windowSampleCount(sampleRate: 0, channelCount: 2), 1)
        XCTAssertEqual(AudioBufferLevels.windowSampleCount(sampleRate: 48_000, channelCount: 0), 1)
        XCTAssertEqual(AudioBufferLevels.windowSampleCount(sampleRate: .nan, channelCount: 2), 1)
    }

    func testSampleFormatAcceptsNativeFloatOnly() {
        let float = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        XCTAssertEqual(
            PCMSampleFormat(formatID: kAudioFormatLinearPCM, flags: float, bitsPerChannel: 32),
            .float32
        )
        XCTAssertEqual(
            PCMSampleFormat(
                formatID: kAudioFormatLinearPCM,
                flags: float | kAudioFormatFlagIsNonInterleaved,
                bitsPerChannel: 64
            ),
            .float64
        )
        XCTAssertNil(
            PCMSampleFormat(
                formatID: kAudioFormatLinearPCM,
                flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                bitsPerChannel: 32
            )
        )
        XCTAssertNil(PCMSampleFormat(formatID: kAudioFormatLinearPCM, flags: float, bitsPerChannel: 24))
        XCTAssertNil(PCMSampleFormat(formatID: kAudioFormatAppleLossless, flags: float, bitsPerChannel: 32))
        #if _endian(little)
        XCTAssertNil(
            PCMSampleFormat(
                formatID: kAudioFormatLinearPCM,
                flags: float | kAudioFormatFlagIsBigEndian,
                bitsPerChannel: 32
            )
        )
        #endif
    }

    func testSampleFormatFromStreamDescriptionChecksTheFrameSize() {
        func description(
            flags: AudioFormatFlags,
            bits: UInt32,
            bytesPerFrame: UInt32,
            channels: UInt32
        ) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: 48_000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags,
                mBytesPerPacket: bytesPerFrame,
                mFramesPerPacket: 1,
                mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: channels,
                mBitsPerChannel: bits,
                mReserved: 0
            )
        }
        let float = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked

        XCTAssertEqual(
            PCMSampleFormat(description(flags: float, bits: 32, bytesPerFrame: 8, channels: 2)),
            .float32
        )
        XCTAssertEqual(
            PCMSampleFormat(
                description(flags: float | kAudioFormatFlagIsNonInterleaved, bits: 32, bytesPerFrame: 4, channels: 2)
            ),
            .float32
        )
        XCTAssertEqual(
            PCMSampleFormat(description(flags: float, bits: 64, bytesPerFrame: 16, channels: 2)),
            .float64
        )
        XCTAssertNil(
            PCMSampleFormat(description(flags: float, bits: 32, bytesPerFrame: 4, channels: 2))
        )
        XCTAssertNil(
            PCMSampleFormat(
                description(flags: float | kAudioFormatFlagIsNonInterleaved, bits: 32, bytesPerFrame: 8, channels: 2)
            )
        )
    }
}
