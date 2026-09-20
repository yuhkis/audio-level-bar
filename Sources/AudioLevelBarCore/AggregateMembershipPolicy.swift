import Foundation

/// What to do with an open IOProc when the sub-devices of its aggregate
/// device change.
public enum AggregateMembershipDecision: Equatable {
    /// Nothing beyond the invalidation, which has already stopped the
    /// IOProc's reports. The owner's evaluation after the quiet window
    /// decides a restart or a stop.
    case leaveToOwner
    /// A Bluetooth or Bluetooth LE device is now active in the aggregate.
    /// Stop and destroy the IOProc at once, inside any quiet window.
    case stopNow
}

/// Decides what happens when an aggregate device the app has open gains or
/// loses sub-devices.
///
/// The app never opens an aggregate whose full composition names a Bluetooth
/// member, active or not, or a member it cannot resolve (`InputOpenPolicy`).
/// So a headset can join an open aggregate only when its composition is
/// edited while the aggregate is open, and while its ID stays the same. The
/// app watches both lists of an aggregate it has open:
///
/// - A change of the full composition only invalidates. A member that is not
///   active carries no IO, so waiting for the quiet window is outside any
///   Bluetooth configuration change, and the owner's evaluation after the
///   window refuses the aggregate.
/// - A change of the active sub-devices is read again at once. Only a read
///   that positively shows an active Bluetooth device stops the IOProc
///   immediately, inside any quiet window: leaving it running would carry a
///   running app context on the headset through its own configuration change
///   for the window's length. This stop is a last resort, which the path
///   above leaves rare, and it is not exempt from the hardware gate: the gate
///   judges it against the Bluetooth configuration-change requests like any
///   other stop. Nothing is ever started on this path. A device whose
///   transport or sub-devices cannot be read is left to the owner, like any
///   other invalidation.
public enum AggregateMembershipPolicy {
    /// Whether to listen for changes of the device's active sub-devices and
    /// of its full composition, as read when it was opened. Only an aggregate
    /// has them.
    public static func watchesSubDeviceLists(_ info: AudioDeviceTransportInfo?) -> Bool {
        info?.transport == .aggregate
    }

    /// The decision for a transport read again, uncached, after the active
    /// sub-device list of the open aggregate changed. A Bluetooth member that
    /// is only in the full composition is left to the owner.
    public static func afterActiveSubDevicesChanged(
        _ info: AudioDeviceTransportInfo?
    ) -> AggregateMembershipDecision {
        info?.showsActiveBluetooth == true ? .stopNow : .leaveToOwner
    }
}
