import AppKit
import AVFoundation
import AudioLevelBarCore
import Combine
import CoreAudio
import Foundation

enum MicrophonePermissionState: Equatable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted

    var description: String {
        switch self {
        case .notDetermined:
            return localized("Microphone permission has not been checked")
        case .requesting:
            return localized("Checking microphone permission")
        case .authorized:
            return localized("Monitoring the microphone level")
        case .denied:
            return localized("Microphone access is not allowed")
        case .restricted:
            return localized("Microphone access is restricted on this Mac")
        }
    }
}

enum SystemOutputMonitoringState: Equatable {
    case disabled
    case starting
    case active
    case denied
    case unavailable
    case failed(String)

    var description: String {
        switch self {
        case .disabled:
            return localized("System playback level monitoring is off")
        case .starting:
            return localized("Starting system playback level monitoring…")
        case .active:
            return localized("Monitoring the system playback level")
        case .denied:
            return localized("System audio recording is not allowed")
        case .unavailable:
            return localized("This version of macOS cannot monitor the system playback level")
        case let .failed(message):
            return message
        }
    }
}

/// What happened when the published device was asked to go away.
private enum ProcessedMicrophoneTeardownResult {
    case completed
    /// Held back because a consuming app still has the device open. Destroying
    /// it under that app wedges Core Audio for every process on the machine.
    case deferredWhileInUse
    case failed(String)
}

enum ProcessedMicrophoneState: Equatable {
    case disabled
    case starting
    case publishedIdle
    case active
    /// Switched off by the user while another app still had the published
    /// device open. Publication is held rather than torn down under that app.
    case awaitingRelease
    case microphoneDenied
    case systemAudioDenied
    case unavailable
    case failed(String)

    var description: String {
        switch self {
        case .disabled:
            return localized("The processed microphone is off")
        case .starting:
            return localized("Preparing the processed microphone")
        case .publishedIdle:
            return localized("Publishing “Audio Level Bar Microphone” (idle)")
        case .active:
            return localized("“Audio Level Bar Microphone” is in use")
        case .awaitingRelease:
            return localized("Another app is still using it. Choosing a different microphone in that app turns this off")
        case .microphoneDenied:
            return localized("Microphone access is not allowed")
        case .systemAudioDenied:
            return localized("System audio recording is not allowed")
        case .unavailable:
            return localized("This version of macOS cannot provide the processed microphone")
        case let .failed(message):
            return message
        }
    }
}

final class AudioState: ObservableObject {
    /// Apps stop and restart the published device when they change format or
    /// move between preview and call modes. Keep processing alive across those
    /// gaps instead of tearing down voice processing and rebuilding it.
    private static let processingIdleGracePeriod: TimeInterval = 3

    private static let systemOutputMonitoringKey = "systemOutputMonitoringEnabled"
    private static let processedMicrophoneKey = "processedMicrophoneEnabled"
    private static let microphoneProcessingModeKey = "microphoneProcessingMode"
    private static let legacyAppleVoiceProcessingKey = "appleVoiceProcessingEnabled"
    private static let digitalGainKey = "processedMicrophoneDigitalGainDecibels"
    private static let bluetoothAlwaysMonitorKey = "bluetoothMicrophoneAlwaysMonitored"

    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var inputDeviceID = AudioDeviceID(kAudioObjectUnknown)

    @Published private(set) var outputVolume: Float?
    @Published private(set) var outputVolumeIsAdjustable = false
    @Published private(set) var outputMuted: Bool?
    @Published private(set) var outputMuteIsAdjustable = false
    @Published private(set) var systemOutputMonitoringEnabled: Bool
    @Published private(set) var systemOutputMonitoringState: SystemOutputMonitoringState = .disabled

    @Published private(set) var inputVolume: Float?
    @Published private(set) var inputVolumeIsAdjustable = false
    @Published private(set) var inputMuted: Bool?
    @Published private(set) var inputMuteIsAdjustable = false

    @Published private(set) var microphonePermission: MicrophonePermissionState = .notDetermined
    @Published private(set) var microphoneError: String?
    /// Transport of the current default input, read with every poll. nil until
    /// the first snapshot arrives; the meter holds off until it is known, so a
    /// Bluetooth headset is never opened just to find out it should not be.
    @Published private(set) var inputTransport: AudioDeviceTransport?
    /// True while the always-on meter is deliberately not capturing because
    /// the default input is Bluetooth and no panel is showing. The menu bar
    /// shows `--` for it: an unmeasured level, not a measured silence.
    @Published private(set) var microphoneMonitoringPaused = false
    @Published private(set) var bluetoothMicrophoneAlwaysMonitored: Bool

    @Published private(set) var processedMicrophoneEnabled: Bool
    @Published private(set) var processedMicrophoneState: ProcessedMicrophoneState = .disabled
    @Published private(set) var microphoneProcessingMode: MicrophoneProcessingMode
    @Published private(set) var microphoneProcessingMessage: String?
    @Published private(set) var digitalGainDecibels: Float

    /// Meter values live outside `objectWillChange` on purpose. See
    /// `AudioLevels` for why the 20 Hz path must not notify this object.
    let levels = AudioLevels()

    private let audioSystem = CoreAudioSystem()
    private lazy var hal = AudioHALWorker(audioSystem: audioSystem)
    private let microphoneMeter = MicrophoneMeter()
    private let systemOutputMeter = SystemOutputMeter()
    private let processedMicrophoneEngine = ProcessedMicrophoneEngine()
    private let processedMicrophoneDevice = PublicProcessedMicrophoneDevice()
    private let defaults: UserDefaults
    private var refreshTimer: Timer?
    private var refreshCount = 0
    /// Bumped on every local volume, mute, or default-device write. A poll
    /// carries the value it saw at issue time, so a result that predates a
    /// write can be recognized and its control values discarded.
    private var controlWriteEpoch: UInt64 = 0
    private var isRestartingProcessedMicrophone = false
    private var levelMetersAreVisible = false
    /// Whether the always-on meter is meant to be capturing right now. The
    /// meter itself has no query, and re-issuing restart() on every policy
    /// re-evaluation would rebuild the tap for nothing.
    private var microphoneMeterShouldBeRunning = false
    private var scheduledProcessingStop: DispatchWorkItem?
    /// Set when the user switched the feature off while a consuming app still
    /// had the published device open, so the teardown has to wait for it.
    private var pendingPublicationTeardown = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        systemOutputMonitoringEnabled = defaults.bool(
            forKey: Self.systemOutputMonitoringKey
        )
        processedMicrophoneEnabled = defaults.bool(
            forKey: Self.processedMicrophoneKey
        )
        if
            let savedMode = defaults.string(
                forKey: Self.microphoneProcessingModeKey
            ),
            let mode = MicrophoneProcessingMode(rawValue: savedMode)
        {
            microphoneProcessingMode = mode
        } else {
            let migratedMode: MicrophoneProcessingMode = defaults.bool(
                forKey: Self.legacyAppleVoiceProcessingKey
            ) ? .apple : .off
            microphoneProcessingMode = migratedMode
            defaults.set(
                migratedMode.rawValue,
                forKey: Self.microphoneProcessingModeKey
            )
        }
        digitalGainDecibels = DigitalGain.clampedDecibels(
            Float(defaults.double(forKey: Self.digitalGainKey))
        )
        bluetoothMicrophoneAlwaysMonitored = defaults.bool(
            forKey: Self.bluetoothAlwaysMonitorKey
        )

        microphoneMeter.onLevel = { [weak self] rms, peak in
            guard let self else {
                return
            }
            levels.setMicrophone(rmsDecibels: rms, peakDecibels: peak)
            publishIfChanged(\.microphoneError, nil)
        }
        microphoneMeter.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.microphoneError = message
            }
        }
        systemOutputMeter.onStarted = { [weak self] in
            guard self?.systemOutputMonitoringEnabled == true else {
                return
            }
            self?.systemOutputMonitoringState = .active
        }
        systemOutputMeter.onLevel = { [weak self] rms, peak in
            guard let self, systemOutputMonitoringEnabled else {
                return
            }
            levels.setSystemOutput(rmsDecibels: rms, peakDecibels: peak)
            publishIfChanged(\.systemOutputMonitoringState, .active)
        }
        systemOutputMeter.onError = { [weak self] error in
            guard self?.systemOutputMonitoringEnabled == true else {
                return
            }
            switch error {
            case .unsupportedOS:
                self?.systemOutputMonitoringState = .unavailable
            case .permissionDenied:
                self?.systemOutputMonitoringState = .denied
            case .audioProcessUnavailable, .unsupportedFormat, .operationFailed:
                self?.systemOutputMonitoringState = .failed(
                    error.localizedDescription
                )
            }
        }
        processedMicrophoneEngine.onOutputLevel = { [weak self] rms, peak in
            guard let self, processedMicrophoneEnabled else {
                return
            }
            levels.setMicrophone(rmsDecibels: rms, peakDecibels: peak)
            publishIfChanged(\.microphoneError, nil)
        }
        processedMicrophoneEngine.onStarted = { [weak self] in
            guard let self, self.processedMicrophoneEnabled else {
                return
            }
            guard
                self.processedMicrophoneEngine.configuration.processingMode
                    == self.microphoneProcessingMode
            else {
                // The desired mode can change after start() returns but before
                // this main-queue callback runs. Never report an old mode as
                // active; rebuild it with the latest selection.
                self.restartProcessedMicrophonePipeline()
                return
            }
            self.processedMicrophoneState = .active
        }
        processedMicrophoneEngine.onError = { [weak self] error in
            self?.handleProcessedMicrophoneEngineError(error)
        }
        processedMicrophoneEngine.onNeedsRestart = { [weak self] in
            self?.restartProcessedMicrophonePipeline()
        }
        processedMicrophoneDevice.onInUseChanged = { [weak self] inUse in
            self?.handleProcessedMicrophoneInUseChange(inUse)
        }
    }

    func start() {
        // This instance does not own a route yet, regardless of the saved
        // opt-in value. Remove a public aggregate left by an earlier crash
        // before permission handling can defer the processing pipeline.
        do {
            try processedMicrophoneDevice.removeStalePublishedDevice()
        } catch {
            processedMicrophoneState = .failed(
                localized("Could not shut down the earlier processed microphone: %@", error.localizedDescription)
            )
        }
        // The aggregate above has a fixed UID, so a crashed run's device can be
        // found and removed. Its process tap has no such handle and would
        // otherwise survive indefinitely; reclaim it here, while this instance
        // owns no tap of its own and holds the instance lock.
        _ = OrphanedProcessTapReclaimer.reclaim()
        refreshDevices()
        refreshControls()
        refreshMicrophonePermission(requestIfNeeded: true)
        if systemOutputMonitoringEnabled {
            restartSystemOutputMeter()
        }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.periodicRefresh()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        processedMicrophoneEngine.stop()
        // A refusal here means a consuming app still holds the published
        // device open. Quitting leaves it behind rather than destroying it
        // under that app, which would take Core Audio down for every process
        // on the machine. The next launch reclaims it once nothing holds it.
        try? processedMicrophoneDevice.stop()
        microphoneMeter.stop()
        systemOutputMeter.stop()
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID) {
        let previous = outputDeviceID
        let epoch = beginControlWrite()
        // Show the choice immediately. Waiting for the HAL would leave the
        // picker snapped back to the old device for a round trip, which reads
        // as the click not registering.
        outputDeviceID = deviceID
        hal.setDefaultDevice(deviceID, direction: .output) { [weak self] result in
            guard let self else {
                return
            }
            if !result.accepted {
                outputDeviceID = previous
            }
            applyWriteResult(result, direction: .output, epoch: epoch)
            if result.accepted {
                restartSystemOutputMeter()
            }
        }
    }

    func selectInputDevice(_ deviceID: AudioDeviceID) {
        let previous = inputDeviceID
        let previousTransport = inputTransport
        let epoch = beginControlWrite()
        inputDeviceID = deviceID
        // The picker only offers devices from this list, so the transport is
        // on hand without a HAL read. Committing it with the ID keeps the
        // write completion's meter policy from judging the new device by the
        // old device's transport.
        if let transport = inputDevices.first(where: { $0.id == deviceID })?.transport {
            publishIfChanged(\.inputTransport, transport)
        }
        hal.setDefaultDevice(deviceID, direction: .input) { [weak self] result in
            guard let self else {
                return
            }
            if !result.accepted {
                inputDeviceID = previous
                publishIfChanged(\.inputTransport, previousTransport)
                applyWriteResult(result, direction: .input, epoch: epoch)
                // A visibility change during the round trip was judged
                // against the optimistic transport; nothing else re-runs the
                // policy for a rejected pick, because no later snapshot
                // differs from the rolled-back state.
                reconcileMicrophoneMonitoring()
                return
            }
            applyWriteResult(result, direction: .input, epoch: epoch)
            // Runs after inputDeviceID is committed, because it reads it back.
            if processedMicrophoneEnabled {
                handleInputChangeWhileProcessing()
            } else {
                restartMicrophoneMeterIfAuthorized()
            }
        }
    }

    func setOutputVolume(_ volume: Float) {
        guard outputDeviceID != kAudioObjectUnknown else {
            return
        }
        let epoch = beginControlWrite()
        outputVolume = volume
        hal.setVolume(
            volume,
            deviceID: outputDeviceID,
            direction: .output
        ) { [weak self] result in
            self?.applyWriteResult(result, direction: .output, epoch: epoch)
        }
    }

    func setInputVolume(_ volume: Float) {
        guard inputDeviceID != kAudioObjectUnknown else {
            return
        }
        let epoch = beginControlWrite()
        inputVolume = volume
        hal.setVolume(
            volume,
            deviceID: inputDeviceID,
            direction: .input
        ) { [weak self] result in
            self?.applyWriteResult(result, direction: .input, epoch: epoch)
        }
    }

    func toggleOutputMute() {
        guard
            let outputMuted,
            outputDeviceID != kAudioObjectUnknown
        else {
            return
        }
        let target = !outputMuted
        let epoch = beginControlWrite()
        // The write is asynchronous, so leaving the mute button to the
        // read-back alone would hold the icon stale for a whole round trip.
        // Show the requested state now and let the read-back correct it if the
        // device disagrees.
        self.outputMuted = target
        hal.setMuted(
            target,
            deviceID: outputDeviceID,
            direction: .output
        ) { [weak self] result in
            self?.applyWriteResult(result, direction: .output, epoch: epoch)
        }
    }

    func toggleInputMute() {
        guard
            let inputMuted,
            inputDeviceID != kAudioObjectUnknown
        else {
            return
        }
        let target = !inputMuted
        let epoch = beginControlWrite()
        self.inputMuted = target
        hal.setMuted(
            target,
            deviceID: inputDeviceID,
            direction: .input
        ) { [weak self] result in
            self?.applyWriteResult(result, direction: .input, epoch: epoch)
        }
    }

    /// Stamps a new write and returns its epoch.
    private func beginControlWrite() -> UInt64 {
        controlWriteEpoch &+= 1
        return controlWriteEpoch
    }

    /// Publishes a write's read-back unless a newer write has since been made.
    ///
    /// Without this, the tail of a drag would republish an earlier sample's
    /// read-back over a later one and the knob would jitter backward.
    private func applyWriteResult(
        _ result: AudioHALWorker.WriteResult,
        direction: AudioDirection,
        epoch: UInt64
    ) {
        guard epoch == controlWriteEpoch else {
            return
        }
        publishControls(result.controls, direction: direction)
    }

    func setSystemOutputMonitoringEnabled(_ enabled: Bool) {
        systemOutputMonitoringEnabled = enabled
        defaults.set(enabled, forKey: Self.systemOutputMonitoringKey)

        if enabled {
            restartSystemOutputMeter()
        } else {
            systemOutputMeter.stop()
            levels.resetSystemOutput()
            systemOutputMonitoringState = .disabled
        }
    }

    func setProcessedMicrophoneEnabled(_ enabled: Bool) {
        guard processedMicrophoneEnabled != enabled else {
            return
        }

        processedMicrophoneEnabled = enabled
        defaults.set(enabled, forKey: Self.processedMicrophoneKey)

        if enabled {
            pendingPublicationTeardown = false
            startProcessedMicrophone()
        } else {
            applyDisableResult(
                stopProcessedMicrophoneResources(restartLegacyMeter: true)
            )
            restartSystemOutputMeter()
        }
    }

    func setMicrophoneProcessingMode(_ mode: MicrophoneProcessingMode) {
        guard microphoneProcessingMode != mode else {
            return
        }

        microphoneProcessingMode = mode
        microphoneProcessingMessage = nil
        defaults.set(mode.rawValue, forKey: Self.microphoneProcessingModeKey)

        guard processedMicrophoneEnabled else {
            return
        }
        guard
            processedMicrophoneState == .active
                || processedMicrophoneEngine.isRunning
        else {
            return
        }

        restartProcessedMicrophonePipeline()
    }

    func setDigitalGainDecibels(_ decibels: Float) {
        let clamped = DigitalGain.clampedDecibels(decibels)
        digitalGainDecibels = clamped
        defaults.set(Double(clamped), forKey: Self.digitalGainKey)
        processedMicrophoneEngine.setDigitalGainDecibels(clamped)
    }

    func resetDigitalGain() {
        setDigitalGainDecibels(DigitalGain.neutralDecibels)
    }

    func retryProcessedMicrophone() {
        if processedMicrophoneEnabled {
            pendingPublicationTeardown = false
            startProcessedMicrophone()
        } else {
            let result = stopProcessedMicrophoneResources(restartLegacyMeter: true)
            var staleErrors: [String] = []
            do {
                try processedMicrophoneDevice.removeStalePublishedDevice()
            } catch PublicProcessedMicrophoneDeviceError.publishedDeviceInUse {
                // Someone is using a device left over from an earlier run.
                // Reported through the same waiting state as our own.
                pendingPublicationTeardown = true
                processedMicrophoneState = .awaitingRelease
                return
            } catch {
                staleErrors.append(error.localizedDescription)
            }
            applyDisableResult(result, additionalErrors: staleErrors)
        }
    }

    func retrySystemOutputMonitoring() {
        restartSystemOutputMeter()
    }

    func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSystemAudioPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSoundSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens the output list in the macOS Sound settings, where AirPlay
    /// destinations are offered.
    ///
    /// An AirPlay receiver is not a Core Audio device until it is connected,
    /// and nothing in the HAL enumerates the ones that are merely reachable,
    /// so this app cannot list them in its own picker. macOS keeps that
    /// discovery behind entitlements only its own UI carries. Once a receiver
    /// is connected there it becomes an ordinary output device with transport
    /// `airp`, and the picker selects it like any other.
    func openAirPlayOutputSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?output"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Reports meter visibility so the 20 Hz path can go quiet.
    ///
    /// The menu bar item polls the stored levels every 0.5 s and never
    /// observes them, so nothing on screen needs a live tap while both panels
    /// are closed. Safe to call repeatedly with the same value.
    func setLevelMetersVisible(_ visible: Bool) {
        guard levelMetersAreVisible != visible else {
            return
        }
        levelMetersAreVisible = visible
        levels.setMetersVisible(visible)
        systemOutputMeter.setDetailedLevelUpdatesEnabled(visible)
        reconcileMicrophoneMonitoring()
    }

    func setBluetoothMicrophoneAlwaysMonitored(_ enabled: Bool) {
        guard bluetoothMicrophoneAlwaysMonitored != enabled else {
            return
        }
        bluetoothMicrophoneAlwaysMonitored = enabled
        defaults.set(enabled, forKey: Self.bluetoothAlwaysMonitorKey)
        reconcileMicrophoneMonitoring()
    }

    /// Shown while the standing rule applies to the current input, whether or
    /// not the meter is paused this instant — with the popup open it is
    /// running, and the note is what explains the `--` after it closes.
    var showsBluetoothMonitoringNote: Bool {
        (inputTransport == .bluetooth || inputTransport == .bluetoothLE)
            && !bluetoothMicrophoneAlwaysMonitored
            && !processedMicrophoneEnabled
            && microphonePermission == .authorized
            && microphoneError == nil
    }

    private func periodicRefresh() {
        refreshCount += 1

        // Core Audio reads happen on the poller's queue and come back to
        // `apply(_:)`. Anything below this call must not touch the HAL.
        hal.poll(
            AudioHALWorker.Request(
                knownOutputDeviceID: outputDeviceID,
                knownInputDeviceID: inputDeviceID,
                wantsDeviceLists: refreshCount % 8 == 0,
                controlWriteEpoch: controlWriteEpoch
            )
        ) { [weak self] snapshot in
            self?.apply(snapshot)
        }

        if refreshCount % 8 == 0 {
            refreshMicrophonePermission(requestIfNeeded: false)
            reconcileProcessedMicrophoneProcessing()
        }
    }

    /// Publishes one poll result and runs the reactions it triggers.
    ///
    /// The order matters and matches what the synchronous version did on a
    /// single run loop turn: commit every published value first, then react.
    /// The reactions read `outputDeviceID` and `inputDeviceID` back off `self`
    /// rather than taking them as parameters, so they must not run until those
    /// are committed.
    private func apply(_ snapshot: AudioHALWorker.Snapshot) {
        let outputChanged = snapshot.outputDeviceID != outputDeviceID
        let inputChanged = snapshot.inputDeviceID != inputDeviceID
        // Epoch-gated like the controls below: a poll that was in flight
        // when selectInputDevice published the picked device's transport
        // still carries the old device's, and publishing that would make the
        // write completion judge the new device by it after all. The gate is
        // lifted when the snapshot's input device differs from the published
        // one — the snapshot's ID and transport were read together on the
        // worker queue, so they are a coherent pair for that device, and
        // suppressing the transport there would make the inputChanged
        // reaction below judge the arriving device by the old transport.
        let inputTransportChanged: Bool
        if inputChanged || snapshot.controlWriteEpoch == controlWriteEpoch {
            inputTransportChanged = snapshot.inputTransport != inputTransport
        } else {
            inputTransportChanged = false
        }

        publishIfChanged(\.outputDeviceID, snapshot.outputDeviceID)
        publishIfChanged(\.inputDeviceID, snapshot.inputDeviceID)
        if inputTransportChanged {
            publishIfChanged(\.inputTransport, snapshot.inputTransport)
        }

        if let lists = snapshot.deviceLists {
            publishIfChanged(\.outputDevices, lists.output)
            publishIfChanged(\.inputDevices, lists.input)
        }

        // A poll issued before a local write returns the value from before it.
        // Publishing that would drag a slider back to where it was and then
        // forward again on the next drag event. The write path has already
        // published the authoritative value through its own read-back, so drop
        // the stale controls and keep the IDs and device lists, which no local
        // write invalidates.
        if snapshot.controlWriteEpoch == controlWriteEpoch {
            publishControls(snapshot.outputControls, direction: .output)
            publishControls(snapshot.inputControls, direction: .input)
        }

        if inputChanged, microphonePermission == .authorized {
            if processedMicrophoneEnabled {
                handleInputChangeWhileProcessing()
            } else {
                restartMicrophoneMeterIfAuthorized()
            }
        } else if inputTransportChanged {
            // Same device, newly known transport — the first snapshot after
            // launch, mostly. No restart is owed; the policy just gets to run
            // with real data for the first time.
            reconcileMicrophoneMonitoring()
        }
        if outputChanged {
            restartSystemOutputMeter()
        }
    }

    private func publishControls(
        _ controls: AudioControlSnapshot?,
        direction: AudioDirection
    ) {
        switch direction {
        case .output:
            publishIfChanged(\.outputVolume, controls?.volume)
            publishIfChanged(
                \.outputVolumeIsAdjustable,
                controls?.volumeIsAdjustable ?? false
            )
            publishIfChanged(\.outputMuted, controls?.isMuted)
            publishIfChanged(
                \.outputMuteIsAdjustable,
                controls?.muteIsAdjustable ?? false
            )
        case .input:
            publishIfChanged(\.inputVolume, controls?.volume)
            publishIfChanged(
                \.inputVolumeIsAdjustable,
                controls?.volumeIsAdjustable ?? false
            )
            publishIfChanged(\.inputMuted, controls?.isMuted)
            publishIfChanged(
                \.inputMuteIsAdjustable,
                controls?.muteIsAdjustable ?? false
            )
        }
    }

    private func refreshDevices() {
        publishIfChanged(\.outputDevices, audioSystem.devices(for: .output))
        publishIfChanged(
            \.inputDevices,
            audioSystem.devices(for: .input).filter {
                !PublicProcessedMicrophoneDevice.ownsAggregateDeviceUID($0.uid)
            }
        )
        publishIfChanged(
            \.outputDeviceID,
            audioSystem.defaultDevice(for: .output)
                ?? AudioDeviceID(kAudioObjectUnknown)
        )
        publishIfChanged(
            \.inputDeviceID,
            audioSystem.defaultDevice(for: .input)
                ?? AudioDeviceID(kAudioObjectUnknown)
        )
    }

    private func refreshControls() {
        if outputDeviceID != kAudioObjectUnknown {
            let output = audioSystem.controls(for: outputDeviceID, direction: .output)
            publishIfChanged(\.outputVolume, output.volume)
            publishIfChanged(\.outputVolumeIsAdjustable, output.volumeIsAdjustable)
            publishIfChanged(\.outputMuted, output.isMuted)
            publishIfChanged(\.outputMuteIsAdjustable, output.muteIsAdjustable)
        } else {
            publishIfChanged(\.outputVolume, nil)
            publishIfChanged(\.outputVolumeIsAdjustable, false)
            publishIfChanged(\.outputMuted, nil)
            publishIfChanged(\.outputMuteIsAdjustable, false)
        }

        if inputDeviceID != kAudioObjectUnknown {
            let input = audioSystem.controls(for: inputDeviceID, direction: .input)
            publishIfChanged(\.inputVolume, input.volume)
            publishIfChanged(\.inputVolumeIsAdjustable, input.volumeIsAdjustable)
            publishIfChanged(\.inputMuted, input.isMuted)
            publishIfChanged(\.inputMuteIsAdjustable, input.muteIsAdjustable)
        } else {
            publishIfChanged(\.inputVolume, nil)
            publishIfChanged(\.inputVolumeIsAdjustable, false)
            publishIfChanged(\.inputMuted, nil)
            publishIfChanged(\.inputMuteIsAdjustable, false)
        }
    }

    /// Assigns only when the value actually differs.
    ///
    /// `@Published` notifies on every assignment, equal or not, and the 0.25 s
    /// refresh rewrites a dozen mostly-unchanged properties. Each redundant
    /// notification is a full SwiftUI update of the open panel.
    private func publishIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AudioState, Value>,
        _ newValue: Value
    ) {
        guard self[keyPath: keyPath] != newValue else {
            return
        }
        self[keyPath: keyPath] = newValue
    }

    private func refreshMicrophonePermission(requestIfNeeded: Bool) {
        let previousPermission = microphonePermission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermission = .authorized
        case .denied:
            microphonePermission = .denied
        case .restricted:
            microphonePermission = .restricted
        case .notDetermined:
            microphonePermission = requestIfNeeded ? .requesting : .notDetermined
            guard requestIfNeeded else {
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshMicrophonePermission(requestIfNeeded: false)
                }
            }
        @unknown default:
            microphonePermission = .restricted
        }

        guard microphonePermission != previousPermission else {
            return
        }

        if microphonePermission == .authorized {
            if processedMicrophoneEnabled {
                startProcessedMicrophone()
            } else {
                restartMicrophoneMeterIfAuthorized()
            }
        } else if
            processedMicrophoneEnabled,
            microphonePermission == .denied
                || microphonePermission == .restricted
        {
            _ = stopProcessedMicrophoneResources(restartLegacyMeter: false)
            processedMicrophoneState = .microphoneDenied
        } else if processedMicrophoneEnabled {
            processedMicrophoneState = .starting
        }
    }

    private func restartMicrophoneMeterIfAuthorized() {
        guard
            microphonePermission == .authorized,
            !processedMicrophoneEnabled
        else {
            return
        }
        applyMicrophoneMeterPolicy(restartIfRunning: true)
    }

    /// Re-evaluates the Bluetooth pause without forcing a restart. Called when
    /// a policy input changed: panel visibility, the input transport, or the
    /// always-monitor setting.
    private func reconcileMicrophoneMonitoring() {
        guard
            microphonePermission == .authorized,
            !processedMicrophoneEnabled
        else {
            return
        }
        applyMicrophoneMeterPolicy(restartIfRunning: false)
    }

    /// Records a meter start made outside the policy — the processed
    /// microphone's paths, where metering is continuous by decision. Keeping
    /// the flag and the published pause truthful here is what lets the policy
    /// pick the meter back up correctly when the feature turns off.
    private func noteMeterRunningOutsidePolicy() {
        microphoneMeterShouldBeRunning = true
        publishIfChanged(\.microphoneMonitoringPaused, false)
    }

    /// The one place that starts and suspends the always-on meter.
    private func applyMicrophoneMeterPolicy(restartIfRunning: Bool) {
        if BluetoothMicrophonePolicy.shouldPauseMonitoring(
            transport: inputTransport,
            alwaysMonitorBluetooth: bluetoothMicrophoneAlwaysMonitored,
            metersAreVisible: levelMetersAreVisible
        ) {
            publishIfChanged(\.microphoneMonitoringPaused, true)
            guard microphoneMeterShouldBeRunning else {
                return
            }
            microphoneMeterShouldBeRunning = false
            microphoneMeter.suspend()
            levels.resetMicrophone()
            publishIfChanged(\.microphoneError, nil)
        } else {
            publishIfChanged(\.microphoneMonitoringPaused, false)
            guard restartIfRunning || !microphoneMeterShouldBeRunning else {
                return
            }
            microphoneMeterShouldBeRunning = true
            levels.resetMicrophone()
            microphoneMeter.restart()
        }
    }

    private func startProcessedMicrophone() {
        guard processedMicrophoneEnabled else {
            return
        }
        guard #available(macOS 14.2, *) else {
            processedMicrophoneState = .unavailable
            return
        }

        switch microphonePermission {
        case .authorized:
            break
        case .denied, .restricted:
            processedMicrophoneState = .microphoneDenied
            return
        case .notDetermined, .requesting:
            processedMicrophoneState = .starting
            return
        }

        if isProcessedMicrophoneDevice(inputDeviceID) {
            try? processedMicrophoneDevice.removeStalePublishedDevice()
            refreshDevices()
            if isProcessedMicrophoneDevice(inputDeviceID) {
                _ = stopProcessedMicrophoneResources(restartLegacyMeter: true)
                processedMicrophoneState = .failed(
                    localized("The processed microphone cannot be its own source. Make a physical microphone the default input and try again.")
                )
                return
            }
        }

        _ = stopProcessedMicrophoneResources(restartLegacyMeter: false)
        processedMicrophoneState = .starting
        levels.resetMicrophone()
        microphoneError = nil

        startProcessedMicrophonePipeline()
    }

    private func startProcessedMicrophonePipeline() {
        guard processedMicrophoneEnabled else {
            return
        }

        // Ensure this process has a Core Audio process object even during a
        // cold launch with the saved opt-in already enabled. Publishing the
        // device translates this pid to a Core Audio process object, and that
        // object only exists once something in this process has opened audio.
        // The meter is what opens it, and its engine comes up on its own
        // queue, so publication waits for that rather than assuming it. While
        // no app is consuming the published device this meter also stays on as
        // the menu bar's microphone source, in place of the processing engines.
        noteMeterRunningOutsidePolicy()
        microphoneMeter.restart { [weak self] in
            self?.publishProcessedMicrophone()
        }
    }

    private func publishProcessedMicrophone() {
        guard processedMicrophoneEnabled else {
            return
        }

        do {
            _ = try processedMicrophoneDevice.start()

            if shouldRunProcessingEngines {
                startProcessedMicrophoneProcessing()
            } else {
                processedMicrophoneState = .publishedIdle
            }
            if systemOutputMonitoringEnabled {
                // Rebuild only after publication is ready. SystemOutputMeter
                // starts asynchronously, so this ordering avoids racing its
                // HAL object creation against the public process tap while
                // still excluding this process from the speaker meter.
                restartSystemOutputMeter()
            }
            // Every failed start reports its concrete error asynchronously.
            // Keep the already-muted public route alive until that callback so
            // Apple processing can fall back without racing stable-UID device
            // destruction and recreation. Non-recoverable errors tear it down
            // in handleProcessedMicrophoneEngineError(_:).
            refreshDevices()
        } catch let error as PublicProcessedMicrophoneDeviceError {
            handleProcessedMicrophoneDeviceError(error)
        } catch {
            processedMicrophoneState = .failed(
                localized("Could not start the processed microphone: %@", error.localizedDescription)
            )
            _ = stopProcessedMicrophoneResources(restartLegacyMeter: true)
        }
    }

    /// Whether the capture and publisher engines need to run right now.
    ///
    /// Apple voice processing is by far the most expensive part of this app,
    /// and it produces audio nobody reads while no app has the published
    /// device open. Without the in-use signal, fall back to running it
    /// unconditionally rather than publishing silence.
    private var shouldRunProcessingEngines: Bool {
        guard processedMicrophoneDevice.isMonitoringInUse else {
            return true
        }
        return processedMicrophoneDevice.isInUse
    }

    private func startProcessedMicrophoneProcessing() {
        cancelScheduledProcessingStop()
        guard
            processedMicrophoneEnabled,
            microphonePermission == .authorized,
            processedMicrophoneDevice.isPublished,
            !processedMicrophoneEngine.isRunning
        else {
            return
        }

        levels.resetMicrophone()
        processedMicrophoneState = .starting

        // The legacy meter and the capture engine both open the default input,
        // and voice processing gets a broken or silent input if it claims the
        // device while the meter still holds it. The meter's teardown runs on
        // its own queue, so wait for it rather than assume it already happened.
        microphoneMeterShouldBeRunning = false
        microphoneMeter.stop { [weak self] in
            guard let self else {
                return
            }
            // Conditions can change while the meter is releasing the device.
            guard
                processedMicrophoneEnabled,
                processedMicrophoneState == .starting,
                !processedMicrophoneEngine.isRunning
            else {
                return
            }
            _ = processedMicrophoneEngine.start(
                configuration: .init(
                    processingMode: microphoneProcessingMode,
                    digitalGainDecibels: digitalGainDecibels
                )
            )
        }
    }

    private func handleProcessedMicrophoneInUseChange(_ inUse: Bool) {
        if pendingPublicationTeardown {
            if !inUse {
                completePendingPublicationTeardown()
            }
            return
        }

        guard
            processedMicrophoneEnabled,
            processedMicrophoneDevice.isPublished
        else {
            return
        }

        if inUse {
            startProcessedMicrophoneProcessing()
        } else {
            scheduleProcessingStopForIdle()
        }
    }

    private func scheduleProcessingStopForIdle() {
        guard
            processedMicrophoneEngine.isRunning,
            scheduledProcessingStop == nil
        else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            scheduledProcessingStop = nil
            stopProcessingWhileIdle()
        }
        scheduledProcessingStop = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.processingIdleGracePeriod,
            execute: workItem
        )
    }

    private func cancelScheduledProcessingStop() {
        scheduledProcessingStop?.cancel()
        scheduledProcessingStop = nil
    }

    private func stopProcessingWhileIdle() {
        guard
            processedMicrophoneEnabled,
            processedMicrophoneDevice.isPublished,
            !shouldRunProcessingEngines
        else {
            return
        }

        // The publication itself stays up: other apps keep seeing the device
        // in their input lists, and reopening it starts processing again.
        //
        // It also keeps the same Core Audio object. Replacing the object here
        // would let a consumer that reopens the device hear something — see the
        // known limitation in ROADMAP.md — but rebuilding a public aggregate on
        // every idle transition turned out to be more than the HAL keeps up
        // with: the wait for the destroyed UID to leave the device list starts
        // timing out after a handful of cycles, and the device then disappears
        // from every app's input list until the feature is switched off and on.
        // Silence on a second session is a smaller failure than a device that
        // vanishes, so the object is left alone.
        processedMicrophoneEngine.stop()
        levels.resetMicrophone()
        restartLegacyMicrophoneMeter()
        processedMicrophoneState = .publishedIdle
    }

    /// Recovers from a missed property notification.
    ///
    /// The listener is the real signal; this only has to catch a dropped one,
    /// so it runs on the slow cadence and reads a single HAL property. Do not
    /// consult `isPublished` here: validating the publication enumerates every
    /// device in the system, which is far too much for a safety net.
    private func reconcileProcessedMicrophoneProcessing() {
        // Catches a dropped notification for the deferred teardown too. The
        // guard below is about the running pipeline, which a disabled feature
        // no longer has.
        if pendingPublicationTeardown {
            if !processedMicrophoneDevice.isInUse {
                completePendingPublicationTeardown()
            }
            return
        }

        guard
            processedMicrophoneEnabled,
            processedMicrophoneDevice.isMonitoringInUse,
            processedMicrophoneState != .starting
        else {
            return
        }

        if processedMicrophoneDevice.isInUse {
            cancelScheduledProcessingStop()
            if !processedMicrophoneEngine.isRunning {
                startProcessedMicrophoneProcessing()
            }
        } else if processedMicrophoneEngine.isRunning {
            scheduleProcessingStopForIdle()
        }
    }

    private func handleInputChangeWhileProcessing() {
        guard processedMicrophoneEnabled else {
            return
        }
        guard !isProcessedMicrophoneDevice(inputDeviceID) else {
            _ = stopProcessedMicrophoneResources(restartLegacyMeter: true)
            processedMicrophoneState = .failed(
                localized("The processed microphone cannot be its own source. Make a physical microphone the default input and try again.")
            )
            return
        }

        guard processedMicrophoneDevice.isPublished else {
            startProcessedMicrophone()
            return
        }

        if processedMicrophoneEngine.isRunning {
            restartProcessedMicrophonePipeline()
        } else {
            // Idle: only the meter follows the new default input. Processing
            // picks it up when an app opens the published device again.
            restartLegacyMicrophoneMeter()
        }
    }

    private func restartProcessedMicrophonePipeline() {
        guard
            processedMicrophoneEnabled,
            microphonePermission == .authorized,
            !isRestartingProcessedMicrophone
        else {
            return
        }

        isRestartingProcessedMicrophone = true
        defer { isRestartingProcessedMicrophone = false }

        // Fail closed: the publisher is stopped before checking the muted tap.
        // PublicProcessedMicrophoneDevice.start() validates and, if needed,
        // recreates the tap/aggregate before publisher audio resumes.
        cancelScheduledProcessingStop()
        processedMicrophoneState = .starting
        processedMicrophoneEngine.stop()
        levels.resetMicrophone()
        startProcessedMicrophonePipeline()
    }

    private func handleProcessedMicrophoneDeviceError(
        _ error: PublicProcessedMicrophoneDeviceError
    ) {
        switch error {
        case .unsupportedOS:
            processedMicrophoneState = .unavailable
        case .permissionDenied:
            processedMicrophoneState = .systemAudioDenied
        default:
            processedMicrophoneState = .failed(
                error.errorDescription ?? error.localizedDescription
            )
        }
        _ = stopProcessedMicrophoneResources(restartLegacyMeter: true)
    }

    private func handleProcessedMicrophoneEngineError(
        _ error: ProcessedMicrophoneEngineError
    ) {
        guard processedMicrophoneEnabled else {
            return
        }

        let failedMode = processedMicrophoneEngine.configuration.processingMode
        if failedMode != microphoneProcessingMode {
            // This error belongs to a superseded start generation. Keep the
            // user's newer selection and rebuild instead of disabling it.
            restartProcessedMicrophonePipeline()
            return
        }

        if failedMode != .off {
            microphoneProcessingMode = .off
            defaults.set(
                MicrophoneProcessingMode.off.rawValue,
                forKey: Self.microphoneProcessingModeKey
            )
            let detail = error.errorDescription ?? error.localizedDescription
            microphoneProcessingMessage =
                localized(
                    "%1$@ could not start, so processing was turned off and the processed microphone kept running (%2$@).",
                    failedMode.displayName,
                    detail
                )
            restartProcessedMicrophonePipeline()
            return
        }

        let message = error.errorDescription ?? error.localizedDescription
        _ = stopProcessedMicrophoneResources(restartLegacyMeter: true)
        processedMicrophoneState = .failed(message)
    }

    @discardableResult
    private func stopProcessedMicrophoneResources(
        restartLegacyMeter: Bool
    ) -> ProcessedMicrophoneTeardownResult {
        // Stop the publisher before destroying its muted tap so processed
        // microphone samples can never briefly reach the physical output.
        cancelScheduledProcessingStop()
        processedMicrophoneEngine.stop()

        var result = ProcessedMicrophoneTeardownResult.completed
        do {
            try processedMicrophoneDevice.stop()
        } catch PublicProcessedMicrophoneDeviceError.publishedDeviceInUse {
            result = .deferredWhileInUse
        } catch {
            result = .failed(error.localizedDescription)
        }

        refreshDevices()
        if restartLegacyMeter {
            restartLegacyMicrophoneMeter()
        }
        return result
    }

    /// Finishes a teardown that was held back while a consuming app had the
    /// published device open.
    ///
    /// The engines were already stopped when the user switched the feature
    /// off, so nothing is being processed in the meantime; what survives is
    /// the published device itself, and it goes as soon as the other app lets
    /// go of it.
    private func completePendingPublicationTeardown() {
        guard pendingPublicationTeardown, !processedMicrophoneEnabled else {
            return
        }

        switch stopProcessedMicrophoneResources(restartLegacyMeter: true) {
        case .completed:
            pendingPublicationTeardown = false
            processedMicrophoneState = .disabled
        case .deferredWhileInUse:
            return
        case let .failed(message):
            pendingPublicationTeardown = false
            processedMicrophoneState = .failed(message)
        }
    }

    private func applyDisableResult(
        _ result: ProcessedMicrophoneTeardownResult,
        additionalErrors: [String] = []
    ) {
        switch result {
        case .completed:
            pendingPublicationTeardown = false
            processedMicrophoneState = additionalErrors.isEmpty
                ? .disabled
                : .failed(additionalErrors.joined(separator: " "))
        case .deferredWhileInUse:
            pendingPublicationTeardown = true
            processedMicrophoneState = .awaitingRelease
        case let .failed(message):
            pendingPublicationTeardown = false
            processedMicrophoneState = .failed(
                ([message] + additionalErrors).joined(separator: " ")
            )
        }
    }

    private func restartLegacyMicrophoneMeter() {
        guard microphonePermission == .authorized else {
            return
        }
        guard processedMicrophoneEnabled else {
            // The feature was already switched off by the time this restart
            // runs — a deferred publication teardown completing after the
            // consuming app finally let go, possibly hours later with no
            // panel showing. The continuous-metering exclusion is owed only
            // while the feature is on, so the Bluetooth policy decides here.
            // A pause taken against a nil transport cannot wedge on this
            // side: the transport-known reconcile is gated off only while
            // the feature is enabled.
            applyMicrophoneMeterPolicy(restartIfRunning: true)
            return
        }
        // While the feature is enabled, deliberately not the Bluetooth
        // policy: the published device must be openable at any moment, its
        // idle meter is the menu bar's source, and the user opted in
        // explicitly. Routing this through the policy is what paused the
        // meter against a nil transport at cold launch and then wedged,
        // because the reconcile that would have recovered is gated on the
        // feature being off.
        noteMeterRunningOutsidePolicy()
        levels.resetMicrophone()
        microphoneMeter.restart()
    }

    private func isProcessedMicrophoneDevice(
        _ deviceID: AudioDeviceID
    ) -> Bool {
        guard
            deviceID != kAudioObjectUnknown,
            let uid = audioSystem.deviceUID(for: deviceID)
        else {
            return false
        }
        return PublicProcessedMicrophoneDevice.ownsAggregateDeviceUID(uid)
    }

    private func restartSystemOutputMeter() {
        guard systemOutputMonitoringEnabled else {
            return
        }
        guard #available(macOS 14.2, *) else {
            systemOutputMonitoringState = .unavailable
            return
        }
        guard
            outputDeviceID != kAudioObjectUnknown,
            let deviceUID = audioSystem.deviceUID(for: outputDeviceID)
        else {
            systemOutputMonitoringState = .failed(
                localized("The default output device could not be read.")
            )
            return
        }

        levels.resetSystemOutput()
        systemOutputMonitoringState = .starting
        systemOutputMeter.start(
            deviceUID: deviceUID,
            excludingCurrentProcess: processedMicrophoneEnabled
        )
    }
}
