import AudioLevelBarCore
import Combine
import Foundation

struct AudioLevelReading: Equatable {
    var rmsDecibels: Float
    var peakDecibels: Float

    static let silent = AudioLevelReading(
        rmsDecibels: MeterScale.calculationFloorDecibels,
        peakDecibels: MeterScale.calculationFloorDecibels
    )
}

/// Meter values that change far faster than the rest of the app state.
///
/// The menu bar reads these on its own 0.5 s timer instead of observing them,
/// so the stored values are always current. Change notifications are the
/// expensive part: one notification relayouts every SwiftUI view that observes
/// this object, and the tap emits at 20 Hz. Keeping the levels out of
/// `AudioState` limits that work to the two meters, `setMetersVisible(_:)`
/// suppresses it entirely while no panel is on screen, and repeated identical
/// readings — silence, most of all — never notify at all.
final class AudioLevels: ObservableObject {
    private(set) var microphone = AudioLevelReading.silent
    private(set) var systemOutput = AudioLevelReading.silent
    private(set) var metersAreVisible = false

    func setMetersVisible(_ visible: Bool) {
        guard metersAreVisible != visible else {
            return
        }
        metersAreVisible = visible
        guard visible else {
            return
        }
        // The stored readings moved on while nothing was observing them.
        // Redraw once so a panel never opens on a stale meter.
        objectWillChange.send()
    }

    func setMicrophone(rmsDecibels: Float, peakDecibels: Float) {
        apply(
            AudioLevelReading(
                rmsDecibels: rmsDecibels,
                peakDecibels: peakDecibels
            ),
            to: \.microphone
        )
    }

    func setSystemOutput(rmsDecibels: Float, peakDecibels: Float) {
        apply(
            AudioLevelReading(
                rmsDecibels: rmsDecibels,
                peakDecibels: peakDecibels
            ),
            to: \.systemOutput
        )
    }

    func resetMicrophone() {
        apply(.silent, to: \.microphone)
    }

    func resetSystemOutput() {
        apply(.silent, to: \.systemOutput)
    }

    private func apply(
        _ reading: AudioLevelReading,
        to keyPath: ReferenceWritableKeyPath<AudioLevels, AudioLevelReading>
    ) {
        guard self[keyPath: keyPath] != reading else {
            return
        }
        if metersAreVisible {
            objectWillChange.send()
        }
        self[keyPath: keyPath] = reading
    }
}
