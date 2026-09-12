/// Decides when the always-on microphone meter must not hold the input open.
///
/// A Bluetooth headset cannot carry high-quality playback and a microphone at
/// the same time: opening its microphone drops the whole link into call mode,
/// and playback stays degraded for as long as anything holds the input. Other
/// apps open a microphone when the user asks for a call or a recording; a
/// meter that opens it just by existing degrades playback permanently and
/// invisibly. So a Bluetooth default input is metered only while someone is
/// actually looking — a panel is showing — unless the user opts into
/// always-on monitoring and accepts the cost.
public enum BluetoothMicrophonePolicy {
    /// - Parameter transport: nil while the transport has not been read yet.
    ///   Holding off costs one poll tick for every device; starting blind
    ///   would open a Bluetooth headset just to find out it should not have.
    public static func shouldPauseMonitoring(
        transport: AudioDeviceTransport?,
        alwaysMonitorBluetooth: Bool,
        metersAreVisible: Bool
    ) -> Bool {
        guard let transport else {
            return true
        }
        guard transport == .bluetooth || transport == .bluetoothLE else {
            return false
        }
        return !alwaysMonitorBluetooth && !metersAreVisible
    }
}
