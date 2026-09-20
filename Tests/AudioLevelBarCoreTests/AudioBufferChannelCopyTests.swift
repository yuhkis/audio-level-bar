import CoreAudio
import XCTest
@testable import AudioLevelBarCore

final class AudioBufferChannelCopyTests: XCTestCase {
    private struct TestBuffer<Sample> {
        var channels: UInt32
        var samples: [Sample]
        var hasData = true
    }

    private func withBufferList<Sample>(
        _ buffers: [TestBuffer<Sample>],
        _ body: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        let list = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
        var allocations: [UnsafeMutableRawPointer] = []
        defer {
            allocations.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }

        list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers.count)
        for (index, buffer) in buffers.enumerated() {
            let byteCount = buffer.samples.count * MemoryLayout<Sample>.stride
            var data: UnsafeMutableRawPointer?
            if buffer.hasData {
                let raw = UnsafeMutableRawPointer.allocate(
                    byteCount: max(byteCount, 1),
                    alignment: MemoryLayout<Sample>.alignment
                )
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

    private func copy(
        _ list: UnsafePointer<AudioBufferList>,
        format: PCMSampleFormat,
        capacity: Int
    ) -> [Float] {
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: max(capacity, 1))
        destination.initialize(repeating: .nan, count: max(capacity, 1))
        defer {
            destination.deallocate()
        }
        let count = AudioBufferChannelCopy.copyFirstChannel(
            list,
            format: format,
            into: destination,
            capacity: capacity
        )
        return Array(UnsafeBufferPointer(start: destination, count: count))
    }

    func testInterleavedStereoPicksTheLeftChannel() {
        let interleaved: [Float32] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
        withBufferList([TestBuffer(channels: 2, samples: interleaved)]) { list in
            XCTAssertEqual(copy(list, format: .float32, capacity: 16), [0.1, 0.2, 0.3])
        }
    }

    func testNonInterleavedPicksTheFirstBuffer() {
        let left = TestBuffer<Float32>(channels: 1, samples: [0.5, 0.25])
        let right = TestBuffer<Float32>(channels: 1, samples: [-0.5, -0.25])
        withBufferList([left, right]) { list in
            XCTAssertEqual(copy(list, format: .float32, capacity: 16), [0.5, 0.25])
        }
    }

    func testFloat64IsConverted() {
        let interleaved: [Float64] = [0.75, 9, -0.5, 9]
        withBufferList([TestBuffer(channels: 2, samples: interleaved)]) { list in
            XCTAssertEqual(copy(list, format: .float64, capacity: 16), [0.75, -0.5])
        }
    }

    func testCopyIsClampedToCapacity() {
        let mono: [Float32] = [1, 2, 3, 4, 5]
        withBufferList([TestBuffer(channels: 1, samples: mono)]) { list in
            XCTAssertEqual(copy(list, format: .float32, capacity: 3), [1, 2, 3])
            XCTAssertEqual(copy(list, format: .float32, capacity: 0), [])
        }
    }

    func testMissingDataCopiesNothing() {
        withBufferList([TestBuffer<Float32>(channels: 1, samples: [1, 2], hasData: false)]) { list in
            XCTAssertEqual(copy(list, format: .float32, capacity: 16), [])
        }
    }

    func testNonFiniteSamplesCopyAsZero() {
        let float32: [Float32] = [0.5, .nan, .infinity, -.infinity, -0.25]
        withBufferList([TestBuffer(channels: 1, samples: float32)]) { list in
            XCTAssertEqual(copy(list, format: .float32, capacity: 16), [0.5, 0, 0, 0, -0.25])
        }
        // 1e300 is finite as Float64 and infinite once converted to Float32.
        let float64: [Float64] = [.nan, 9, .infinity, 9, 1e300, 9, -.infinity, 9, 0.75, 9]
        withBufferList([TestBuffer(channels: 2, samples: float64)]) { list in
            XCTAssertEqual(copy(list, format: .float64, capacity: 16), [0, 0, 0, 0, 0.75])
        }
    }

    func testEmptyListCopiesNothing() {
        withBufferList([TestBuffer<Float32>]()) { list in
            XCTAssertEqual(copy(list, format: .float32, capacity: 16), [])
        }
    }

    func testPartialTrailingFrameIsDropped() {
        // Three samples in a two-channel buffer: one whole frame.
        let interleaved: [Float32] = [0.4, -0.4, 0.8]
        withBufferList([TestBuffer(channels: 2, samples: interleaved)]) { list in
            XCTAssertEqual(copy(list, format: .float32, capacity: 16), [0.4])
        }
    }
}
