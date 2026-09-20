import Foundation

/// A Bluetooth refusal of the processed microphone's source that an uncached
/// read found and the poll did not, kept with what the poll showed then.
///
/// The poll decides from cached transports and can keep allowing a source
/// that the read made immediately before opening it refuses. Retrying on
/// every evaluation, or once per quiet window, would repeat that read and its
/// refusal while nothing the poll can see has changed. The latch holds the
/// refusal instead, until the poll shows a different device or transport.
public struct SourceRefusalLatch: Equatable {
    public enum Scope: Equatable {
        /// The capture refused its input. Stands whatever the processing
        /// mode, because the input is refused for every mode.
        case input
        /// Apple voice processing refused the default input or output it was
        /// about to open. Stands only while that mode is selected.
        case voiceProcessing
        /// The read made before the publisher engine is built found no
        /// output it may be bound to. Stands whatever the mode and the input,
        /// while the poll shows the same default output and transport.
        case publisherOutput
    }

    public let scope: Scope
    public let refusal: ProcessedMicrophoneRefusal
    public let inputDeviceID: UInt32
    public let input: AudioDeviceTransportInfo?
    public let outputDeviceID: UInt32
    public let output: AudioDeviceTransportInfo?

    /// The capture's uncached re-read refused the input it was started for as
    /// a Bluetooth microphone, or an aggregate device with a Bluetooth
    /// member. A read that only failed, of the transport or of an aggregate
    /// member the poll had resolved, is not a refusal to latch: it is retried,
    /// spaced and capped (`CaptureInputRetry`).
    /// - Parameter polledInput: The input's transport as the poll shows it.
    public static func captureInput(
        deviceID: UInt32,
        polledInput: AudioDeviceTransportInfo?
    ) -> SourceRefusalLatch {
        SourceRefusalLatch(
            scope: .input,
            refusal: .bluetoothInput,
            inputDeviceID: deviceID,
            input: polledInput,
            outputDeviceID: 0,
            output: nil
        )
    }

    /// The check Apple voice processing made on the defaults it read again
    /// immediately before starting. A latch only for a Bluetooth refusal of
    /// the devices the start was decided on; a default that moved, or one
    /// that could not be read, is a change to wait out, not a refusal. Nor is
    /// a connected Bluetooth device the fresh read found: the latch compares
    /// the defaults, which say nothing about it, and the poll that shows the
    /// device refuses by itself.
    public static func voiceProcessing(
        _ check: VoiceProcessingDeviceCheck,
        inputDeviceID: UInt32,
        polledInput: AudioDeviceTransportInfo?,
        outputDeviceID: UInt32,
        polledOutput: AudioDeviceTransportInfo?
    ) -> SourceRefusalLatch? {
        guard
            case let .refused(refusal) = check,
            refusal.involvesBluetooth,
            refusal != .bluetoothDevicePresentForVoiceProcessing
        else {
            return nil
        }
        return SourceRefusalLatch(
            scope: .voiceProcessing,
            refusal: refusal,
            inputDeviceID: inputDeviceID,
            input: polledInput,
            outputDeviceID: outputDeviceID,
            output: polledOutput
        )
    }

    /// The uncached read made before the publisher engine is built found no
    /// output it may be bound to, while the poll still showed one.
    /// - Parameters:
    ///   - outputDeviceID: The default output as the poll shows it.
    ///   - polledOutput: Its transport as the poll shows it.
    public static func publisherOutput(
        outputDeviceID: UInt32,
        polledOutput: AudioDeviceTransportInfo?
    ) -> SourceRefusalLatch {
        SourceRefusalLatch(
            scope: .publisherOutput,
            refusal: .noNonBluetoothOutput,
            inputDeviceID: 0,
            input: nil,
            outputDeviceID: outputDeviceID,
            output: polledOutput
        )
    }

    /// Whether the refusal still stands for what the poll shows now.
    public func stands(
        usesVoiceProcessing: Bool,
        inputDeviceID: UInt32,
        input: AudioDeviceTransportInfo?,
        outputDeviceID: UInt32,
        output: AudioDeviceTransportInfo?
    ) -> Bool {
        let sameInput = inputDeviceID == self.inputDeviceID && input == self.input
        let sameOutput = outputDeviceID == self.outputDeviceID && output == self.output
        switch scope {
        case .input:
            return sameInput
        case .voiceProcessing:
            return sameInput && usesVoiceProcessing && sameOutput
        case .publisherOutput:
            return sameOutput
        }
    }
}
