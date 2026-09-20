import Foundation

/// Whether running processed-microphone engines have to be rebuilt, from
/// what the poll shows now.
///
/// They are stale when they asked to be rebuilt, run another processing mode
/// or capture another input than the current ones, run Apple voice processing
/// against another default output, or, in every processing mode, have a
/// publisher bound to an output the poll now shows gone, involving Bluetooth,
/// or an aggregate device it can no longer look into. The default output
/// merely moving does not make the publisher stale: the muted tap captures it
/// wherever it renders.
public enum ProcessedMicrophoneEngineStaleness {
    /// - Parameters:
    ///   - running: Whether the engines are running.
    ///   - needsRestart: Whether they asked to be rebuilt.
    ///   - modeChanged: Whether the processing mode they run differs from the
    ///     selected one.
    ///   - inputChanged: Whether the input they capture differs from the
    ///     default input.
    ///   - runsVoiceProcessing: Whether they run Apple voice processing.
    ///   - outputChanged: Whether the default output they were started for
    ///     differs from the current one. Only Apple voice processing, which
    ///     opens the default output itself, is rebuilt for it.
    ///   - boundPublisherOutputID: The output the publisher is bound to, or
    ///     nil when none is.
    ///   - survey: The output devices and the default output as the poll
    ///     shows them.
    public static func isStale(
        running: Bool,
        needsRestart: Bool,
        modeChanged: Bool,
        inputChanged: Bool,
        runsVoiceProcessing: Bool,
        outputChanged: Bool,
        boundPublisherOutputID: UInt32?,
        survey: PublisherOutputSurvey
    ) -> Bool {
        guard running else {
            return false
        }
        let publisherOutputIsStale = boundPublisherOutputID.map {
            PublisherOutputPolicy.boundOutputIsStale(deviceID: $0, survey: survey)
        } ?? false
        return needsRestart
            || modeChanged
            || inputChanged
            || (runsVoiceProcessing && outputChanged)
            || publisherOutputIsStale
    }
}
