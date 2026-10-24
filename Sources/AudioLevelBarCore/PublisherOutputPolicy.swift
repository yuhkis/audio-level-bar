import Foundation

/// One output device, as the publisher's output is chosen from it.
public struct PublisherOutputCandidate: Equatable {
    public var deviceID: UInt32
    /// The transport and, for an aggregate, its active sub-devices. nil when
    /// it could not be read. An aggregate taken from the device list has nil
    /// sub-devices: only the default output's are read.
    public var info: AudioDeviceTransportInfo?
    public var hasOutputChannels: Bool

    public init(deviceID: UInt32, info: AudioDeviceTransportInfo?, hasOutputChannels: Bool) {
        self.deviceID = deviceID
        self.info = info
        self.hasOutputChannels = hasOutputChannels
    }
}

/// An output device as the device list reports it.
public struct ListedOutputDevice: Equatable {
    public var deviceID: UInt32
    /// The transport as read, or nil when it could not be read. An unread
    /// transport is not `.unknown`: `.unknown` is a transport that was read
    /// and that this app does not classify, which rules the device out, while
    /// an unread one is a read to wait out.
    public var transport: AudioDeviceTransport?
    public var hasOutputChannels: Bool

    public init(deviceID: UInt32, transport: AudioDeviceTransport?, hasOutputChannels: Bool) {
        self.deviceID = deviceID
        self.transport = transport
        self.hasOutputChannels = hasOutputChannels
    }
}

/// The output devices and the default output the publisher output is chosen
/// from, whether read uncached before the engine is built or taken from the
/// poll.
public struct PublisherOutputSurvey: Equatable {
    /// Every listed output device, or nil when the list could not be read.
    public var outputs: [PublisherOutputCandidate]?
    /// The default output, or nil when there is none.
    public var defaultOutput: PublisherOutputCandidate?

    public init(outputs: [PublisherOutputCandidate]?, defaultOutput: PublisherOutputCandidate?) {
        self.outputs = outputs
        self.defaultOutput = defaultOutput
    }

    /// - Parameters:
    ///   - listed: The output device list, or nil when it could not be read.
    ///     A listed device whose transport was not read has no info, so
    ///     `PublisherOutputPolicy.choose` waits for it (`outputsNotRead`)
    ///     rather than refusing.
    ///   - defaultOutputID: The default output, 0 when there is none.
    ///   - defaultOutput: The default output's transport with its active
    ///     sub-devices, or nil when it could not be read.
    public init(
        listed: [ListedOutputDevice]?,
        defaultOutputID: UInt32,
        defaultOutput: AudioDeviceTransportInfo?
    ) {
        outputs = listed?.map { device in
            PublisherOutputCandidate(
                deviceID: device.deviceID,
                info: device.deviceID == defaultOutputID
                    ? defaultOutput
                    : device.transport.map { AudioDeviceTransportInfo(transport: $0) },
                hasOutputChannels: device.hasOutputChannels
            )
        }
        self.defaultOutput = defaultOutputID == 0
            ? nil
            : PublisherOutputCandidate(
                deviceID: defaultOutputID,
                info: defaultOutput,
                // The default output has output channels even when the list
                // that would say so could not be read or does not show it.
                hasOutputChannels: listed?
                    .first(where: { $0.deviceID == defaultOutputID })?
                    .hasOutputChannels ?? true
            )
    }
}

public enum PublisherOutputRefusal: Equatable {
    /// No built-in output, and no other output, the default included, whose
    /// transports were all read and none of them is Bluetooth.
    case noNonBluetoothOutput
    /// The device list, or a transport that could have allowed an output,
    /// could not be read. A change to wait out, not a refusal to show.
    case outputsNotRead
}

public enum PublisherOutputChoice: Equatable {
    /// Bind the publisher to this device.
    case device(UInt32, AudioDeviceTransportInfo)
    case refused(PublisherOutputRefusal)
}

/// Chooses the output device the processed microphone's publisher is
/// bound to, and tells when a running one has to be rebuilt.
///
/// The publisher's audio is captured by a muted tap on this process's own
/// audio, not on a device, so the device it renders to is never heard. What
/// matters is that the publisher never renders through a Bluetooth device and
/// never follows the default output: an `AVAudioEngine` left on the default
/// output, or bound to another device, moves itself onto an arriving headset
/// and restarts its IO there while the headset is still reconfiguring. So the
/// publisher is an IOProc on one device, and that device is:
/// - a built-in output when there is one: the default output if it is
///   built-in, otherwise the built-in output with the lowest ID. It never
///   becomes Bluetooth and never goes away, so the choice does not move when
///   the default output does;
/// - otherwise the default output, if it has output channels and every
///   transport involved, an aggregate's full composition included, was
///   read and is known and none of them is Bluetooth;
/// - otherwise nothing, and the processed microphone refuses to start, as it
///   does for a Bluetooth microphone.
public enum PublisherOutputPolicy {
    public static func choose(_ survey: PublisherOutputSurvey) -> PublisherOutputChoice {
        let builtIns = (survey.outputs ?? []).filter(isBuiltIn)
        if
            let defaultOutput = survey.defaultOutput,
            let builtIn = builtIns.first(where: { $0.deviceID == defaultOutput.deviceID }),
            let info = builtIn.info
        {
            return .device(builtIn.deviceID, info)
        }
        if
            let builtIn = builtIns.min(by: { $0.deviceID < $1.deviceID }),
            let info = builtIn.info
        {
            return .device(builtIn.deviceID, info)
        }
        if
            let defaultOutput = survey.defaultOutput,
            isEligible(defaultOutput),
            let info = defaultOutput.info
        {
            return .device(defaultOutput.deviceID, info)
        }

        // A read that failed might have shown an output that could be used.
        let unread = survey.outputs == nil
            || survey.defaultOutput?.info == nil && survey.defaultOutput != nil
            || (survey.outputs ?? []).contains { $0.hasOutputChannels && $0.info == nil }
        return .refused(unread ? .outputsNotRead : .noNonBluetoothOutput)
    }

    /// Whether the publisher may be bound to this device: it has
    /// output channels, and its transport, an aggregate's active sub-devices
    /// and its full composition were read and resolved, are known, and none
    /// of them is Bluetooth. An unknown transport or an aggregate that cannot
    /// be looked into could wrap a Bluetooth link, and an aggregate whose
    /// active sub-devices were not read is what `boundOutputIsStale` rebuilds
    /// from, so it is never chosen.
    public static func isEligible(_ candidate: PublisherOutputCandidate) -> Bool {
        guard candidate.hasOutputChannels, let info = candidate.info, !activeSubDevicesUnread(info) else {
            return false
        }
        return InputOpenPolicy.decide(deviceID: candidate.deviceID, info: info)
            == .open(.knownTransport)
    }

    /// Whether a running publisher bound to `deviceID` has to be
    /// rebuilt, from what the poll shows now.
    ///
    /// True only on evidence: the device is no longer listed, it now
    /// involves Bluetooth (an aggregate member that is not active, or not
    /// resolved, counts), or it is an aggregate whose active sub-devices the
    /// poll no longer reads, which is what happens once it stops being the
    /// default output. The default output merely moving to another device is
    /// not a reason, because the muted tap captures the publisher wherever it
    /// renders. Without a device list, or with the device's transport unread,
    /// there is no verdict. A device `choose` picks from a survey is never
    /// stale in that same survey, so a rebuild cannot keep choosing the device
    /// it rebuilt from.
    public static func boundOutputIsStale(deviceID: UInt32, survey: PublisherOutputSurvey) -> Bool {
        guard let outputs = survey.outputs else {
            return false
        }
        let candidate: PublisherOutputCandidate
        if let defaultOutput = survey.defaultOutput, defaultOutput.deviceID == deviceID {
            candidate = defaultOutput
        } else if let listed = outputs.first(where: { $0.deviceID == deviceID }) {
            candidate = listed
        } else {
            return true
        }
        guard let info = candidate.info else {
            return false
        }
        if InputOpenPolicy.involvesBluetooth(info) {
            return true
        }
        return activeSubDevicesUnread(info)
    }

    /// Whether the device is an aggregate whose active sub-devices were not
    /// read.
    private static func activeSubDevicesUnread(_ info: AudioDeviceTransportInfo) -> Bool {
        info.transport == .aggregate && info.activeSubDeviceTransports == nil
    }

    /// Whether a `.noNonBluetoothOutput` refusal from the read made
    /// immediately before the engine is built may be latched until the poll
    /// shows another default output, given what the poll itself chooses.
    ///
    /// A built-in output the poll shows never becomes Bluetooth and never
    /// goes away. When the poll's choice is one, the uncached read that found
    /// no output could only have failed to read it, as a dropped device or an
    /// unread transport does while devices reconfigure: that is a change to
    /// wait out, not a refusal to show for the rest of the call.
    public static func uncachedRefusalMayLatch(pollChoice: PublisherOutputChoice) -> Bool {
        if case let .device(_, info) = pollChoice, info.transport == .builtIn {
            return false
        }
        return true
    }

    /// Whether the output a publisher is bound to has to be read again
    /// immediately before its IOProc is created and started. A built-in output cannot
    /// gain a Bluetooth sub-device, so it is not; any other output, such as
    /// an aggregate default output, can between the read that chose it and
    /// the start.
    public static func needsReadBeforeStart(_ bound: AudioDeviceTransportInfo) -> Bool {
        bound.transport != .builtIn
    }

    /// Whether an output read again immediately before the publisher's IOProc is created or started may
    /// still be rendered to: read, of known transports, and none of them
    /// Bluetooth, an aggregate's active sub-devices included.
    public static func isStillEligibleBeforeStart(deviceID: UInt32, current: AudioDeviceTransportInfo?) -> Bool {
        isEligible(PublisherOutputCandidate(deviceID: deviceID, info: current, hasOutputChannels: true))
    }

    private static func isBuiltIn(_ candidate: PublisherOutputCandidate) -> Bool {
        candidate.hasOutputChannels && candidate.info?.transport == .builtIn
    }
}
