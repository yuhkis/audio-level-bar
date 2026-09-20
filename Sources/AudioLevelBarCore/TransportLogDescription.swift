import Foundation

extension AudioDeviceTransport {
    /// A short, stable name for log lines. Never a device name or UID.
    public var logName: String {
        switch self {
        case .builtIn:
            return "builtIn"
        case .aggregate:
            return "aggregate"
        case .virtual:
            return "virtual"
        case .pci:
            return "pci"
        case .usb:
            return "usb"
        case .fireWire:
            return "fireWire"
        case .bluetooth:
            return "bluetooth"
        case .bluetoothLE:
            return "bluetoothLE"
        case .hdmi:
            return "hdmi"
        case .displayPort:
            return "displayPort"
        case .airPlay:
            return "airPlay"
        case .avb:
            return "avb"
        case .thunderbolt:
            return "thunderbolt"
        case .continuityCapture:
            return "continuityCapture"
        case .unknown:
            return "unknown"
        }
    }
}

extension AudioDeviceTransportInfo {
    /// The transport class for a log line. A direct device is its transport,
    /// such as `usb`. An aggregate lists its active sub-devices, then its full
    /// composition after `|`: `aggregate[builtIn|builtIn,bluetooth]` for a
    /// headset that is a member but not active, and `?` for a member that
    /// could not be resolved, as in `aggregate[builtIn|builtIn,?]`. A list
    /// that could not be read is `unread`: `aggregate[unread|unread]`.
    public var logDescription: String {
        let showsFull = transport == .aggregate || fullSubDeviceTransports != nil
        guard showsFull || activeSubDeviceTransports != nil else {
            return transport.logName
        }
        let active = activeSubDeviceTransports.map { $0.map(\.logName).joined(separator: ",") } ?? "unread"
        guard showsFull else {
            return "\(transport.logName)[\(active)]"
        }
        let full = fullSubDeviceTransports.map { members in
            members.map { $0?.logName ?? "?" }.joined(separator: ",")
        } ?? "unread"
        return "\(transport.logName)[\(active)|\(full)]"
    }

    /// `unread` when the transport could not be read at all.
    public static func logDescription(_ info: AudioDeviceTransportInfo?) -> String {
        info?.logDescription ?? "unread"
    }
}
