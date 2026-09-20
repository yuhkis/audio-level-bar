import Foundation

/// The step an IOProc start takes once it has created its IOProc and added
/// its listeners, immediately before `AudioDeviceStart`.
///
/// The device's transport is read, uncached, before anything is created, but
/// an aggregate's sub-devices can change between that read and the moment its
/// listeners are in place, and a listener reports only changes made after it
/// was added. So the start reads the device again once the listeners are
/// added: anything that changes after this read reaches a listener, and
/// anything that changed before it is in the read.
public enum InputOpenSequence {
    public enum AfterListeners: Equatable {
        /// Start the IO. The note is the one the second read gives.
        case start(InputOpenNote)
        /// The second read refuses the device and no quiet window armed since
        /// the start was issued: release what the start created, which never
        /// started, then report the refusal.
        case refuseAndRelease(InputOpenRefusal)
        /// A quiet window armed since the start was issued. Nothing is started
        /// or released inside it; the owner's next start or stop after the
        /// window releases what the start created. `refusal` is set when the
        /// second read refused the device too, so that the refusal is logged
        /// before the interruption.
        case interrupt(refusal: InputOpenRefusal?)
    }

    /// - Parameters:
    ///   - deviceID: The device the start opened.
    ///   - secondInfo: The transport read again after the listeners were
    ///     added, nil when it could not be read.
    ///   - generationCurrent: Whether the quiet window's generation is still
    ///     the one the start was issued in.
    public static func afterListeners(
        deviceID: UInt32,
        secondInfo: AudioDeviceTransportInfo?,
        generationCurrent: Bool
    ) -> AfterListeners {
        let decision = InputOpenPolicy.decide(deviceID: deviceID, info: secondInfo)
        guard generationCurrent else {
            if case let .refuse(refusal) = decision {
                return .interrupt(refusal: refusal)
            }
            return .interrupt(refusal: nil)
        }
        switch decision {
        case let .open(note):
            return .start(note)
        case let .refuse(refusal):
            return .refuseAndRelease(refusal)
        }
    }

    /// Whether the start adds the sub-device list listeners only after the
    /// second read: that read shows an aggregate, and the first, from which
    /// the listeners were chosen, did not.
    public static func addsSubDeviceListenersAfterSecondRead(
        first: AudioDeviceTransportInfo?,
        second: AudioDeviceTransportInfo?
    ) -> Bool {
        !AggregateMembershipPolicy.watchesSubDeviceLists(first)
            && AggregateMembershipPolicy.watchesSubDeviceLists(second)
    }
}
