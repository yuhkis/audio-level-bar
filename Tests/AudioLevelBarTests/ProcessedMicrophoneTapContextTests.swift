import AVFoundation
import XCTest
@testable import AudioLevelBar

/// Apple voice processing's input tap is installed with no format, so a
/// buffer can arrive at another rate than the one the ring buffer was made
/// for. Such a buffer is dropped, and the level timer is told once.
final class ProcessedMicrophoneTapContextTests: XCTestCase {
    private func buffer(sampleRate: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for index in 0..<480 {
            buffer.floatChannelData?[0][index] = 0.25
        }
        return buffer
    }

    private func context() throws -> (ProcessedMicrophoneTapContext, ProcessedMicrophoneRingBuffer) {
        let monoFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let ringBuffer = try XCTUnwrap(ProcessedMicrophoneRingBuffer(format: monoFormat, duration: 0.25))
        let context = try ProcessedMicrophoneTapContext(
            gainScalar: ProcessedMicrophoneAtomicFloat(1),
            ringBuffer: ringBuffer,
            sampleRate: 48_000,
            webRTCLevel: nil
        )
        return (context, ringBuffer)
    }

    func testABufferAtTheExpectedRateIsWritten() throws {
        let (context, ringBuffer) = try context()

        context.process(try buffer(sampleRate: 48_000))

        XCTAssertFalse(context.consumeFormatMismatch())
        XCTAssertNotNil(ringBuffer.latestLevels(after: 0), "its levels reach the ring")
    }

    func testABufferAtAnotherRateIsDroppedAndReportedOnce() throws {
        let (context, ringBuffer) = try context()

        context.process(try buffer(sampleRate: 16_000))
        context.process(try buffer(sampleRate: 16_000))

        XCTAssertNil(ringBuffer.latestLevels(after: 0), "nothing at the wrong rate reaches the ring")
        XCTAssertTrue(context.consumeFormatMismatch())
        XCTAssertFalse(context.consumeFormatMismatch(), "reported once")
    }
}
