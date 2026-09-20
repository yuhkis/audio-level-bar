import CoreAudio
import Foundation

extension AudioDeviceTransport {
    /// Classifies a `kAudioDevicePropertyTransportType` value.
    ///
    /// Every Bluetooth refusal depends on this mapping: a Bluetooth value that
    /// fell through to `.unknown` would be opened as an unknown transport.
    public init(transportType: UInt32) {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        // An automatically generated aggregate, such as the one a framework
        // builds around the default device, is still an aggregate: its
        // sub-devices are what decide whether it involves Bluetooth.
        case kAudioDeviceTransportTypeAggregate,
                kAudioDeviceTransportTypeAutoAggregate:
            self = .aggregate
        case kAudioDeviceTransportTypeVirtual:
            self = .virtual
        case kAudioDeviceTransportTypePCI:
            self = .pci
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeFireWire:
            self = .fireWire
        case kAudioDeviceTransportTypeBluetooth:
            self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetoothLE
        case kAudioDeviceTransportTypeHDMI:
            self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort:
            self = .displayPort
        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay
        case kAudioDeviceTransportTypeAVB:
            self = .avb
        case kAudioDeviceTransportTypeThunderbolt:
            self = .thunderbolt
        case kAudioDeviceTransportTypeContinuityCaptureWired,
                kAudioDeviceTransportTypeContinuityCaptureWireless:
            self = .continuityCapture
        default:
            self = .unknown
        }
    }
}

extension AudioDeviceTransportInfo {
    /// How many aggregates deep a full composition is followed. A member
    /// nested deeper, or an aggregate that names itself through its members,
    /// is unresolved.
    public static let maximumNestingDepth = 4

    /// Reads the transport of one device and, for an aggregate, of its active
    /// sub-devices and its full composition, through the reads the caller
    /// supplies.
    ///
    /// - nil when there is no device or its own transport could not be read,
    ///   so that a failed read is never mistaken for a transport that rules
    ///   Bluetooth out.
    /// - An active sub-device whose transport cannot be read counts as
    ///   `.unknown`. An aggregate whose active sub-device list cannot be read
    ///   has nil `activeSubDeviceTransports`.
    /// - The full composition names every sub-device, active or not. A member
    ///   that `fullSubDevicesOf` could not resolve to a device (nil), or whose
    ///   transport cannot be read, is an unresolved member (a nil element).
    ///   A nested aggregate is replaced by its own full composition, up to
    ///   `maximumNestingDepth`; one whose list cannot be read, that is nested
    ///   deeper, or that is already being read is unresolved. An aggregate
    ///   whose own list cannot be read has nil `fullSubDeviceTransports`.
    ///   `InputOpenPolicy` refuses an aggregate with either.
    /// - The sub-device lists are read only for an aggregate.
    ///
    /// - Parameters:
    ///   - activeSubDevicesOf: The active sub-devices of an aggregate, nil when
    ///     the list could not be read.
    ///   - fullSubDevicesOf: Every sub-device an aggregate names, each resolved
    ///     to its device ID or nil when it could not be, nil when the list
    ///     could not be read.
    public static func read(
        deviceID: UInt32,
        transportOf: (UInt32) -> AudioDeviceTransport?,
        activeSubDevicesOf: (UInt32) -> [UInt32]?,
        fullSubDevicesOf: (UInt32) -> [UInt32?]?
    ) -> AudioDeviceTransportInfo? {
        guard deviceID != 0, let transport = transportOf(deviceID) else {
            return nil
        }
        guard transport == .aggregate else {
            return AudioDeviceTransportInfo(transport: transport)
        }
        return AudioDeviceTransportInfo(
            transport: transport,
            activeSubDeviceTransports: activeSubDevicesOf(deviceID)?.map {
                transportOf($0) ?? .unknown
            },
            fullSubDeviceTransports: fullComposition(
                of: deviceID,
                reading: [deviceID],
                transportOf: transportOf,
                fullSubDevicesOf: fullSubDevicesOf
            )
        )
    }

    /// - Parameter reading: The aggregates being read, outermost first.
    private static func fullComposition(
        of aggregateID: UInt32,
        reading: [UInt32],
        transportOf: (UInt32) -> AudioDeviceTransport?,
        fullSubDevicesOf: (UInt32) -> [UInt32?]?
    ) -> [AudioDeviceTransport?]? {
        guard let members = fullSubDevicesOf(aggregateID) else {
            return nil
        }
        var transports: [AudioDeviceTransport?] = []
        for member in members {
            guard let member, member != 0, let transport = transportOf(member) else {
                transports.append(nil)
                continue
            }
            guard transport == .aggregate else {
                transports.append(transport)
                continue
            }
            guard
                !reading.contains(member),
                reading.count < maximumNestingDepth,
                let nested = fullComposition(
                    of: member,
                    reading: reading + [member],
                    transportOf: transportOf,
                    fullSubDevicesOf: fullSubDevicesOf
                )
            else {
                transports.append(nil)
                continue
            }
            transports.append(contentsOf: nested)
        }
        return transports
    }
}

/// The transport of every listed device, read once per device ID, and the
/// set of Bluetooth devices derived from it.
///
/// A device's transport does not change while its ID lives, so an update
/// reads only IDs it has not seen. IDs that leave the list are dropped, so a
/// reused ID is read again once it has been absent for one update. A change in
/// `bluetoothDeviceIDs` is what arms the quiet window for a Bluetooth device
/// connecting or disconnecting; a non-Bluetooth device arriving or leaving
/// leaves it unchanged.
public struct DeviceTransportCache: Equatable {
    public private(set) var transports: [UInt32: AudioDeviceTransport] = [:]

    public init() {}

    /// - Parameters:
    ///   - deviceIDs: The device list, or nil when it could not be read. A
    ///     failed list read keeps the cache as it was: an empty set would read
    ///     as every Bluetooth device disconnecting at once.
    ///   - read: Reads one device's transport, or nil on failure. A failed
    ///     read is not cached, so the next update tries that ID again.
    public mutating func update(
        listing deviceIDs: [UInt32]?,
        read: (UInt32) -> AudioDeviceTransport?
    ) {
        guard let deviceIDs else {
            return
        }
        let listed = Set(deviceIDs)
        transports = transports.filter { listed.contains($0.key) }
        for deviceID in deviceIDs where transports[deviceID] == nil {
            if let transport = read(deviceID) {
                transports[deviceID] = transport
            }
        }
    }

    public subscript(deviceID: UInt32) -> AudioDeviceTransport? {
        transports[deviceID]
    }

    /// Every cached device whose transport is Bluetooth or Bluetooth LE.
    public var bluetoothDeviceIDs: Set<UInt32> {
        Set(
            transports.compactMap { deviceID, transport in
                InputOpenPolicy.isBluetooth(transport) ? deviceID : nil
            }
        )
    }
}
