import Foundation

/// The transport of one audio device and, for an aggregate, the transports of
/// its sub-devices: those active in it, and its full composition.
public struct AudioDeviceTransportInfo: Equatable {
    public var transport: AudioDeviceTransport
    /// The transports of the active sub-devices, in the order Core Audio lists
    /// them. nil when the device is not an aggregate or the list could not be
    /// read.
    public var activeSubDeviceTransports: [AudioDeviceTransport]?
    /// The aggregate's full composition: every sub-device it names, active or
    /// not, in the order Core Audio lists them, with each nested aggregate
    /// replaced by its own full composition. A nil element is a member that
    /// could not be resolved: a device absent from the system, such as a
    /// headset that is not connected, a member whose transport or own
    /// composition could not be read, or one nested too deeply. nil when the
    /// device is not an aggregate or its list could not be read.
    public var fullSubDeviceTransports: [AudioDeviceTransport?]?

    public init(
        transport: AudioDeviceTransport,
        activeSubDeviceTransports: [AudioDeviceTransport]? = nil,
        fullSubDeviceTransports: [AudioDeviceTransport?]? = nil
    ) {
        self.transport = transport
        self.activeSubDeviceTransports = activeSubDeviceTransports
        self.fullSubDeviceTransports = fullSubDeviceTransports
    }

    /// Whether a transport read shows Bluetooth: the device itself, an active
    /// sub-device, or any member of its full composition.
    public var showsBluetooth: Bool {
        InputOpenPolicy.isBluetooth(transport)
            || (activeSubDeviceTransports ?? []).contains(where: InputOpenPolicy.isBluetooth)
            || (fullSubDeviceTransports ?? []).contains { $0.map(InputOpenPolicy.isBluetooth) ?? false }
    }

    /// Whether an active sub-device is Bluetooth, or the device itself is.
    /// The full composition does not count: a member that is not active
    /// carries no IO.
    public var showsActiveBluetooth: Bool {
        InputOpenPolicy.isBluetooth(transport)
            || (activeSubDeviceTransports ?? []).contains(where: InputOpenPolicy.isBluetooth)
    }

    /// Whether the device is an aggregate whose full composition could not be
    /// read in full: the list itself, or one of its members.
    public var hasUnresolvedMember: Bool {
        guard transport == .aggregate else {
            return false
        }
        guard let fullSubDeviceTransports else {
            return true
        }
        return fullSubDeviceTransports.contains(nil)
    }
}

/// Why an input device may be opened, and whether that is worth a log line.
public enum InputOpenNote: Equatable {
    /// Every transport involved was read, and none of them is Bluetooth.
    case knownTransport
    /// The device, or a sub-device of an aggregate, reports a transport this
    /// app does not classify. It could wrap a Bluetooth link.
    case unknownTransport

    /// Every note except `.knownTransport` records a decision made without
    /// being able to rule Bluetooth out, so the caller logs it.
    public var shouldBeLogged: Bool {
        self != .knownTransport
    }
}

/// Why an input device must not be opened.
public enum InputOpenRefusal: Equatable {
    /// There is no default input.
    case noDevice
    /// The transport has not been read, so Bluetooth cannot be ruled out.
    case transportNotRead
    /// The device is a Bluetooth or Bluetooth LE microphone.
    case bluetooth
    /// The device is an aggregate with a Bluetooth or Bluetooth LE member,
    /// active in it or not. A member that is not active becomes active when
    /// its headset connects, and that recomposition runs inside the headset's
    /// own configuration change, under whatever the app has running on the
    /// aggregate.
    case aggregateWithBluetoothMember
    /// The device is an aggregate whose full composition could not be read in
    /// full: its member list, or a member that is absent from the system or
    /// whose transport could not be read. Such a member could be a headset
    /// that is not connected, so it counts as Bluetooth. An aggregate whose
    /// composition names no member at all, such as one built around a process
    /// tap alone, counts the same: what feeds it cannot be checked.
    case aggregateWithUnresolvedMember
}

public enum InputOpenDecision: Equatable {
    case open(InputOpenNote)
    case refuse(InputOpenRefusal)
}

/// Decides whether the app may open an input device by itself.
///
/// Opening a Bluetooth headset's microphone switches the headset into call
/// mode, and playback stays degraded for as long as the input is open. The
/// microphone's own reconfiguration is also where a meter that follows the
/// default input can leave coreaudiod waiting for every process. So the app
/// never opens a Bluetooth microphone on its own, directly or through an
/// aggregate, nor an aggregate that names one among its members, connected
/// or not, nor one whose members cannot all be resolved.
///
/// The decision takes only the device. Whether a panel is showing or the
/// processed microphone is on has no say in it, by construction.
public enum InputOpenPolicy {
    public static func decide(
        deviceID: UInt32,
        info: AudioDeviceTransportInfo?
    ) -> InputOpenDecision {
        guard deviceID != 0 else {
            return .refuse(.noDevice)
        }
        guard let info else {
            return .refuse(.transportNotRead)
        }
        if isBluetooth(info.transport) {
            return .refuse(.bluetooth)
        }
        // Checked whatever the device's own transport says: a sub-device list
        // that names Bluetooth is reason enough not to open it.
        if info.showsBluetooth {
            return .refuse(.aggregateWithBluetoothMember)
        }

        guard info.transport == .aggregate else {
            return .open(info.transport == .unknown ? .unknownTransport : .knownTransport)
        }
        // Fail closed: a member that cannot be resolved could be a headset
        // that is not connected.
        guard !info.hasUnresolvedMember, let members = info.fullSubDeviceTransports?.compactMap({ $0 }) else {
            return .refuse(.aggregateWithUnresolvedMember)
        }
        // A reader replaces each nested aggregate with its own members; one
        // left in the list was not looked into.
        if members.contains(.aggregate) {
            return .refuse(.aggregateWithUnresolvedMember)
        }
        // A composition that names no member says nothing about what feeds
        // the aggregate, and its active list alone cannot rule out a member
        // that is not active.
        if members.isEmpty {
            return .refuse(.aggregateWithUnresolvedMember)
        }
        if members.contains(.unknown) || (info.activeSubDeviceTransports ?? []).contains(.unknown) {
            return .open(.unknownTransport)
        }
        return .open(.knownTransport)
    }

    /// Whether the device may involve Bluetooth: it is Bluetooth, or an
    /// aggregate with a Bluetooth member, active or not, or with a member
    /// that could not be resolved, which counts as Bluetooth. False when the
    /// transport has not been read; callers treat that on its own.
    public static func involvesBluetooth(_ info: AudioDeviceTransportInfo?) -> Bool {
        guard let info else {
            return false
        }
        return info.showsBluetooth || info.hasUnresolvedMember
    }

    public static func isBluetooth(_ transport: AudioDeviceTransport) -> Bool {
        transport == .bluetooth || transport == .bluetoothLE
    }
}
