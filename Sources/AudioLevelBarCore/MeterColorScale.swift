public enum MeterColorBand: Equatable {
    case neutral
    case green
    case red
}

/// Meters whose color thresholds are configured independently, because the
/// same normalized value means a different thing on each one.
public enum MeterColorChannel: String, CaseIterable {
    case systemOutput
    case microphone
}

public enum MeterColorScale {
    public static let minimumThresholdGap: Float = 0.05

    public static func band(
        for level: Float,
        greenThreshold: Float,
        redThreshold: Float
    ) -> MeterColorBand {
        let clampedLevel = min(max(level, 0), 1)
        let clampedGreen = min(max(greenThreshold, 0), 1)
        let clampedRed = min(max(redThreshold, clampedGreen), 1)

        if clampedLevel >= clampedRed {
            return .red
        }
        if clampedLevel >= clampedGreen {
            return .green
        }
        return .neutral
    }

    public static func defaultThresholds(
        for channel: MeterColorChannel
    ) -> MeterColorThresholds {
        switch channel {
        case .systemOutput:
            return .systemOutputDefault
        case .microphone:
            return .microphoneDefault
        }
    }
}

/// A validated green/red pair on the 0...1 display scale, which maps to
/// −60...0 dBFS for live signals and to 0...100% for a volume setting.
public struct MeterColorThresholds: Equatable {
    public let greenThreshold: Float
    public let redThreshold: Float

    public init(greenThreshold: Float, redThreshold: Float) {
        let clampedRed = min(
            max(redThreshold, MeterColorScale.minimumThresholdGap),
            1
        )
        self.redThreshold = clampedRed
        self.greenThreshold = min(
            max(greenThreshold, 0),
            clampedRed - MeterColorScale.minimumThresholdGap
        )
    }

    /// Speech stays green from −30 dBFS, which keeps a usable margin over room
    /// noise for speech recognition, and turns red at −6 dBFS, where short-term
    /// RMS is hot enough that peaks are close to clipping.
    public static let microphoneDefault = MeterColorThresholds(
        greenThreshold: 0.5,
        redThreshold: 0.9
    )

    /// The speaker meter is a monitor, not a target: green from −45 dBFS (or a
    /// 25% volume setting) means audio is really flowing, and red at −6 dBFS
    /// (or a 90% volume setting) flags a signal that is unusually hot.
    public static let systemOutputDefault = MeterColorThresholds(
        greenThreshold: 0.25,
        redThreshold: 0.9
    )

    public func band(for level: Float) -> MeterColorBand {
        MeterColorScale.band(
            for: level,
            greenThreshold: greenThreshold,
            redThreshold: redThreshold
        )
    }

    public func settingGreenThreshold(_ value: Float) -> MeterColorThresholds {
        MeterColorThresholds(greenThreshold: value, redThreshold: redThreshold)
    }

    public func settingRedThreshold(_ value: Float) -> MeterColorThresholds {
        MeterColorThresholds(
            greenThreshold: greenThreshold,
            redThreshold: max(value, greenThreshold + MeterColorScale.minimumThresholdGap)
        )
    }
}

public enum MeterColorThresholdMigration {
    public static let sharedGreenThreshold: Float = 0.4
    public static let sharedRedThreshold: Float = 0.9
    private static let equalityTolerance: Float = 0.001

    /// Versions before per-channel thresholds stored one shared pair, and wrote
    /// it on first launch even when the user never touched it. A stored value
    /// that still equals the shipped shared default is therefore treated as
    /// untouched, so the new per-channel default wins; anything else is a real
    /// choice and carries over to both channels.
    public static func resolvedThresholds(
        legacyGreen: Double?,
        legacyRed: Double?,
        channelDefault: MeterColorThresholds
    ) -> MeterColorThresholds {
        MeterColorThresholds(
            greenThreshold: customizedValue(
                legacyGreen,
                sharedDefault: sharedGreenThreshold
            ) ?? channelDefault.greenThreshold,
            redThreshold: customizedValue(
                legacyRed,
                sharedDefault: sharedRedThreshold
            ) ?? channelDefault.redThreshold
        )
    }

    private static func customizedValue(
        _ value: Double?,
        sharedDefault: Float
    ) -> Float? {
        guard let value, value.isFinite else {
            return nil
        }

        let candidate = Float(value)
        return abs(candidate - sharedDefault) > equalityTolerance ? candidate : nil
    }
}
