import Foundation

/// Why the processed microphone does not capture from the default input.
public enum ProcessedMicrophoneRefusal: Equatable {
    /// There is no default input.
    case noInput
    /// A transport that would rule Bluetooth out has not been read.
    case transportNotRead
    /// The default input is a Bluetooth microphone, or an aggregate with a
    /// Bluetooth member, active or not, or with a member that cannot be
    /// resolved.
    case bluetoothInput
    /// Apple voice processing is selected and the default output involves
    /// Bluetooth. Its engine opens the default input and output as a pair and
    /// follows them, so a Bluetooth output is as unsafe for it as a Bluetooth
    /// microphone.
    case bluetoothOutputForVoiceProcessing
    /// Apple voice processing is selected and a Bluetooth or Bluetooth LE
    /// audio device is connected, default or not. macOS can make a connected
    /// headset the default at any moment, and that switch happens inside the
    /// headset's own configuration change: an engine that follows the
    /// defaults would move onto it before any quiet window could stop it.
    case bluetoothDevicePresentForVoiceProcessing
    /// There is no output the publisher engine may be bound to: no built-in
    /// output, and no other output known not to involve Bluetooth. The engine
    /// is never bound to a Bluetooth output, nor left to follow the default
    /// output onto one. See `PublisherOutputPolicy`.
    case noNonBluetoothOutput

    /// Whether the refusal is about Bluetooth, which the user is told about.
    /// The other refusals are a device not being known yet, which the feature
    /// simply waits out.
    public var involvesBluetooth: Bool {
        switch self {
        case .bluetoothInput, .bluetoothOutputForVoiceProcessing, .bluetoothDevicePresentForVoiceProcessing,
             .noNonBluetoothOutput:
            return true
        case .noInput, .transportNotRead:
            return false
        }
    }
}

public enum ProcessedMicrophoneSourceDecision: Equatable {
    case allowed
    case refused(ProcessedMicrophoneRefusal)
}

/// Decides whether the processed microphone may capture from the default
/// input, and for Apple voice processing, run against the default output.
///
/// The input goes through `InputOpenPolicy`, the same rule the level meter
/// follows: the app never opens a Bluetooth microphone by itself, and turning
/// the processed microphone on does not change that. Processing modes that
/// capture from one explicitly chosen device do not care about the default
/// output, nor about Bluetooth devices that are not the input. Apple voice
/// processing does, because its engine follows the default input and output
/// itself: it does not run while any Bluetooth audio device is connected, or
/// while whether one is cannot be told. Every mode needs an output the
/// publisher engine may be bound to, chosen by `PublisherOutputPolicy`.
public enum ProcessedMicrophoneSourcePolicy {
    /// The decision with the publisher engine's output taken into account:
    /// the input and, for Apple voice processing, the connected Bluetooth
    /// devices and the default output first, then whether an output the
    /// publisher may be bound to exists.
    public static func decide(
        usesVoiceProcessing: Bool,
        inputDeviceID: UInt32,
        input: AudioDeviceTransportInfo?,
        output: AudioDeviceTransportInfo?,
        bluetoothDevicePresent: Bool?,
        publisherOutput: PublisherOutputChoice
    ) -> ProcessedMicrophoneSourceDecision {
        let decision = decide(
            usesVoiceProcessing: usesVoiceProcessing,
            inputDeviceID: inputDeviceID,
            input: input,
            output: output,
            bluetoothDevicePresent: bluetoothDevicePresent
        )
        guard decision == .allowed else {
            return decision
        }
        switch publisherOutput {
        case .device:
            return .allowed
        case .refused(.noNonBluetoothOutput):
            return .refused(.noNonBluetoothOutput)
        case .refused(.outputsNotRead):
            return .refused(.transportNotRead)
        }
    }

    /// The decision on the input and, for Apple voice processing, the
    /// connected Bluetooth devices and the default output alone.
    ///
    /// - Parameter bluetoothDevicePresent: Whether a Bluetooth or Bluetooth LE
    ///   audio device is connected, nil when that could not be read; see
    ///   `bluetoothDevicePresence`. Only Apple voice processing reads it.
    public static func decide(
        usesVoiceProcessing: Bool,
        inputDeviceID: UInt32,
        input: AudioDeviceTransportInfo?,
        output: AudioDeviceTransportInfo?,
        bluetoothDevicePresent: Bool?
    ) -> ProcessedMicrophoneSourceDecision {
        switch InputOpenPolicy.decide(deviceID: inputDeviceID, info: input) {
        case .refuse(.noDevice):
            return .refused(.noInput)
        case .refuse(.transportNotRead):
            return .refused(.transportNotRead)
        case .refuse(.bluetooth), .refuse(.aggregateWithBluetoothMember), .refuse(.aggregateWithUnresolvedMember):
            return .refused(.bluetoothInput)
        case .open:
            break
        }

        guard usesVoiceProcessing else {
            return .allowed
        }
        // Checked first: while a Bluetooth device is connected, whether the
        // defaults involve it is only a matter of time, and the reason the
        // user sees stays the same until the last one disconnects.
        if bluetoothDevicePresent == true {
            return .refused(.bluetoothDevicePresentForVoiceProcessing)
        }
        guard let output else {
            return .refused(.transportNotRead)
        }
        if InputOpenPolicy.involvesBluetooth(output) {
            return .refused(.bluetoothOutputForVoiceProcessing)
        }
        guard bluetoothDevicePresent != nil else {
            return .refused(.transportNotRead)
        }
        return .allowed
    }

    /// Checks the default devices Apple voice processing is about to open,
    /// read again immediately before its engine starts, against the devices
    /// the start was decided on.
    ///
    /// Voice Processing I/O opens whatever the defaults are when it starts, so
    /// a default that moved since the decision, even to a wired device, stops
    /// the start: the next decision is made from a fresh poll.
    ///
    /// - Parameter bluetoothDevicePresent: Whether the same uncached read
    ///   found a Bluetooth audio device connected, nil when it could not tell.
    public static func checkVoiceProcessingDevices(
        decidedInputDeviceID: UInt32,
        decidedOutputDeviceID: UInt32,
        inputDeviceID: UInt32,
        outputDeviceID: UInt32,
        input: AudioDeviceTransportInfo?,
        output: AudioDeviceTransportInfo?,
        bluetoothDevicePresent: Bool?
    ) -> VoiceProcessingDeviceCheck {
        guard inputDeviceID == decidedInputDeviceID else {
            return .inputMoved
        }
        guard outputDeviceID == decidedOutputDeviceID else {
            return .outputMoved
        }
        switch decide(
            usesVoiceProcessing: true,
            inputDeviceID: inputDeviceID,
            input: input,
            output: output,
            bluetoothDevicePresent: bluetoothDevicePresent
        ) {
        case .allowed:
            return .unchanged
        case let .refused(refusal):
            return .refused(refusal)
        }
    }

    /// Whether a Bluetooth or Bluetooth LE audio device is connected, from a
    /// poll's device list: true when the poll found one, false when it read
    /// the transport of every listed device and none is Bluetooth, and nil
    /// when it could not tell, because the list or a device's transport was
    /// not read. A device whose transport was not read could be Bluetooth.
    public static func bluetoothDevicePresence(
        bluetoothDeviceIDs: Set<UInt32>,
        everyTransportRead: Bool
    ) -> Bool? {
        if !bluetoothDeviceIDs.isEmpty {
            return true
        }
        return everyTransportRead ? false : nil
    }

    /// The same from the transports of a device list read uncached: nil when
    /// the list could not be read, or when a listed device's transport (a nil
    /// element) could not be read and none of the others is Bluetooth.
    public static func bluetoothDevicePresence(
        listedTransports: [AudioDeviceTransport?]?
    ) -> Bool? {
        guard let listedTransports else {
            return nil
        }
        if listedTransports.contains(where: { $0.map(InputOpenPolicy.isBluetooth) ?? false }) {
            return true
        }
        return listedTransports.contains(where: { $0 == nil }) ? nil : false
    }
}

/// The outcome of re-reading the default devices before Apple voice
/// processing starts.
public enum VoiceProcessingDeviceCheck: Equatable {
    /// The same devices, and neither involves Bluetooth.
    case unchanged
    case inputMoved
    case outputMoved
    /// The same devices, which the policy now refuses.
    case refused(ProcessedMicrophoneRefusal)

    /// Whether the output, rather than the input, is what the check objects
    /// to, for the log line.
    public var concernsOutput: Bool {
        switch self {
        case .outputMoved, .refused(.bluetoothOutputForVoiceProcessing), .refused(.noNonBluetoothOutput):
            return true
        case .unchanged, .inputMoved, .refused:
            return false
        }
    }

    /// Compares the default devices, read again by ID alone immediately
    /// before or after Apple voice processing's engine starts, with the
    /// devices the start was decided on. Only the IDs are read at that point,
    /// so this reports a move and nothing else. A default that could not be
    /// read, passed as 0, counts as moved.
    public static func defaults(
        decidedInputDeviceID: UInt32,
        decidedOutputDeviceID: UInt32,
        inputDeviceID: UInt32,
        outputDeviceID: UInt32
    ) -> VoiceProcessingDeviceCheck {
        guard inputDeviceID != 0, inputDeviceID == decidedInputDeviceID else {
            return .inputMoved
        }
        guard outputDeviceID != 0, outputDeviceID == decidedOutputDeviceID else {
            return .outputMoved
        }
        return .unchanged
    }
}

/// Decides the processed microphone's next lifecycle step from where it is.
///
/// The owner evaluates this after every poll and every event that changes one
/// of the conditions, and performs the returned action. Events only record
/// what changed; nothing that creates, starts, stops or destroys a HAL
/// resource for the processed microphone happens anywhere else, so every such
/// step waits for the quiet window.
///
/// Three invariants hold by construction and are pinned by tests:
/// - A teardown is never returned while a consuming app has the published
///   device open. Destroying a public aggregate under a consumer stops
///   coreaudiod answering any process on the machine.
/// - A refusal only ever stops the processing engines. The publication stays,
///   and a consumer receives silence until the source is allowed again.
/// - While starts are held, only stops and owed teardowns are returned. A
///   restart is cut to its stop, and the start waits for a release that
///   admits it.
public enum ProcessedMicrophonePlan {
    public struct Conditions: Equatable {
        /// Switched on, permitted, and not halted by a failure the user has
        /// to retry.
        public var enabled: Bool
        /// The app holds a publication of the processed microphone.
        public var published: Bool
        /// A consuming app has the published device open, as last read.
        public var inUse: Bool
        /// Processing should run: a consumer has the device open, it closed
        /// it within the idle grace period, or whether it is open cannot be
        /// observed.
        public var processingWanted: Bool
        /// The processing engines are running or being started.
        public var engineRunning: Bool
        /// The running engines capture another input or run another mode than
        /// the current one, or asked to be restarted.
        public var engineIsStale: Bool
        /// Publication is in progress: the meter is being brought up on the
        /// input before the device is published.
        public var publishing: Bool
        /// A teardown of the publication is owed.
        public var pendingTeardown: Bool
        public var decision: ProcessedMicrophoneSourceDecision
        /// The quiet window holds HAL resource changes.
        public var holding: Bool
        /// Starts are held: the window holds, or a release admits stops
        /// only. The engines may be stopped and an owed teardown completed,
        /// but nothing is started, restarted or published.
        public var startsHeld: Bool
        /// Retries of a start whose publisher output read no usable format
        /// (`PublisherOutputRetry`). `spaced` holds starts as `startsHeld`
        /// does. `exhausted` issues nothing at all, not even a stop: what the
        /// last start left, which renders nothing, stays until the user
        /// retries or the output changes.
        public var outputRetry: PublisherOutputRetry.Gate

        public init(
            enabled: Bool,
            published: Bool,
            inUse: Bool,
            processingWanted: Bool,
            engineRunning: Bool,
            engineIsStale: Bool,
            publishing: Bool,
            pendingTeardown: Bool,
            decision: ProcessedMicrophoneSourceDecision,
            holding: Bool,
            startsHeld: Bool,
            outputRetry: PublisherOutputRetry.Gate
        ) {
            self.outputRetry = outputRetry
            self.enabled = enabled
            self.published = published
            self.inUse = inUse
            self.processingWanted = processingWanted
            self.engineRunning = engineRunning
            self.engineIsStale = engineIsStale
            self.publishing = publishing
            self.pendingTeardown = pendingTeardown
            self.decision = decision
            self.holding = holding
            self.startsHeld = startsHeld
        }
    }

    public enum Action: Equatable {
        case none
        /// Bring the meter up on the input, then publish.
        case startPipeline
        /// Hand the input from the meter to the processing engines.
        case startProcessing
        /// Stop the engines and bring them up again on the current input and
        /// mode, validating the publication on the way.
        case restartProcessing
        /// Stop the engines only. The publication stays.
        case stopProcessingKeepPublication
        /// Stop the engines and withdraw the publication.
        case completeTeardown
    }

    public static func next(_ conditions: Conditions) -> Action {
        guard !conditions.holding else {
            return .none
        }
        // The retries on an output that kept reading no usable format ended.
        // Nothing is issued until the user retries or the output changes.
        guard conditions.outputRetry != .exhausted else {
            return .none
        }
        let action = actionOutsideTheWindow(conditions)
        // A retry waiting for its spacing holds starts as a stops-only
        // release does.
        guard conditions.startsHeld || conditions.outputRetry == .spaced else {
            return action
        }
        switch action {
        case .startPipeline, .startProcessing:
            return .none
        case .restartProcessing:
            // The stop half now; the start waits for a release that admits it.
            return .stopProcessingKeepPublication
        case .none, .stopProcessingKeepPublication, .completeTeardown:
            return action
        }
    }

    private static func actionOutsideTheWindow(_ conditions: Conditions) -> Action {
        guard conditions.enabled else {
            if conditions.pendingTeardown, !conditions.inUse {
                return .completeTeardown
            }
            return conditions.engineRunning ? .stopProcessingKeepPublication : .none
        }

        guard conditions.decision == .allowed else {
            return conditions.engineRunning ? .stopProcessingKeepPublication : .none
        }

        if conditions.engineRunning {
            // Never render processed audio without the muted publication in
            // place, and never keep processing for nobody.
            guard conditions.published, conditions.processingWanted else {
                return .stopProcessingKeepPublication
            }
            return conditions.engineIsStale ? .restartProcessing : .none
        }

        if conditions.publishing {
            return .none
        }
        guard conditions.published else {
            return .startPipeline
        }
        return conditions.processingWanted ? .startProcessing : .none
    }

    /// What the app's own device picker does about Apple voice processing
    /// before it writes a default device.
    public enum DefaultPick: Equatable {
        /// Write the default.
        case write
        /// Stop Apple voice processing's engines, then write the default.
        case stopVoiceProcessingThenWrite
        /// Neither stop nor write: the pick is not taken.
        case refuse
    }

    /// What the app's own device picker does before it writes a default
    /// device.
    ///
    /// The voice-processing engine follows the default input and output by
    /// itself, so a default the picker moves onto a Bluetooth headset takes
    /// the engine's IO onto the headset while the headset reconfigures for it.
    /// Stopping the engine before the write keeps its stop out of that change.
    /// The picker knows the picked device's transport from its list, but not
    /// an aggregate's sub-devices, and a device it does not list has no
    /// transport on hand: both count as possibly Bluetooth, as does a
    /// transport this app does not classify. A known wired or virtual device
    /// is written with nothing stopped; the evaluation after the window
    /// rebuilds for it.
    ///
    /// That stop is not held by the quiet window, so it is issued only when
    /// no change can be under way. While one may be, as while a Bluetooth
    /// device is connected, since the engines are then running only because
    /// the window its arrival armed still holds them, the stop could land
    /// inside that change, and a write without it would take the engine
    /// with it. Such a pick is refused: nothing is stopped or written, and
    /// the release after the window stops the engines if the source is no
    /// longer allowed, after which the same pick is written.
    ///
    /// - Parameters:
    ///   - voiceProcessingEngaged: Apple voice processing's engines are
    ///     running or being started.
    ///   - pickedTransport: The picked device's transport as its list shows
    ///     it, nil when the list does not show the device.
    ///   - changeMayBeUnderWay: The quiet window is armed or has a change
    ///     carried, a generation has advanced that the owner has not armed
    ///     the window for, a default-device write is outstanding, or the
    ///     engines owe a restart.
    ///   - bluetoothDevicePresent: Whether a Bluetooth or Bluetooth LE audio
    ///     device is connected, nil when that could not be read.
    public static func beforeDefaultWrite(
        voiceProcessingEngaged: Bool,
        pickedTransport: AudioDeviceTransport?,
        changeMayBeUnderWay: Bool,
        bluetoothDevicePresent: Bool?
    ) -> DefaultPick {
        guard voiceProcessingEngaged, mayInvolveBluetooth(pickedTransport) else {
            return .write
        }
        guard !changeMayBeUnderWay, bluetoothDevicePresent == false else {
            return .refuse
        }
        return .stopVoiceProcessingThenWrite
    }

    private static func mayInvolveBluetooth(_ pickedTransport: AudioDeviceTransport?) -> Bool {
        guard let pickedTransport else {
            return true
        }
        switch pickedTransport {
        case .bluetooth, .bluetoothLE, .aggregate, .unknown:
            return true
        case .builtIn, .virtual, .pci, .usb, .fireWire, .hdmi, .displayPort, .airPlay, .avb, .thunderbolt,
             .continuityCapture:
            return false
        }
    }
}
