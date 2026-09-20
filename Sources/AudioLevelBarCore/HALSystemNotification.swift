import Foundation

/// A property notification on the HAL system object, and what the owner does
/// with it.
///
/// The poll notices a default-device change a quarter of a second or more
/// after it happens. A listener on the system object hears of it sooner, so
/// the quiet window can hold, and a start or stop already on its way can stop
/// at its next check, before the poll comes back. The listener makes no HAL
/// read and no lifecycle call; the poll stays the source of device IDs.
public enum HALSystemNotification: Equatable, CaseIterable {
    /// `kAudioHardwarePropertyDevices`.
    case devices
    /// `kAudioHardwarePropertyDefaultInputDevice`.
    case defaultInput
    /// `kAudioHardwarePropertyDefaultOutputDevice`.
    case defaultOutput
    /// `kAudioHardwarePropertyDefaultSystemOutputDevice`.
    case defaultSystemOutput
    /// `kAudioHardwarePropertyServiceRestarted`.
    case serviceRestarted

    public init?(selector: UInt32) {
        guard let notification = Self.allCases.first(where: { $0.selector == selector }) else {
            return nil
        }
        self = notification
    }

    /// The property selector the listener is registered for.
    public var selector: UInt32 {
        switch self {
        case .devices:
            return Self.fourCharacterCode("dev#")
        case .defaultInput:
            return Self.fourCharacterCode("dIn ")
        case .defaultOutput:
            return Self.fourCharacterCode("dOut")
        case .defaultSystemOutput:
            return Self.fourCharacterCode("sOut")
        case .serviceRestarted:
            return Self.fourCharacterCode("srst")
        }
    }

    /// Whether the listener advances the quiet window's generation at once,
    /// on its own queue, before the main thread hears of it.
    public var advancesHoldGenerationAtOnce: Bool {
        quietWindowReason != nil
    }

    /// The reason the owner arms the quiet window with, or nil when this
    /// notification does not arm it.
    ///
    /// The device list changes whenever any process creates or destroys an
    /// aggregate device, this app's own system playback meter and published
    /// microphone included, and only a change in the set of Bluetooth
    /// devices among it arms the window. Arming on the list itself would
    /// interrupt the app's own starts, so it only asks for a poll.
    public var quietWindowReason: String? {
        switch self {
        case .devices:
            return nil
        case .defaultInput, .defaultOutput, .defaultSystemOutput:
            return "hal-notification"
        case .serviceRestarted:
            return "service-restarted"
        }
    }

    /// Whether the owner polls at once rather than waiting for the timer.
    public var requestsPoll: Bool {
        self == .devices
    }

    /// Whether every HAL object this process held, and every ID it cached,
    /// is gone or may name something else now. The owner drops them without
    /// a HAL call and rebuilds after the quiet window.
    public var resetsHALState: Bool {
        self == .serviceRestarted
    }

    private static func fourCharacterCode(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
