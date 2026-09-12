import AudioLevelBarCore
import Combine
import Foundation

final class MeterColorSettings: ObservableObject {
    private static let legacyGreenThresholdKey = "meterColorGreenThreshold"
    private static let legacyRedThresholdKey = "meterColorRedThreshold"

    @Published private(set) var systemOutputThresholds: MeterColorThresholds
    @Published private(set) var microphoneThresholds: MeterColorThresholds

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let legacyGreen = Self.storedValue(
            forKey: Self.legacyGreenThresholdKey,
            in: defaults
        )
        let legacyRed = Self.storedValue(
            forKey: Self.legacyRedThresholdKey,
            in: defaults
        )

        systemOutputThresholds = Self.loadThresholds(
            for: .systemOutput,
            legacyGreen: legacyGreen,
            legacyRed: legacyRed,
            in: defaults
        )
        microphoneThresholds = Self.loadThresholds(
            for: .microphone,
            legacyGreen: legacyGreen,
            legacyRed: legacyRed,
            in: defaults
        )

        defaults.removeObject(forKey: Self.legacyGreenThresholdKey)
        defaults.removeObject(forKey: Self.legacyRedThresholdKey)
        persist(.systemOutput)
        persist(.microphone)
    }

    var minimumGap: Double {
        Double(MeterColorScale.minimumThresholdGap)
    }

    func thresholds(for channel: MeterColorChannel) -> MeterColorThresholds {
        switch channel {
        case .systemOutput:
            return systemOutputThresholds
        case .microphone:
            return microphoneThresholds
        }
    }

    func setGreenThreshold(_ value: Double, for channel: MeterColorChannel) {
        update(channel) { $0.settingGreenThreshold(Float(value)) }
    }

    func setRedThreshold(_ value: Double, for channel: MeterColorChannel) {
        update(channel) { $0.settingRedThreshold(Float(value)) }
    }

    func reset(_ channel: MeterColorChannel) {
        update(channel) { _ in MeterColorScale.defaultThresholds(for: channel) }
    }

    func band(for level: Float?, in channel: MeterColorChannel) -> MeterColorBand {
        guard let level else {
            return .neutral
        }
        return thresholds(for: channel).band(for: level)
    }

    private func update(
        _ channel: MeterColorChannel,
        transform: (MeterColorThresholds) -> MeterColorThresholds
    ) {
        let updated = transform(thresholds(for: channel))
        guard updated != thresholds(for: channel) else {
            return
        }

        switch channel {
        case .systemOutput:
            systemOutputThresholds = updated
        case .microphone:
            microphoneThresholds = updated
        }
        persist(channel)
    }

    private func persist(_ channel: MeterColorChannel) {
        let keys = Self.keys(for: channel)
        let thresholds = thresholds(for: channel)
        defaults.set(Double(thresholds.greenThreshold), forKey: keys.green)
        defaults.set(Double(thresholds.redThreshold), forKey: keys.red)
    }

    private static func loadThresholds(
        for channel: MeterColorChannel,
        legacyGreen: Double?,
        legacyRed: Double?,
        in defaults: UserDefaults
    ) -> MeterColorThresholds {
        let keys = keys(for: channel)
        let channelDefault = MeterColorScale.defaultThresholds(for: channel)
        let storedGreen = storedValue(forKey: keys.green, in: defaults)
        let storedRed = storedValue(forKey: keys.red, in: defaults)

        guard storedGreen != nil || storedRed != nil else {
            return MeterColorThresholdMigration.resolvedThresholds(
                legacyGreen: legacyGreen,
                legacyRed: legacyRed,
                channelDefault: channelDefault
            )
        }

        return MeterColorThresholds(
            greenThreshold: storedGreen.map { Float($0) } ?? channelDefault.greenThreshold,
            redThreshold: storedRed.map { Float($0) } ?? channelDefault.redThreshold
        )
    }

    private static func keys(
        for channel: MeterColorChannel
    ) -> (green: String, red: String) {
        switch channel {
        case .systemOutput:
            return (
                green: "meterColorSystemOutputGreenThreshold",
                red: "meterColorSystemOutputRedThreshold"
            )
        case .microphone:
            return (
                green: "meterColorMicrophoneGreenThreshold",
                red: "meterColorMicrophoneRedThreshold"
            )
        }
    }

    private static func storedValue(
        forKey key: String,
        in defaults: UserDefaults
    ) -> Double? {
        defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
    }
}
