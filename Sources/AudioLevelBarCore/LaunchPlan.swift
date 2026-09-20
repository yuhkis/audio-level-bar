import Foundation

/// The order of the steps at launch.
///
/// Launch arms the quiet window before anything else. A headset that is
/// connecting as the app launches, at login for instance, is still
/// reconfiguring, and the first poll sees no change to arm on. With the
/// window armed first, the first system playback tap, the first meter start
/// and publication all wait for a release like any other change.
///
/// Launch itself destroys nothing. The cleanup of what an earlier run left
/// behind waits for the first release that admits starts; see
/// `LaunchCleanup` and `EvaluationPlan`.
public enum LaunchPlan {
    public enum Step: Equatable {
        /// Arm the quiet window, with reason `launch`.
        case armQuietWindow
        /// Listen on the HAL system object for default-device changes,
        /// device-list changes and a coreaudiod restart.
        case listenForSystemNotifications
        /// Read the device lists, the defaults and their controls.
        case readDevicesAndControls
        /// Check microphone permission, which evaluates the lifecycle.
        case checkMicrophonePermission
        /// Ask for the system playback meter, if monitoring is on.
        case requestSystemOutputMeter
        /// Start the 0.25 s poll.
        case startPolling
    }

    public static let steps: [Step] = [
        .armQuietWindow,
        .listenForSystemNotifications,
        .readDevicesAndControls,
        .checkMicrophonePermission,
        .requestSystemOutputMeter,
        .startPolling
    ]
}
