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
    /// A quiet window armed after the evaluation that issued the teardown
    /// read its admission. Either the engines' stop was held back, and
    /// nothing was withdrawn, because the publisher may still render and its
    /// muted tap is what keeps that inaudible; or the withdrawal itself
    /// ended before one of its destroys. The teardown stays owed.
    case heldBack
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
    /// On, but the default input — or for Apple voice processing the default
    /// output — is not a source the app opens by itself, or there is no
    /// output the publisher engine may be bound to. Nothing is captured.
    /// `published` tells whether an earlier publication stays available,
    /// sending silence, until the source is allowed again.
    case refused(ProcessedMicrophoneRefusal, published: Bool)

    /// A state the feature leaves only when the user retries or switches it
    /// off and on again.
    var isHalted: Bool {
        switch self {
        case .microphoneDenied, .systemAudioDenied, .unavailable, .failed:
            return true
        case .disabled, .starting, .publishedIdle, .active, .awaitingRelease, .refused:
            return false
        }
    }

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
        case let .refused(refusal, published):
            switch refusal {
            case .bluetoothInput where published:
                return localized("Processing is paused because the default input is a Bluetooth microphone, or an aggregate device that includes a Bluetooth device or a device that is not available. “Audio Level Bar Microphone” stays available and sends silence until another input is the default.")
            case .bluetoothInput:
                return localized("The processed microphone does not start while the default input is a Bluetooth microphone, or an aggregate device that includes a Bluetooth device or a device that is not available, because opening it could switch a headset into call mode and lower playback quality. It starts once another input is the default.")
            case .bluetoothOutputForVoiceProcessing where published:
                return localized("Apple voice processing is paused while a Bluetooth device is the default input or output. “Audio Level Bar Microphone” stays available and sends silence until that changes or another processing mode is chosen.")
            case .bluetoothOutputForVoiceProcessing:
                return localized("Apple voice processing does not start while a Bluetooth device is the default input or output. Another processing mode works with a Bluetooth output.")
            case .bluetoothDevicePresentForVoiceProcessing where published:
                return localized("Apple voice processing is paused while a Bluetooth audio device is connected. “Audio Level Bar Microphone” stays available and sends silence until none is connected or another processing mode is chosen.")
            case .bluetoothDevicePresentForVoiceProcessing:
                return localized("Apple voice processing does not start while a Bluetooth audio device is connected. It starts by itself once none is connected. Another processing mode works while one is.")
            case .noNonBluetoothOutput where published:
                return localized("Processing is paused because there is no built-in or other non-Bluetooth output to render it to. “Audio Level Bar Microphone” stays available and sends silence until there is.")
            case .noNonBluetoothOutput:
                return localized("The processed microphone does not start without a built-in or other non-Bluetooth output. It renders its audio, muted, to such an output rather than to a Bluetooth headset. It starts once one is available.")
            case .noInput, .transportNotRead:
                return localized("Preparing the processed microphone")
            }
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
    /// Whether the microphone meter gave up on the default input: its start
    /// failed `MeterSession.maximumStartAttempts` times in a row, and no
    /// further start is issued for that input by itself. The panel then offers
    /// Retry beside `microphoneError`; see `retryMicrophoneMeter()`. A failed
    /// start releases what it created before it reports, so a meter that gave
    /// up holds nothing open.
    @Published private(set) var microphoneMeterGaveUp = false
    /// What the microphone meter shows: a live level, a start in progress, or
    /// why nothing is measured. It follows the target at once, including while
    /// the quiet window holds the meter itself where it is.
    @Published private(set) var microphoneDisplay: MeterSession.Display = .starting
    /// Transport of the current default input and, for an aggregate, of its
    /// active sub-devices, read with the input's ID on every poll. nil until
    /// the first snapshot arrives or when it could not be read; the meter does
    /// not open a device until it is known, so a Bluetooth headset is never
    /// opened just to find out it should not have been.
    @Published private(set) var inputTransportInfo: AudioDeviceTransportInfo?
    /// The same for the default output.
    @Published private(set) var outputTransportInfo: AudioDeviceTransportInfo?

    @Published private(set) var processedMicrophoneEnabled: Bool
    @Published private(set) var processedMicrophoneState: ProcessedMicrophoneState = .disabled
    @Published private(set) var microphoneProcessingMode: MicrophoneProcessingMode
    @Published private(set) var microphoneProcessingMessage: String?
    @Published private(set) var digitalGainDecibels: Float

    /// Meter values live outside `objectWillChange` on purpose. See
    /// `AudioLevels` for why the 20 Hz path must not notify this object.
    let levels = AudioLevels()

    private let audioSystem: any AudioHALWorkerSystem
    /// Advanced every time the quiet window arms. A HAL start already on its
    /// way compares it before each create and start, and stops there when a
    /// window armed after the start was issued.
    private let lifecycleHoldGeneration = LifecycleHoldGeneration()
    private lazy var hal = AudioHALWorker(
        audioSystem: audioSystem,
        holdGeneration: lifecycleHoldGeneration,
        now: clock
    )
    /// The Core Audio calls the meters, the capture and the publication make
    /// to create, start, stop and destroy their resources.
    private let lifecycleCalls: any HALLifecycleCalls
    /// The lifecycle clock; see `lifecycleNow()`.
    private let clock: () -> TimeInterval
    private let scheduler: any AudioStateScheduler
    private let microphoneAuthorization: any MicrophoneAuthorization
    private let makePublisherEngine: () -> any ProcessedMicrophonePublisherEngine
    private let makeVoiceProcessingEngine: () -> any VoiceProcessingCaptureEngine
    private let tapReclaimInventory: OrphanedProcessTapReclaimer.Inventory
    private let powerNotificationCenter: NotificationCenter
    private lazy var microphoneMeter = MicrophoneMeter(
        halCalls: lifecycleCalls,
        holdGeneration: lifecycleHoldGeneration
    )
    private lazy var systemOutputMeter = SystemOutputMeter(
        halCalls: lifecycleCalls,
        holdGeneration: lifecycleHoldGeneration
    )
    private lazy var processedMicrophoneEngine = ProcessedMicrophoneEngine(
        halCalls: lifecycleCalls,
        holdGeneration: lifecycleHoldGeneration,
        makePublisherEngine: makePublisherEngine,
        makeVoiceProcessingEngine: makeVoiceProcessingEngine
    )
    private lazy var processedMicrophoneDevice = PublicProcessedMicrophoneDevice(
        halCalls: lifecycleCalls,
        holdGeneration: lifecycleHoldGeneration
    )
    /// Default-device changes, device-list changes and a coreaudiod restart,
    /// heard from the HAL system object before the poll sees them.
    private lazy var systemNotifications = SystemAudioNotifications(
        halCalls: lifecycleCalls,
        holdGeneration: lifecycleHoldGeneration
    )
    /// Writes the system's sleep and wake to the hal-lifecycle log.
    private lazy var powerStateLog = PowerStateLog(
        center: powerNotificationCenter,
        holdGeneration: lifecycleHoldGeneration
    )
    private let defaults: UserDefaults
    /// Invalidates the 0.25 s poll timer.
    private var cancelRefreshTimer: (() -> Void)?
    private var refreshCount = 0
    /// Bumped on every local volume, mute, or default-device write. A poll
    /// carries the value it saw at issue time, so a result that predates a
    /// write can be recognized and its control values discarded.
    private var controlWriteEpoch: UInt64 = 0
    private var levelMetersAreVisible = false
    /// Decides the microphone meter's starts and stops; see
    /// `reconcileLifecycle()`.
    private var meterSession = MeterSession()
    /// Whether `inputDeviceID` is this app's own published processed
    /// microphone, as the poll read it. nil until read.
    private var inputIsProcessedMicrophone: Bool?
    /// True from the moment the hand-off to the processing engines begins
    /// until the engine start it waits for has been issued, or abandoned.
    private var processingStartInFlight = false
    /// Set while the processed microphone waits for the meter to be running on
    /// the current input before it publishes. Publishing translates this
    /// process to a Core Audio process object, which exists only once this
    /// process has IO running, and the meter is what runs it.
    private var publishWhenMeterStarts = false
    /// Publication attempts that found no process object for this process,
    /// and when the next one may run. One retry is made, on an evaluation at
    /// least `publicationRetryDelay` later, with the meter still running and
    /// no extra IO started for it.
    private var publicationAttempts = 0
    private var publicationRetryAt: TimeInterval = -.infinity
    private static let publicationRetryDelay: TimeInterval = 1
    /// Publications the quiet window interrupted in a row. Each is rolled
    /// back after its window and issued again, so at the cap the evaluation
    /// that has rolled the last one back publishes nothing more and halts
    /// the processed microphone with Retry. See `PublicationInterruptions`.
    private var publicationInterruptions = PublicationInterruptions()
    /// Whether a consuming app has the published device open, as the in-use
    /// listener or the slow safety net last reported it. Kept here so an
    /// evaluation reads no HAL property on the main thread; the teardown
    /// reads the device itself before it destroys anything.
    private var processedMicrophoneInUse = false
    /// A Bluetooth refusal from the capture's own uncached re-read of the
    /// input it was started for, with the transport the poll showed for that
    /// input at the time. It stands until the default input or its transport
    /// changes, so the evaluation does not hand the input over again and again
    /// to a device the poll cannot tell apart from an allowed one. A read that
    /// only failed is not latched here; see `captureInputRetry`.
    private var captureRefusal: SourceRefusalLatch?
    /// The same for Apple voice processing: a Bluetooth refusal from its
    /// uncached read of both defaults immediately before starting. It stands
    /// while that mode is selected and the poll shows the same default input
    /// and output with the same transports, so the start is not retried once
    /// per quiet window while the poll and the fresh read disagree.
    private var voiceProcessingRefusal: SourceRefusalLatch?
    /// The same for the publisher engine's output: the read made immediately
    /// before the engine is built found no output it may be bound to, while
    /// the poll still showed one. It stands while the poll shows the same
    /// default output with the same transport.
    private var publisherOutputRefusal: SourceRefusalLatch?
    /// Retries of a processed microphone start whose output read no usable
    /// format: spaced, and ended by repeated reads on one output. See
    /// `PublisherOutputRetry`.
    private var publisherOutputRetry = PublisherOutputRetry()
    /// Retries of a capture start whose input only the read made as it was
    /// opened refused, because its transport, or a member of an aggregate
    /// device, could not be read: spaced and capped as the microphone meter's
    /// are. See `CaptureInputRetry`.
    private var captureInputRetry = CaptureInputRetry()
    /// A Retry on a switched-off, failed processed microphone that the quiet
    /// window held back.
    private var pendingDisabledRetry = false
    private var isReconciling = false
    /// Quit has been requested. From then on nothing is polled or evaluated,
    /// the pickers and toggles do nothing, and every lifecycle start and stop
    /// outside Quit's own teardown holds, whether or not the teardown waits
    /// for a quiet window first.
    private var quitRequested = false
    /// `QuitPlan.deferralMaximum` after the Quit request, on the lifecycle
    /// clock: the latest Quit's teardown waits for the window. nil before a
    /// request, and after a termination that never asked.
    private var quitDeadline: TimeInterval?
    /// Holds HAL resource changes for a few seconds after a Bluetooth device
    /// connects or disconnects, a default device changes, or the metered
    /// device reconfigures. See `LifecycleQuietWindow`.
    private var quietWindow = LifecycleQuietWindow()
    /// The quiet window's generation as of the main thread's latest arming.
    /// A listener that advances the generation on its own queue leaves the
    /// window unarmed until its report reaches the main thread; meanwhile an
    /// evaluation that reads a generation it has not seen holds and arms the
    /// window itself, and every start and stop it issues carries this value.
    private var generationSeenOnMain: UInt64 = 0
    /// What the previous poll saw, to tell whether this one arms the window.
    private var lastTopology: AudioTopology?
    /// The Bluetooth and Bluetooth LE audio devices the latest poll found,
    /// and whether it read the transport of every device it listed. nil until
    /// a poll has applied, and again after a coreaudiod restart.
    private var polledBluetoothDevices: (ids: Set<AudioDeviceID>, everyTransportRead: Bool)?
    /// When the newest poll that has applied was issued, on the lifecycle
    /// clock. A release waits for a poll issued at or after the window's end,
    /// so it never acts on a topology read before a change it has not seen.
    private var lastAppliedSnapshotIssuedAt: TimeInterval?
    /// Default-device writes from the pickers whose completion has not run.
    /// They hold the quiet window up to its cap, and a poll read before one
    /// of them does not move that direction's device.
    private var defaultDeviceWrites = DefaultDeviceWrites<AudioDirection>()
    /// A system playback meter rebuild or stop the quiet window is holding
    /// back. Its callbacks are ignored while one is pending, so the display
    /// can already show where it is going. See `SystemOutputIntent`.
    private var systemOutputIntent = SystemOutputIntent()
    /// Whether the running system playback meter still delivers levels, and
    /// how far apart the rebuilds of an invalidated one are spaced. See
    /// `SystemOutputRecovery`.
    private var systemOutputRecovery = SystemOutputRecovery()
    /// Whether a check found the system playback meter's levels missing and
    /// its confirmation waits for a later main-queue turn.
    private var systemOutputStaleConfirmationQueued = false
    /// The system playback meter's latest start or stop, until its lifecycle
    /// queue has come back from it.
    private var systemOutputCallWatch = LifecycleCallWatch()
    /// The processed microphone capture's latest start, until it reports, or
    /// its latest release, until the capture queue has come back from it.
    private var captureCallWatch = LifecycleCallWatch()
    /// The token of the capture start `captureCallWatch` last issued.
    private var captureStartToken: UInt64 = 0
    /// The microphone meter's stop for a hand-off to the processed
    /// microphone, until it completes.
    private var handOffStopWatch = LifecycleCallWatch()
    /// The input the hand-off stop was issued for, for its stall line.
    private var handOffStopDeviceID = AudioDeviceID(kAudioObjectUnknown)
    /// The idle grace period after the last consumer closed the published
    /// device. Processing is still wanted while it runs.
    private var scheduledProcessingStop: DispatchWorkItem?
    /// A teardown of the publication is owed: the user switched the feature
    /// off, or a failure halted it. It waits for the quiet window and for any
    /// consuming app to close the device.
    private var pendingPublicationTeardown = false
    /// The removal of what an earlier run left behind, owed from launch until
    /// the first evaluation that admits starts. Starts stay held until it has
    /// run. See `LaunchCleanup`.
    private var launchCleanup = LaunchCleanup()

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, dependencies: .live())
    }

    /// - Parameter dependencies: `Dependencies.live()` in the app.
    init(defaults: UserDefaults, dependencies: Dependencies) {
        self.defaults = defaults
        audioSystem = dependencies.audioSystem
        lifecycleCalls = dependencies.halCalls
        clock = dependencies.now
        scheduler = dependencies.scheduler
        microphoneAuthorization = dependencies.microphoneAuthorization
        makePublisherEngine = dependencies.makePublisherEngine
        makeVoiceProcessingEngine = dependencies.makeVoiceProcessingEngine
        tapReclaimInventory = dependencies.tapReclaimInventory
        powerNotificationCenter = dependencies.powerNotificationCenter
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

        microphoneMeter.onLevel = { [weak self] rms, peak in
            // A level from a meter the display no longer shows as live — one
            // being replaced, or invalidated under it — is dropped.
            guard let self, microphoneDisplay == .live else {
                return
            }
            levels.setMicrophone(rmsDecibels: rms, peakDecibels: peak)
        }
        microphoneMeter.onEvent = { [weak self] event in
            self?.handleMicrophoneMeterEvent(event)
        }
        // While a rebuild or stop is pending, the tap still running belongs to
        // the previous output or setting, so nothing it reports is shown.
        systemOutputMeter.onStarted = { [weak self] in
            guard
                let self,
                systemOutputMonitoringEnabled,
                systemOutputIntent.pending == nil
            else {
                return
            }
            systemOutputRecovery.started(at: lifecycleNow())
            systemOutputMonitoringState = .active
        }
        systemOutputMeter.onLevel = { [weak self] rms, peak in
            guard
                let self,
                systemOutputMonitoringEnabled,
                systemOutputIntent.pending == nil
            else {
                return
            }
            systemOutputRecovery.level(at: lifecycleNow())
            levels.setSystemOutput(rmsDecibels: rms, peakDecibels: peak)
            publishIfChanged(\.systemOutputMonitoringState, .active)
        }
        systemOutputMeter.onError = { [weak self] error in
            guard
                self?.systemOutputMonitoringEnabled == true,
                self?.systemOutputIntent.pending == nil
            else {
                return
            }
            self?.systemOutputRecovery.stopped()
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
        systemOutputMeter.onInterrupted = { [weak self] in
            guard let self else {
                return
            }
            // A quiet window armed while the rebuild was on its way to the
            // HAL. It runs again, once, after the window; a pending stop
            // stays a stop.
            systemOutputRecovery.stopped()
            _ = systemOutputIntent.handle(
                .interrupted(monitoringEnabled: systemOutputMonitoringEnabled)
            )
            guard systemOutputMonitoringEnabled else {
                return
            }
            showSystemOutputRebuildOwed()
            reconcileLifecycle()
        }
        systemOutputMeter.onOutputMoved = { [weak self] in
            guard let self else {
                return
            }
            // The default output moved after the poll this rebuild was decided
            // on. That is a change under way: hold the window, keep the
            // rebuild owed, and let a poll after the window pick the output.
            noteLifecycleChange(reason: "output-moved")
            systemOutputRecovery.stopped()
            _ = systemOutputIntent.handle(
                .interrupted(monitoringEnabled: systemOutputMonitoringEnabled)
            )
            guard systemOutputMonitoringEnabled else {
                return
            }
            showSystemOutputRebuildOwed()
            reconcileLifecycle()
        }
        systemOutputMeter.onInvalidated = { [weak self] in
            guard let self else {
                return
            }
            // The aggregate device or the tapped output died or reconfigured
            // with the default output unchanged, as across sleep and wake, so
            // no poll would rebuild it. The listener closed its levels and did
            // nothing else; the rebuild waits for the window and its spacing.
            invalidateSystemOutputMeter(reason: "output-invalidated")
            reconcileLifecycle()
        }
        systemOutputMeter.onChangeObserved = { [weak self] in
            guard let self, systemOutputMonitoringEnabled else {
                return
            }
            // The same build's listener fired again: the device is still
            // reconfiguring, as a Bluetooth output switching profile and back
            // does. The rebuild owed for the first notification waits for 3 s
            // after this one, not after the first.
            noteLifecycleChange(reason: "output-invalidated")
        }
        systemOutputMeter.onStopInterrupted = { [weak self] in
            guard let self else {
                return
            }
            // A quiet window armed while the stop was on its way to the HAL.
            // It is issued again, once, after the window, unless monitoring
            // was turned on again meanwhile: the rebuild that is pending, or
            // already issued, then releases what the stop left.
            systemOutputRecovery.stopped()
            _ = systemOutputIntent.handle(
                .stopInterrupted(monitoringEnabled: systemOutputMonitoringEnabled)
            )
            guard !systemOutputMonitoringEnabled else {
                return
            }
            reconcileLifecycle()
        }
        processedMicrophoneEngine.onOutputLevel = { [weak self] rms, peak in
            guard
                let self,
                processedMicrophoneEnabled,
                processedMicrophoneState == .active
            else {
                return
            }
            levels.setMicrophone(rmsDecibels: rms, peakDecibels: peak)
            publishIfChanged(\.microphoneError, nil)
        }
        processedMicrophoneEngine.onStarted = { [weak self] in
            // Reported once the capture's start has returned, so the watch on
            // it ends here.
            if let self {
                processedMicrophoneCaptureReported(token: captureStartToken)
                // The output took the start: its unusable reads are spent,
                // and so are the input's failed reads.
                publisherOutputRetry.startOver()
                captureInputRetry.startOver()
            }
            guard
                let self,
                processedMicrophoneIsWanted,
                processedMicrophoneState == .starting
            else {
                return
            }
            guard !processedMicrophoneEngineIsStale else {
                // The mode or the input moved on after start() was issued.
                // Never report an old configuration as active; the next
                // evaluation rebuilds it with the latest selection.
                reconcileLifecycle()
                return
            }
            processedMicrophoneState = .active
        }
        processedMicrophoneEngine.onError = { [weak self] error in
            self?.reportCaptureStartOnceTheQueueReturns()
            self?.handleProcessedMicrophoneEngineError(error)
        }
        processedMicrophoneEngine.onNeedsRestart = { [weak self] reason in
            guard let self else {
                return
            }
            reportCaptureStartOnceTheQueueReturns()
            if processedMicrophoneState == .active {
                processedMicrophoneState = .starting
            }
            switch reason {
            case .configurationChanged:
                // A configuration change under the engines is a change the
                // HAL is still settling, like a device change: hold the
                // window, and let the evaluation after it rebuild the stale
                // engines.
                noteLifecycleChange(reason: "processing-invalidated")
            case let .outputUnavailable(outputDeviceID):
                // The publisher's output read no usable format: held like a
                // configuration change, and counted, so an output that keeps
                // reading that way ends the retries.
                noteLifecycleChange(reason: "processing-invalidated")
                noteProcessedMicrophoneOutputUnavailable(outputDeviceID)
            case .sourceChanged:
                // Apple voice processing's start saw a default move. Held
                // before anything is released, so its engines stop after the
                // window, and the next start is decided from a fresh poll.
                noteLifecycleChange(reason: "processing-refused")
            case .startInterrupted, .stopInterrupted:
                // Either the window that stopped the start or the stop
                // already holds, or the conditions moved on. The evaluation
                // rebuilds or stops the engines accordingly, after any window.
                break
            }
            reconcileLifecycle()
        }
        processedMicrophoneEngine.startMayProceed = { [weak self] in
            self?.processedMicrophoneStartMayProceed ?? false
        }
        processedMicrophoneDevice.onInUseChanged = { [weak self] inUse in
            self?.handleProcessedMicrophoneInUseChange(inUse)
        }
        systemNotifications.onNotification = { [weak self] notification in
            self?.handleSystemNotification(notification)
        }
        // Each forget is safe off the main thread: the meters take their
        // session lock and hand the rest to their lifecycle queues, and the
        // publication takes the lock its main-thread stop takes. The main
        // thread's recovery forgets again, and then finds nothing.
        systemNotifications.onServiceRestartedOnListenerQueue = {
            [microphoneMeter, systemOutputMeter, processedMicrophoneDevice] in
            microphoneMeter.forgetAfterServiceRestart()
            systemOutputMeter.forgetAfterServiceRestart()
            processedMicrophoneDevice.forgetAfterServiceRestart()
        }
    }

    /// Launch, in the order `LaunchPlan` gives.
    func start() {
        for step in LaunchPlan.steps {
            switch step {
            case .armQuietWindow:
                // A headset connecting as the app launches is still
                // reconfiguring, and the first poll has nothing to compare
                // with. The window armed here holds the first system
                // playback tap, the first meter start and publication until
                // a release, as after any other change.
                noteLifecycleChange(reason: "launch")
            case .listenForSystemNotifications:
                systemNotifications.start()
            case .readDevicesAndControls:
                refreshDevices()
                refreshControls()
            case .checkMicrophonePermission:
                refreshMicrophonePermission(requestIfNeeded: true)
            case .requestSystemOutputMeter:
                if systemOutputMonitoringEnabled {
                    // Held by the launch window: recorded as a pending rebuild.
                    restartSystemOutputMeter()
                }
            case .startPolling:
                cancelRefreshTimer = scheduler.repeating(every: 0.25, tolerance: 0.05) { [weak self] in
                    self?.periodicRefresh()
                }
            }
        }
        // Log only: sleep and wake arm nothing and stop nothing here.
        powerStateLog.start()
    }

    /// Quit was requested. Returns how many seconds Quit's teardown (`stop()`)
    /// waits.
    ///
    /// Polling stops, and from here on every evaluation, picker and toggle
    /// does nothing and every lifecycle start or stop outside the teardown
    /// holds. While the quiet window holds, the teardown waits until 3 s
    /// after the last change it noted, a change carried past its cap
    /// included, and never more than `QuitPlan.deferralMaximum` after this
    /// request, a deadline fixed here; with a default-device write of the
    /// pickers still outstanding, whose change is yet to come, it waits until
    /// that deadline. A generation a listener advanced that the main thread
    /// has not seen arms the window first, as in any evaluation.
    /// `quit-deferred release-in=<s>` records the deferral, and
    /// `remainingQuitDeferral()` reads the window again when it comes due.
    func requestQuit() -> TimeInterval {
        guard !quitRequested else {
            return 0
        }
        let now = lifecycleNow()
        _ = lifecycleAdmission(at: now)
        let deadline = now + QuitPlan.deferralMaximum
        quitDeadline = deadline
        quitRequested = true
        cancelRefreshTimer?()
        cancelRefreshTimer = nil
        return loggedQuitDeferral(now: now, deadline: deadline)
    }

    /// Quit's deferral came due. Returns how many more seconds its teardown
    /// waits: a change the listeners noted during the deferral moves the
    /// window's end, and the teardown waits for it too, never past the
    /// deadline `requestQuit()` fixed. 0 once the teardown may run, and for a
    /// termination that never asked. A further `quit-deferred` line records
    /// each further wait. Nothing here arms the window or reaches the HAL.
    func remainingQuitDeferral() -> TimeInterval {
        guard let quitDeadline else {
            return 0
        }
        return loggedQuitDeferral(now: lifecycleNow(), deadline: quitDeadline)
    }

    private func loggedQuitDeferral(now: TimeInterval, deadline: TimeInterval) -> TimeInterval {
        let deferral = QuitPlan.deferral(
            now: now,
            windowEnd: QuitPlan.windowEnd(
                now: now,
                settleEnd: quietWindow.settleEnd,
                outstandingDefaultWrites: defaultDeviceWrites.count,
                generationUnseen: generationSeenOnMain != lifecycleHoldGeneration.current
            ),
            deadline: deadline
        )
        if deferral > 0 {
            HALLifecycleLog.quitDeferred(releaseIn: deferral)
        }
        return deferral
    }

    /// Quit's teardown. The one lifecycle path the quiet window does not
    /// hold, run after `requestQuit()`'s deferral, or directly by a
    /// termination that did not ask first. Once it begins it does not consult
    /// the window: a window armed now neither delays nor interrupts it.
    ///
    /// The level gates close first, so no IO thread processes anything while
    /// the process exits. The publisher engine stops, and the published
    /// device is withdrawn, synchronously and in that order, as before. The
    /// meters and the IOProc capture then stop and destroy what they hold on
    /// their own lifecycle queues, at `.userInteractive`, and Quit waits for
    /// them while some queue has finished a HAL call within
    /// `QuitPlan.lifecycleStopIdleTimeout`, and for at most
    /// `QuitPlan.lifecycleStopCeiling`: a queue stuck behind a HAL call an
    /// unresponsive coreaudiod never answers must not hang Quit, or the user
    /// reaches for force quit. What an unfinished stop still holds is left
    /// to coreaudiod's cleanup of the exiting client. The order is
    /// `QuitPlan`.
    func stop() {
        quitRequested = true
        cancelRefreshTimer?()
        cancelRefreshTimer = nil
        // Removed on the listener queue; Quit does not wait for it.
        systemNotifications.stop()
        let stops = LifecycleStopGroup()
        for step in QuitPlan.steps {
            switch step {
            case .closeLevelGates:
                microphoneMeter.closeLevelGateAtQuit()
                systemOutputMeter.closeLevelGateAtQuit()
                processedMicrophoneEngine.closeCaptureGateAtQuit()
            case .stopProcessingEngines:
                processedMicrophoneEngine.stopAtQuit(in: stops)
            case .withdrawPublication:
                // A refusal here means a consuming app still holds the
                // published device open. Quitting leaves it behind rather than
                // destroying it under that app, which would take Core Audio
                // down for every process on the machine. The next launch
                // reclaims it once nothing holds it.
                try? processedMicrophoneDevice.stop(reason: HALLifecycleLog.quitReason)
            case .stopMicrophoneMeter:
                microphoneMeter.stopAtQuit(in: stops)
            case .stopSystemOutputMeter:
                systemOutputMeter.stopAtQuit(in: stops)
            case let .waitForLifecycleStops(idleTimeout, ceiling):
                HALLifecycleLog.quitStops(stops.wait(idleTimeout: idleTimeout, ceiling: ceiling))
            }
        }
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID) {
        guard !quitRequested else {
            return
        }
        guard prepareVoiceProcessingForDefaultWrite(picking: deviceID, from: outputDevices, direction: .output) else {
            return
        }
        let previous = outputDeviceID
        let epoch = beginControlWrite()
        // Show the choice immediately. Waiting for the HAL would leave the
        // picker snapped back to the old device for a round trip, which reads
        // as the click not registering.
        outputDeviceID = deviceID
        // Armed on the pick rather than on the write's completion, so no poll
        // in between can rebuild anything for a default that is still moving.
        // The outstanding write keeps the window holding, however long it
        // waits behind a poll on the HAL queue, up to the window's cap.
        defaultDeviceWrites.begin(.output, epoch: epoch)
        noteLifecycleChange(reason: "output-selection")
        hal.setDefaultDevice(deviceID, direction: .output) { [weak self] result in
            guard let self else {
                return
            }
            defaultDeviceWrites.end(.output, epoch: epoch)
            if !result.accepted {
                outputDeviceID = previous
            }
            applyWriteResult(result, direction: .output, epoch: epoch)
            if result.accepted {
                // The default changed when the write took effect, which can
                // be long after the pick: the write waits behind a poll on the
                // HAL queue, and a Bluetooth route can take seconds to accept
                // it. Count the window from here too, so this rebuild is held.
                noteLifecycleChange(reason: "output-selection")
                // Another output: rebuilds that gave up on the previous one
                // start over.
                systemOutputRecovery.startOver()
                restartSystemOutputMeter()
            }
        }
    }

    func selectInputDevice(_ deviceID: AudioDeviceID) {
        guard !quitRequested else {
            return
        }
        guard prepareVoiceProcessingForDefaultWrite(picking: deviceID, from: inputDevices, direction: .input) else {
            return
        }
        let previous = inputDeviceID
        let previousTransportInfo = inputTransportInfo
        let previousOwnership = inputIsProcessedMicrophone
        let epoch = beginControlWrite()
        inputDeviceID = deviceID
        // The picker only offers devices from this list, so the transport is
        // on hand without a HAL read, and the list never contains the app's
        // own published device. Committing both with the ID keeps the meter
        // from judging the new device by the old device's transport. An
        // aggregate's sub-devices are not in the list, so its transport stays
        // unread until the next poll, and the meter does not open it meanwhile.
        let listed = inputDevices.first(where: { $0.id == deviceID })
        publishIfChanged(
            \.inputTransportInfo,
            listed.flatMap {
                $0.transport == .aggregate
                    ? nil
                    : AudioDeviceTransportInfo(transport: $0.transport)
            }
        )
        inputIsProcessedMicrophone = listed == nil ? nil : false
        // Armed before the reconcile below, so the display switches now and
        // the meter moves once the window ends. The outstanding write keeps
        // the window holding up to its cap.
        defaultDeviceWrites.begin(.input, epoch: epoch)
        noteLifecycleChange(reason: "input-selection")
        reconcileLifecycle()
        hal.setDefaultDevice(deviceID, direction: .input) { [weak self] result in
            guard let self else {
                return
            }
            defaultDeviceWrites.end(.input, epoch: epoch)
            if !result.accepted {
                inputDeviceID = previous
                publishIfChanged(\.inputTransportInfo, previousTransportInfo)
                inputIsProcessedMicrophone = previousOwnership
                applyWriteResult(result, direction: .input, epoch: epoch)
                // No later snapshot differs from the rolled-back state, so
                // nothing else would move the meter back.
                reconcileLifecycle()
                return
            }
            applyWriteResult(result, direction: .input, epoch: epoch)
            // Counted again from when the default input actually changed,
            // which can be long after the pick. The meter and the processed
            // microphone follow the new input through the evaluation once the
            // quiet window has ended.
            noteLifecycleChange(reason: "input-selection")
            reconcileLifecycle()
        }
    }

    /// Deals with Apple voice processing before a picker writes a default
    /// device that may involve Bluetooth. Returns whether the pick goes ahead.
    ///
    /// The voice-processing engine follows the default input and output by
    /// itself: after the write it would move its IO onto the picked headset
    /// while the headset reconfigures for it. With no change under way, its
    /// engines are stopped synchronously on the main thread, before the
    /// window is armed and the default written, so the stop comes before
    /// that change and starts nothing. The quiet window does not hold it,
    /// and its lines carry `reason=bluetooth-selection` and `gen=-`. The
    /// evaluation after the window starts processing again if the source is
    /// still allowed, which a connected Bluetooth device does not allow.
    ///
    /// While a change may be under way, that stop could land inside it, so
    /// the pick is refused instead: nothing is stopped or written, `picker
    /// refuse` records it, and the picker goes back to the current default.
    /// The release after the window stops the engines if the source is no
    /// longer allowed; the same pick is then written with nothing to stop.
    /// See `ProcessedMicrophonePlan.beforeDefaultWrite`.
    private func prepareVoiceProcessingForDefaultWrite(
        picking deviceID: AudioDeviceID,
        from devices: [AudioDevice],
        direction: AudioDirection
    ) -> Bool {
        let listed = devices.first { $0.id == deviceID }
        let changeMayBeUnderWay = quietWindow.isArmed
            || quietWindow.hasCarriedChange
            || generationSeenOnMain != lifecycleHoldGeneration.current
            || defaultDeviceWrites.count > 0
            || processedMicrophoneEngine.needsRestart
        switch ProcessedMicrophonePlan.beforeDefaultWrite(
            voiceProcessingEngaged: processedMicrophoneEngine.runsVoiceProcessing,
            pickedTransport: listed?.transport,
            changeMayBeUnderWay: changeMayBeUnderWay,
            bluetoothDevicePresent: bluetoothAudioDevicePresent
        ) {
        case .write:
            return true
        case .stopVoiceProcessingThenWrite:
            // Nothing to wait out for a consumer that has left: the engines
            // are stopping now.
            cancelScheduledProcessingStop()
            stopProcessedMicrophoneEngine(reason: HALLifecycleLog.bluetoothSelectionReason)
            levels.resetMicrophone()
            if processedMicrophoneState == .active {
                processedMicrophoneState = .starting
            }
            return true
        case .refuse:
            HALLifecycleLog.pickerRefused(
                id: deviceID,
                direction: direction == .input ? "input" : "output",
                transport: listed.map { $0.readTransport?.logName ?? "unread" } ?? "-",
                generation: lifecycleHoldGeneration.current
            )
            // The picker has already shown the pick; publishing the unchanged
            // selection puts it back on the current default.
            objectWillChange.send()
            return false
        }
    }

    func setOutputVolume(_ volume: Float) {
        guard !quitRequested else {
            return
        }
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
        guard !quitRequested else {
            return
        }
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
        guard !quitRequested else {
            return
        }
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
        guard !quitRequested else {
            return
        }
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
        guard !quitRequested else {
            return
        }
        systemOutputMonitoringEnabled = enabled
        defaults.set(enabled, forKey: Self.systemOutputMonitoringKey)

        if enabled {
            systemOutputRecovery.startOver()
            restartSystemOutputMeter()
        } else {
            levels.resetSystemOutput()
            systemOutputMonitoringState = .disabled
            systemOutputRecovery.reset()
            stopSystemOutputMeter()
        }
    }

    func setProcessedMicrophoneEnabled(_ enabled: Bool) {
        guard !quitRequested else {
            return
        }
        guard processedMicrophoneEnabled != enabled else {
            return
        }

        processedMicrophoneEnabled = enabled
        defaults.set(enabled, forKey: Self.processedMicrophoneKey)

        if enabled {
            // Stays on and persisted even when the source is refused: the
            // feature starts by itself once the default input is allowed.
            startProcessedMicrophone()
        } else {
            cancelScheduledProcessingStop()
            // The switch-off owes a teardown, which retries that ended must
            // not hold back.
            publisherOutputRetry.startOver()
            captureInputRetry.startOver()
            // Switching it on again publishes like a first time.
            publicationInterruptions.startOver()
            processingStartInFlight = false
            publishWhenMeterStarts = false
            resetPublicationRetry()
            pendingPublicationTeardown = true
            // Shown at once. The engines stop and the publication goes once
            // the quiet window has ended, and the publication not before a
            // consuming app has let go of it.
            processedMicrophoneState = processedMicrophoneDevice.holdsPublication
                && processedMicrophoneInUse
                ? .awaitingRelease
                : .disabled
            reconcileLifecycle()
            restartSystemOutputMeter()
        }
    }

    func setMicrophoneProcessingMode(_ mode: MicrophoneProcessingMode) {
        guard !quitRequested else {
            return
        }
        guard microphoneProcessingMode != mode else {
            return
        }

        microphoneProcessingMode = mode
        microphoneProcessingMessage = nil
        defaults.set(mode.rawValue, forKey: Self.microphoneProcessingModeKey)

        // Running engines in the old mode are stale now, and the mode decides
        // whether a Bluetooth output is refused; the evaluation handles both.
        reconcileLifecycle()
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
        guard !quitRequested else {
            return
        }
        if processedMicrophoneEnabled {
            startProcessedMicrophone()
            return
        }
        guard !lifecycleIsHeld else {
            pendingDisabledRetry = true
            return
        }
        retryDisabledProcessedMicrophoneTeardown()
        reconcileLifecycle()
    }

    /// Retries the teardown of a switched-off processed microphone that
    /// failed, including a device left over from an earlier run. Runs only
    /// while the quiet window is not holding.
    private func retryDisabledProcessedMicrophoneTeardown() {
        let now = lifecycleNow()
        guard !captureCallWatch.isStalled(now: now), !handOffStopWatch.isStalled(now: now) else {
            // The release and the synchronous teardown would queue behind, or
            // wait on, the call that has not come back. The report's
            // evaluation carries the retry out.
            pendingDisabledRetry = true
            return
        }
        pendingDisabledRetry = false
        let result = stopProcessedMicrophoneResources()
        if case .heldBack = result {
            // The retry is carried out by the release after the window.
            pendingDisabledRetry = true
            return
        }
        var staleErrors: [String] = []
        do {
            try processedMicrophoneDevice.removeStalePublishedDevice(holdToken: generationSeenOnMain)
        } catch is PublicProcessedMicrophoneDevice.Interrupted {
            // A window armed before the earlier run's device was destroyed.
            // The retry is carried out by the release after the window.
            pendingDisabledRetry = true
            return
        } catch PublicProcessedMicrophoneDeviceError.publishedDeviceInUse {
            // Someone is using a device left over from an earlier run.
            // Reported through the same waiting state as our own.
            pendingPublicationTeardown = true
            processedMicrophoneInUse = true
            processedMicrophoneState = .awaitingRelease
            return
        } catch {
            staleErrors.append(error.localizedDescription)
        }
        applyDisableResult(result, additionalErrors: staleErrors)
        if case .completed = result, staleErrors.isEmpty {
            // An earlier run's publication, if one was left, is gone now.
            if !reclaimOrphanedTaps(launchCleanup.publicationTeardownCompleted()) {
                // A window armed before a tap's destroy. The retry runs again
                // after it, finds nothing else left, and reclaims the rest.
                pendingDisabledRetry = true
            }
        }
    }

    func retrySystemOutputMonitoring() {
        guard !quitRequested else {
            return
        }
        // A retry by the user starts rebuilds that gave up over.
        systemOutputRecovery.startOver()
        restartSystemOutputMeter()
    }

    /// Retry beside the microphone meter's error, which the panel offers
    /// once the meter gave up on the default input (`microphoneMeterGaveUp`).
    ///
    /// Starts the meter's attempts over and asks for an evaluation. Nothing
    /// here reaches the HAL. The evaluation issues the start as it would any
    /// other: not while the quiet window holds or starts are held, never for
    /// an input the poll refuses, and through the meter's own reads of the
    /// device as it opens it. Like the other Retry buttons, it does not wait
    /// for the spacing the last failure left; a start that fails again is
    /// spaced 2, 4, then 8 s and counted from one.
    ///
    /// It acts only while the meter has given up, which is when its last
    /// start has reported a failure. A start in flight, stalled or not, keeps
    /// its session, and so does a meter that runs or still retries by itself:
    /// the stop the session returns below is not issued, which is right only
    /// while nothing is held or on its way.
    func retryMicrophoneMeter() {
        guard !quitRequested else {
            return
        }
        guard meterSession.retriesExhausted, !meterSession.hasStartInFlight else {
            return
        }
        publishIfChanged(\.microphoneError, nil)
        // A failed start leaves nothing open, so no HAL call is owed here.
        _ = meterSession.handle(.stopRequested)
        reconcileLifecycle()
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
    /// observes them, so only the emission rate depends on this. Whether any
    /// device is open does not. Safe to call repeatedly with the same value.
    func setLevelMetersVisible(_ visible: Bool) {
        guard levelMetersAreVisible != visible else {
            return
        }
        levelMetersAreVisible = visible
        levels.setMetersVisible(visible)
        systemOutputMeter.setDetailedLevelUpdatesEnabled(visible)
    }

    /// Shown while nothing is measured because the default input is a
    /// Bluetooth microphone, or an aggregate with one active.
    var showsBluetoothInputNote: Bool {
        microphonePermission == .authorized
            && microphoneDisplay == .notMeasured(.bluetooth)
    }

    /// Whether the microphone value on screen is a measurement: the meter
    /// running on the default input, or the processed microphone reporting
    /// its own output while it holds the input. Anything else shows `--`,
    /// which is not the same as a measured silence.
    var microphoneLevelIsLive: Bool {
        guard microphonePermission == .authorized else {
            return false
        }
        switch microphoneDisplay {
        case .live:
            return true
        case .notMeasured(.handedOff):
            return processedMicrophoneState == .active
        case .starting, .notMeasured:
            return false
        }
    }

    private func periodicRefresh() {
        guard !quitRequested else {
            return
        }
        refreshCount += 1

        // Core Audio reads happen on the poller's queue and come back to
        // `apply(_:)`. Anything below this call must not touch the HAL.
        issuePoll(wantsDeviceLists: refreshCount % 8 == 0)

        if refreshCount % 8 == 0 {
            refreshMicrophonePermission(requestIfNeeded: false)
            reconcileProcessedMicrophoneProcessing()
        }
    }

    /// Issues one poll, which the worker drops while another is in flight.
    ///
    /// A poll in flight for more than `HALPollWatch.slowAfter` holds the
    /// quiet window once (`poll-slow`): while it waits behind a slow
    /// coreaudiod or a control write, a Bluetooth device arriving or changing
    /// profile would arm nothing, and the window's freshness rule then holds
    /// until a poll issued after that hold has applied. A dropped poll that
    /// asked for the device lists is issued once the poll in flight returns.
    private func issuePoll(wantsDeviceLists: Bool) {
        guard !quitRequested else {
            return
        }
        let issue = hal.poll(
            AudioHALWorker.Request(
                knownOutputDeviceID: outputDeviceID,
                knownInputDeviceID: inputDeviceID,
                wantsDeviceLists: wantsDeviceLists || hal.takeOwedDeviceLists(),
                controlWriteEpoch: controlWriteEpoch,
                issuedAt: lifecycleNow()
            )
        ) { [weak self] snapshot in
            guard let self else {
                return
            }
            apply(snapshot)
            if hal.takeOwedDeviceLists() {
                issuePoll(wantsDeviceLists: true)
            }
        }
        if case .droppedWhileSlow = issue {
            noteLifecycleChange(reason: "poll-slow")
        }
    }

    /// A notification from the HAL system object. The listener has already
    /// advanced the quiet window's generation for one that arms the window.
    /// Nothing here touches the HAL.
    private func handleSystemNotification(_ notification: HALSystemNotification) {
        if let reason = notification.quietWindowReason {
            noteLifecycleChange(reason: reason)
        }
        if notification.resetsHALState {
            recoverFromServiceRestart()
        }
        if notification.requestsPoll {
            // The device list changed. Whether a Bluetooth device arrived or
            // left is for the poll to read, and it arms the window if so.
            issuePoll(wantsDeviceLists: true)
        }
    }

    /// coreaudiod restarted, and the window is already armed for it.
    ///
    /// Every IOProc, tap and aggregate device this process held went with the
    /// old server, and object IDs may have been reissued, so nothing held is
    /// stopped or destroyed: each owner drops its IDs without a HAL call, and
    /// the caches keyed by ID are dropped too. Nothing here starts anything.
    /// The evaluation the window admits rebuilds what is still wanted, from a
    /// poll issued after the window's end.
    private func recoverFromServiceRestart() {
        hal.forgetCachesAfterServiceRestart()
        lastTopology = nil
        polledBluetoothDevices = nil
        microphoneMeter.forgetAfterServiceRestart()
        systemOutputMeter.forgetAfterServiceRestart()
        processedMicrophoneEngine.noteServiceRestarted()
        if captureCallWatch.isOutstanding {
            // A capture start the restart superseded never reports: its
            // session ended with the forget, and no engine callback follows.
            // Watch the capture queue instead, from now. It answers once it
            // has drained, and a queue still blocked in the old server still
            // stalls. No HAL call.
            let token = captureCallWatch.issue(now: lifecycleNow())
            captureStartToken = token
            processedMicrophoneEngine.afterCaptureQueue { [weak self] in
                self?.processedMicrophoneCaptureReported(token: token)
            }
        }
        processedMicrophoneDevice.forgetAfterServiceRestart()
        // A hand-off to the engines belonged to the old server; the
        // evaluation decides again.
        processingStartInFlight = false
        processedMicrophoneInUse = false
        _ = meterSession.handle(.serviceRestarted)
        // Rebuilds that gave up stay given up: a restart is neither a retry
        // nor another output.
        systemOutputRecovery.serviceRestarted()
        levels.resetMicrophone()
        // Held by the window: recorded as a pending rebuild.
        restartSystemOutputMeter()
        reconcileLifecycle()
    }

    /// Publishes one poll result and runs the reactions it triggers.
    ///
    /// The order matters and matches what the synchronous version did on a
    /// single run loop turn: commit every published value first, then react.
    /// The reactions read `outputDeviceID` and `inputDeviceID` back off `self`
    /// rather than taking them as parameters, so they must not run until those
    /// are committed.
    private func apply(_ snapshot: AudioHALWorker.Snapshot) {
        lastAppliedSnapshotIssuedAt = max(
            lastAppliedSnapshotIssuedAt ?? snapshot.issuedAt,
            snapshot.issuedAt
        )

        // A poll issued before a picker's default-device write that has not
        // completed still reads the previous default for that direction.
        // Publishing it would bring the old device back into the picker and
        // ask the system playback meter to rebuild for it just before the
        // default moves, so that direction keeps what the picker set until a
        // poll read after the write.
        let outputIsCurrent = !defaultDeviceWrites.snapshotPredatesOutstandingWrite(
            .output,
            snapshotEpoch: snapshot.controlWriteEpoch
        )
        let inputIsCurrent = !defaultDeviceWrites.snapshotPredatesOutstandingWrite(
            .input,
            snapshotEpoch: snapshot.controlWriteEpoch
        )
        let outputChanged = outputIsCurrent && snapshot.outputDeviceID != outputDeviceID
        // Each ID is published together with the transport and ownership the
        // worker read for that same ID in the same turn, so they are always a
        // coherent pair and the meter never judges one device by another's
        // transport.
        if outputIsCurrent {
            publishIfChanged(\.outputDeviceID, snapshot.outputDeviceID)
            publishIfChanged(\.outputTransportInfo, snapshot.outputTransportInfo)
        }
        if inputIsCurrent {
            publishIfChanged(\.inputDeviceID, snapshot.inputDeviceID)
            publishIfChanged(\.inputTransportInfo, snapshot.inputTransportInfo)
            inputIsProcessedMicrophone = snapshot.inputIsProcessedMicrophone
        }

        // Armed before any reaction below, so a rebuild those reactions ask
        // for is already held.
        let topology = AudioTopology(
            defaultInput: snapshot.inputDeviceID,
            defaultOutput: snapshot.outputDeviceID,
            bluetoothDeviceIDs: snapshot.bluetoothDeviceIDs
        )
        if AudioTopology.armsQuietWindow(previous: lastTopology, current: topology) {
            noteLifecycleChange(
                reason: Self.quietWindowReason(from: lastTopology, to: topology)
            )
        }
        lastTopology = topology
        polledBluetoothDevices = (snapshot.bluetoothDeviceIDs, snapshot.everyDeviceTransportRead)

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

        if outputChanged {
            // Another output: rebuilds that gave up on the previous one start
            // over.
            systemOutputRecovery.startOver()
            restartSystemOutputMeter()
        }
        reconcileLifecycle()
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
        switch microphoneAuthorization.status() {
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
            microphoneAuthorization.requestAccess { [weak self, scheduler] _ in
                scheduler.async {
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
            }
        } else if
            processedMicrophoneEnabled,
            microphonePermission == .denied
                || microphonePermission == .restricted
        {
            haltProcessedMicrophone(.microphoneDenied)
        } else if processedMicrophoneEnabled {
            processedMicrophoneState = .starting
        }
        reconcileLifecycle()
    }

    /// What the microphone meter should be metering right now.
    ///
    /// The decision to open a device takes the device alone, through
    /// `InputOpenPolicy`: whether a panel is showing or the processed
    /// microphone is on has no say in it. The processed microphone only
    /// matters while its own engines hold the input.
    private func microphoneTarget() -> MeterSession.Target {
        guard microphonePermission == .authorized else {
            return .notMeasured(.notAuthorized)
        }
        guard !processingEngaged else {
            return .notMeasured(.handedOff)
        }
        guard inputDeviceID != kAudioObjectUnknown else {
            return .notMeasured(.noDevice)
        }
        switch inputIsProcessedMicrophone {
        case nil:
            return .notMeasured(.transportNotRead)
        case true?:
            // The published device is fed by this app. Opening it here would
            // also make this app look like one of its consumers.
            return .notMeasured(.noDevice)
        case false?:
            return .input(
                deviceID: inputDeviceID,
                decision: InputOpenPolicy.decide(
                    deviceID: inputDeviceID,
                    info: inputTransportInfo
                )
            )
        }
    }

    /// The one place that starts and stops the microphone meter, and that
    /// carries out a system playback rebuild or stop the quiet window held.
    ///
    /// Runs after every poll snapshot, after meter events that change what
    /// the meter holds, and after the user actions and permission changes that
    /// move the target. The meter's own listeners never restart it; they
    /// report, and the next evaluation here decides.
    ///
    /// While the quiet window holds, the display follows the new target and
    /// nothing else happens: the previous meter keeps running with its levels
    /// suppressed. A release that admits stops only stops what no longer
    /// matches and starts nothing. Once starts are admitted, one evaluation
    /// makes at most one meter change and at most one system playback
    /// rebuild or stop.
    private func reconcileLifecycle() {
        // After a Quit request nothing is evaluated; the teardown alone acts.
        guard !quitRequested else {
            return
        }
        // An action taken below never evaluates again from inside this one;
        // a nested request runs as its own evaluation on the next turn.
        guard !isReconciling else {
            scheduler.async { [weak self] in
                self?.reconcileLifecycle()
            }
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        // Before the admission is read, so a meter found silent arms the
        // window this evaluation acts under.
        checkSystemOutputDelivery(now: lifecycleNow())
        let now = lifecycleNow()
        let admission = lifecycleAdmission(at: now)
        let holding = admission == .hold
        let startsHeld = admission != .full
        if admission == .full {
            // No change the app knows of can be under way now, so the
            // processed microphone's engines stopped since the last such
            // evaluation are freed, before this one stops or builds more. An
            // engine's configuration-change observer arms the window before
            // it evaluates, so this never runs inside that notification.
            processedMicrophoneEngine.releaseRetiredEngines()
        }
        // A call that has not come back is noticed while the window holds
        // too, before any step can issue more behind it.
        noteLifecycleCallStalls(now: now)
        // An armed window that no longer holds has ended: settled, forced by
        // its 15 s cap, or with a change carried past that cap. The plan notes
        // its release first and takes it last, once this evaluation has acted,
        // so every step sees the window released, and a carried change starts
        // the next window after this one evaluation rather than before it.
        // Taking it does not advance the generation, so the release's own
        // stops are not interrupted by the window that follows.
        for step in EvaluationPlan.steps(
            admission: admission,
            windowArmed: quietWindow.isArmed,
            launchCleanupOwed: launchCleanup.isOwed
        ) {
            switch step {
            case .cleanUpAfterEarlierRun:
                switch cleanUpAfterEarlierRun() {
                case .finished:
                    break
                case .destroyedEarlierDevice:
                    // The earlier run's published device is gone. If it was
                    // the default input, coreaudiod is reassigning the
                    // default, possibly to a headset microphone, as this
                    // evaluation would start the system playback tap and the
                    // meter. Nothing more is issued: the window re-armed
                    // here holds them, and its release acts from a poll
                    // issued after it.
                    noteLifecycleChange(reason: "launch-cleanup")
                    publishLifecycleCallStallMessages(now: now)
                    return
                case .heldBack:
                    // A listener advanced the generation after this
                    // evaluation read its admission, and the cleanup stopped
                    // before its next destroy. It is still owed, so starts
                    // stay held, and this evaluation issues nothing more: the
                    // release after the window that listener's change arms
                    // runs the cleanup again.
                    publishLifecycleCallStallMessages(now: now)
                    return
                }
            case .noteRelease:
                HALLifecycleLog.quietWindowRelease(
                    admission,
                    generation: lifecycleHoldGeneration.current,
                    snapshotAge: lastAppliedSnapshotIssuedAt.map { now - $0 },
                    writesOutstanding: defaultDeviceWrites.count,
                    pollInFlight: hal.isPollInFlight
                )
            case .updateProcessedMicrophoneState:
                updateProcessedMicrophoneState()
            case .retryDisabledProcessedMicrophoneTeardown:
                if pendingDisabledRetry, !processedMicrophoneEnabled {
                    retryDisabledProcessedMicrophoneTeardown()
                }
            case .performProcessedMicrophonePlan:
                performProcessedMicrophonePlan(holding: holding, startsHeld: startsHeld)
            case .evaluateMicrophoneMeter:
                evaluateMicrophoneMeter(holding: holding, startsHeld: startsHeld, now: now)
            case .publishMicrophoneDisplay:
                publishMicrophoneDisplay()
            case .publishProcessedMicrophone:
                publishProcessedMicrophoneIfMeterRunning(now: now)
            case .applySystemOutputIntent:
                applyPendingSystemOutputChange(startsHeld: startsHeld)
            case .takeRelease:
                if quietWindow.takeRelease(at: now), let releaseTime = quietWindow.releaseTime {
                    // A change carried past the cap, or the rest of the settle
                    // period a cap-forced release cut short, holds from here.
                    // Written after the steps this release issued
                    // synchronously. What they do on the lifecycle queues can
                    // be logged after this line; it carries this release's
                    // generation, which the line repeats.
                    HALLifecycleLog.quietWindowHold(
                        reason: "carried",
                        releaseIn: max(0, releaseTime - now),
                        generation: lifecycleHoldGeneration.current
                    )
                }
            }
        }
        publishLifecycleCallStallMessages(now: now)
    }

    /// Logs, once each, a system playback meter start or stop, a processed
    /// microphone capture start or release, or a hand-off stop that has gone
    /// `LifecycleCallWatch.timeout` without coming back. Its queue is most
    /// likely waiting in an unresponsive coreaudiod. Until it comes back,
    /// nothing further is issued to that queue: the system playback rebuild
    /// or stop stays pending, the processed microphone's plan takes no step,
    /// and during a hand-off the microphone meter is not started.
    private func noteLifecycleCallStalls(now: TimeInterval) {
        if systemOutputCallWatch.noteStall(now: now) {
            HALLifecycleLog.record(
                .systemOutputTap,
                .stall,
                id: AudioObjectID(kAudioObjectUnknown),
                transport: AudioDeviceTransportInfo.logDescription(outputTransportInfo),
                generation: lifecycleHoldGeneration.current
            )
        }
        if captureCallWatch.noteStall(now: now) {
            HALLifecycleLog.record(
                .processedMicrophoneCaptureIOProc,
                .stall,
                id: processedMicrophoneEngine.configuration.inputDeviceID,
                generation: lifecycleHoldGeneration.current
            )
        }
        if handOffStopWatch.noteStall(now: now) {
            HALLifecycleLog.record(
                .microphoneIOProc,
                .stall,
                id: handOffStopDeviceID,
                generation: lifecycleHoldGeneration.current,
                reason: HALLifecycleLog.handOffReason
            )
        }
    }

    /// Shows the Core Audio error for every stalled call, after the steps,
    /// so a step that republishes a state does not hide it.
    private func publishLifecycleCallStallMessages(now: TimeInterval) {
        if systemOutputCallWatch.isStalled(now: now), systemOutputMonitoringEnabled {
            publishIfChanged(\.systemOutputMonitoringState, .failed(Self.systemOutputStallMessage))
        }
        if captureCallWatch.isStalled(now: now) || handOffStopWatch.isStalled(now: now) {
            publishIfChanged(\.microphoneError, Self.processedMicrophoneStallMessage)
        }
    }

    private static var systemOutputStallMessage: String {
        localized("Core Audio has not finished starting or stopping system playback level monitoring. If other audio apps have stopped responding too, Core Audio itself is not answering, and only restarting the Mac recovers it.")
    }

    private static var processedMicrophoneStallMessage: String {
        localized("Core Audio has not finished starting or stopping the processed microphone. If other audio apps have stopped responding too, Core Audio itself is not answering, and only restarting the Mac recovers it.")
    }

    private var systemOutputCallIsStalled: Bool {
        systemOutputCallWatch.isStalled(now: lifecycleNow())
    }

    /// Main thread, no HAL work. Whether the running system playback meter
    /// still delivers levels. A silent output still delivers levels of
    /// -inf dB, so only levels that stop arriving count: after
    /// `SystemOutputRecovery.staleDisplayAfter` the meter shows starting,
    /// and after `rebuildAfterSilence` it is invalidated like a listener
    /// report, and rebuilt after the window.
    ///
    /// Levels reach the main thread through queued blocks, so a main thread
    /// that spent seconds in a synchronous HAL call can find no level while
    /// the IO thread's levels still wait behind it. The verdict is therefore
    /// confirmed on a later main-queue turn, after every block queued before
    /// it has run: a level among them cancels it.
    private func checkSystemOutputDelivery(now: TimeInterval) {
        guard systemOutputDeliveryIsWatched else {
            return
        }
        switch systemOutputRecovery.check(at: now) {
        case .none:
            break
        case .showStale:
            levels.resetSystemOutput()
            publishIfChanged(\.systemOutputMonitoringState, .starting)
        case .rebuild:
            guard !systemOutputStaleConfirmationQueued else {
                return
            }
            systemOutputStaleConfirmationQueued = true
            scheduler.async { [weak self] in
                self?.confirmSystemOutputStale()
            }
        }
    }

    private var systemOutputDeliveryIsWatched: Bool {
        systemOutputMonitoringEnabled
            && systemOutputIntent.pending == nil
            && !systemOutputCallWatch.isOutstanding
    }

    /// A later main-queue turn than the check that found no level for
    /// `rebuildAfterSilence`. Invalidates the meter only if that still holds.
    private func confirmSystemOutputStale() {
        systemOutputStaleConfirmationQueued = false
        guard
            systemOutputDeliveryIsWatched,
            systemOutputRecovery.check(at: lifecycleNow()) == .rebuild
        else {
            return
        }
        invalidateSystemOutputMeter(reason: "output-stale")
        reconcileLifecycle()
    }

    /// The system playback meter was invalidated: its listener reported, or
    /// its levels stopped arriving. Arms the window and owes one rebuild,
    /// spaced by `SystemOutputRecovery`. Nothing is stopped here.
    ///
    /// At `SystemOutputRecovery.maximumConsecutiveInvalidations` in a row the
    /// rebuilds give up: the rebuild stays owed and is never due, so the
    /// meter's callbacks stay ignored and neither a rebuild nor a stop is
    /// issued, and the meter shows failed with Retry. What the last build
    /// holds stays until Retry, monitoring switched off or on, or an output
    /// change.
    private func invalidateSystemOutputMeter(reason: String) {
        noteLifecycleChange(reason: reason)
        let wasExhausted = systemOutputRecovery.rebuildsExhausted
        systemOutputRecovery.invalidated(at: lifecycleNow())
        _ = systemOutputIntent.handle(
            .invalidated(monitoringEnabled: systemOutputMonitoringEnabled)
        )
        guard systemOutputMonitoringEnabled else {
            return
        }
        if systemOutputRecovery.rebuildsExhausted, !wasExhausted {
            HALLifecycleLog.record(
                .systemOutputTap,
                .giveUp,
                id: 0,
                generation: lifecycleHoldGeneration.current,
                output: outputDeviceID
            )
        }
        showSystemOutputRebuildOwed()
    }

    /// Shows the system playback meter waiting for the rebuild it is owed,
    /// or, once its rebuilds gave up, failed with Retry.
    private func showSystemOutputRebuildOwed() {
        levels.resetSystemOutput()
        publishIfChanged(
            \.systemOutputMonitoringState,
            systemOutputRecovery.rebuildsExhausted
                ? .failed(Self.systemOutputRebuildsExhaustedMessage)
                : .starting
        )
    }

    private static var systemOutputRebuildsExhaustedMessage: String {
        localized("System playback level monitoring stopped because the output kept stopping or reconfiguring. Choose Retry to start it again. It also starts again when the output device changes.")
    }

    /// Issues a system playback meter start or stop and watches its lifecycle
    /// queue until it has come back from it.
    private func issueSystemOutputMeterCall(_ call: () -> Void) {
        let token = systemOutputCallWatch.issue(now: lifecycleNow())
        call()
        systemOutputMeter.afterLifecycleQueue { [weak self] in
            self?.systemOutputMeterCallReturned(token: token)
        }
    }

    private func systemOutputMeterCallReturned(token: UInt64) {
        let stallWasNoted = systemOutputCallWatch.stallNoted
        systemOutputCallWatch.report(token: token)
        guard stallWasNoted, !systemOutputCallWatch.isOutstanding else {
            return
        }
        // The queue answered again. Whatever the rebuild or stop left pending
        // is carried out by the evaluation.
        if systemOutputMonitoringState == .failed(Self.systemOutputStallMessage) {
            if systemOutputMonitoringEnabled {
                showSystemOutputRebuildOwed()
            } else {
                systemOutputMonitoringState = .disabled
            }
        }
        reconcileLifecycle()
    }

    /// Stops the processing engines and watches the capture queue until it
    /// has come back from the release, and from anything issued before it.
    ///
    /// A stop an evaluation issues carries the generation the main thread
    /// has seen, as the meters' stops do, not the one current now: a listener
    /// may have advanced it since this evaluation read its admission, and the
    /// stop then ends before its first HAL call, the engines' stops on the
    /// main thread included. What it would have stopped stays, counted as
    /// running with a restart owed, and the plan stops it after the window.
    ///
    /// - Parameter reason: `bluetooth-selection` for the picker's stop before
    ///   a default write, which the quiet window does not hold and which is
    ///   not compared; nil for a stop the evaluation issues.
    /// - Returns: False when the engines' stop was held back. The publisher
    ///   may still render, so nothing that stop was to make safe, such as
    ///   withdrawing the muted tap, may follow it.
    @discardableResult
    private func stopProcessedMicrophoneEngine(reason: String? = nil) -> Bool {
        let token = captureCallWatch.issue(now: lifecycleNow())
        let stopped = processedMicrophoneEngine.stop(
            reason: reason,
            holdToken: HALLifecycleLog.isUnheldStopReason(reason) ? nil : generationSeenOnMain
        )
        processedMicrophoneEngine.afterCaptureQueue { [weak self] in
            self?.processedMicrophoneCaptureReported(token: token)
        }
        return stopped
    }

    /// An error or a restart request may reach the owner while the capture's
    /// start still waits on its queue, as a configuration change under the
    /// publisher does. Neither is the start's own outcome, so the watch on
    /// the start ends only once the capture queue has come back from it.
    private func reportCaptureStartOnceTheQueueReturns() {
        let token = captureStartToken
        processedMicrophoneEngine.afterCaptureQueue { [weak self] in
            self?.processedMicrophoneCaptureReported(token: token)
        }
    }

    /// The processed microphone's start reported, or the capture queue came
    /// back from the call issued with `token`. A token a later call replaced
    /// is ignored.
    private func processedMicrophoneCaptureReported(token: UInt64) {
        let stallWasNoted = captureCallWatch.stallNoted
        captureCallWatch.report(token: token)
        guard stallWasNoted, !captureCallWatch.isOutstanding else {
            return
        }
        clearProcessedMicrophoneStallMessage()
        reconcileLifecycle()
    }

    /// The hand-off stop completed. True when it had been noted as stalled.
    private func handOffStopReported(token: UInt64) -> Bool {
        let stallWasNoted = handOffStopWatch.stallNoted
        handOffStopWatch.report(token: token)
        guard stallWasNoted, !handOffStopWatch.isOutstanding else {
            return false
        }
        clearProcessedMicrophoneStallMessage()
        return true
    }

    private func clearProcessedMicrophoneStallMessage() {
        let now = lifecycleNow()
        guard
            microphoneError == Self.processedMicrophoneStallMessage,
            !captureCallWatch.isStalled(now: now),
            !handOffStopWatch.isStalled(now: now)
        else {
            return
        }
        publishIfChanged(\.microphoneError, nil)
    }

    /// The evaluation's meter step: starts or stops the microphone meter as
    /// `MeterSession` decides, and reports a stalled start.
    private func evaluateMicrophoneMeter(holding: Bool, startsHeld: Bool, now: TimeInterval) {
        let target = microphoneTarget()
        if meterSession.target != target {
            publishIfChanged(\.microphoneError, nil)
        }
        let wasStalled = meterSession.isStalled
        // A hand-off stop that has not come back holds the meter's queue:
        // a start issued now would only wait behind it.
        let heldByHandOff = handOffStopWatch.isStalled(now: now)
        switch meterSession.handle(
            .evaluate(
                target: target,
                holding: holding || heldByHandOff,
                startsHeld: startsHeld || heldByHandOff,
                now: now
            )
        ) {
        case .start(let deviceID)?:
            levels.resetMicrophone()
            microphoneMeter.start(deviceID: deviceID, holdToken: generationSeenOnMain)
        case .stop?:
            levels.resetMicrophone()
            microphoneMeter.stop(holdToken: generationSeenOnMain)
        case nil:
            break
        }
        if case .stalled(let deviceID) = meterSession.phase {
            // The meter's lifecycle queue has not come back from a start,
            // most likely because coreaudiod is not answering. Say so, and
            // issue nothing more for the meter until that start reports:
            // a teardown sent to an unresponsive server only waits there too.
            if !wasStalled {
                HALLifecycleLog.record(
                    .microphoneIOProc,
                    .stall,
                    id: deviceID,
                    generation: lifecycleHoldGeneration.current
                )
            }
            publishIfChanged(\.microphoneError, Self.microphoneStallMessage)
        }
    }

    private static var microphoneTransportUnreadMessage: String {
        localized("The input device’s connection type could not be read, so the microphone level meter could not start.")
    }

    /// A publication waiting for the meter to run cannot go ahead once the
    /// meter has given up on the input; it halts with `message`, owing its
    /// teardown, which waits for the quiet window. No HAL call here.
    private func haltProcessedMicrophoneIfTheMeterGaveUp(_ message: String) {
        guard
            publishWhenMeterStarts,
            processedMicrophoneIsWanted,
            meterSession.retriesExhausted
        else {
            return
        }
        haltProcessedMicrophone(.failed(message))
    }

    private static var microphoneStallMessage: String {
        localized("Core Audio has not finished starting the microphone level meter. If other audio apps have stopped responding too, Core Audio itself is not answering, and only restarting the Mac recovers it.")
    }

    /// The stall message says Core Audio has not answered a start. Once that
    /// start has reported, whatever it reported, the message no longer holds;
    /// a failure publishes its own.
    private func clearMicrophoneStallMessageOnceTheStartReported() {
        guard microphoneError == Self.microphoneStallMessage, !meterSession.isStalled else {
            return
        }
        publishIfChanged(\.microphoneError, nil)
    }

    /// Arms the quiet window, or re-arms it while it holds. `reason` is a fixed
    /// word for the log.
    private func noteLifecycleChange(reason: String) {
        let now = lifecycleNow()
        quietWindow.noteChange(at: now)
        lifecycleHoldGeneration.advance()
        generationSeenOnMain = lifecycleHoldGeneration.current
        HALLifecycleLog.quietWindowHold(
            reason: reason,
            releaseIn: max(0, (quietWindow.releaseTime ?? now) - now),
            generation: lifecycleHoldGeneration.current
        )
    }

    /// What the quiet window admits now. See
    /// `LifecycleQuietWindow.admission(at:freshestSnapshotIssuedAt:outstandingDefaultWrites:)`.
    ///
    /// A generation a listener advanced on its own queue, whose report has
    /// not reached the main thread yet, holds: this arms the window for it
    /// at once (`generation-advanced`), so nothing is admitted with the
    /// advanced generation before the window is armed. The report arms it
    /// again when it arrives. After a Quit request everything holds.
    private func lifecycleAdmission(at now: TimeInterval) -> LifecycleQuietWindow.Admission {
        // After a Quit request only the teardown acts, and it does not ask.
        guard !quitRequested else {
            return .hold
        }
        let admission = LifecycleQuietWindow.admission(
            quietWindow.admission(
                at: now,
                freshestSnapshotIssuedAt: lastAppliedSnapshotIssuedAt,
                outstandingDefaultWrites: defaultDeviceWrites.count
            ),
            generationSeenByOwner: generationSeenOnMain,
            currentGeneration: lifecycleHoldGeneration.current
        )
        if generationSeenOnMain != lifecycleHoldGeneration.current {
            noteLifecycleChange(reason: "generation-advanced")
        }
        return admission
    }

    /// Whether the quiet window holds every lifecycle change, stops too.
    private var lifecycleIsHeld: Bool {
        lifecycleAdmission(at: lifecycleNow()) == .hold
    }

    /// Whether starts are held: the window holds, a release is due that
    /// admits stops only, or the launch cleanup has not run yet. The cleanup
    /// runs first in the first evaluation that admits starts, so nothing this
    /// run builds before it can be taken for an earlier run's leftover.
    private var lifecycleStartsHeld: Bool {
        launchCleanup.holdsStarts(admission: lifecycleAdmission(at: lifecycleNow()))
    }

    /// How the launch cleanup went.
    private enum EarlierRunCleanup {
        case finished
        /// It destroyed the published device an earlier run left behind.
        /// That evaluation issues nothing more and holds the window again.
        case destroyedEarlierDevice
        /// A quiet window armed before one of its destroys, and nothing was
        /// destroyed from there on. The cleanup is still owed, and that
        /// evaluation issues nothing more.
        case heldBack
    }

    /// The launch cleanup, run from the first evaluation after launch that
    /// admits starts, before anything else it issues. See `LaunchCleanup`.
    ///
    /// Its destroys, the earlier run's published device and then the
    /// orphaned taps, follow reads of the device list and of every tap and
    /// aggregate device, which can wait in coreaudiod while a change begins.
    /// So they carry the generation this evaluation saw and are compared
    /// immediately before each call, like everything else an evaluation
    /// issues. Held back, the cleanup stays owed, or is owed again, and the
    /// release after the window runs it again.
    private func cleanUpAfterEarlierRun() -> EarlierRunCleanup {
        let outcome: LaunchCleanup.StaleRemoval
        var destroyedDevice = false
        do {
            // This instance owns no route yet, whatever the saved opt-in.
            destroyedDevice = try processedMicrophoneDevice.removeStalePublishedDevice(
                reason: "launch",
                holdToken: generationSeenOnMain
            )
            outcome = .completed
        } catch is PublicProcessedMicrophoneDevice.Interrupted {
            // Nothing was destroyed, and no outcome is reported: the cleanup
            // stays owed.
            return .heldBack
        } catch PublicProcessedMicrophoneDeviceError.publishedDeviceInUse {
            // A consuming app still records from a device an earlier run
            // published, and its tap is that device's only input, so neither
            // is touched. The device is watched, and the teardown owed for it
            // completes, reclaiming the tap, once the app lets go of it.
            processedMicrophoneInUse = true
            if processedMicrophoneEnabled {
                haltProcessedMicrophone(
                    .failed(
                        localized(
                            "Could not shut down the earlier processed microphone: %@",
                            PublicProcessedMicrophoneDeviceError.publishedDeviceInUse.localizedDescription
                        )
                    )
                )
            } else {
                pendingPublicationTeardown = true
                processedMicrophoneState = .awaitingRelease
            }
            outcome = .inUse
        } catch {
            processedMicrophoneState = .failed(
                localized("Could not shut down the earlier processed microphone: %@", error.localizedDescription)
            )
            outcome = .failed
        }
        let reclaimed = reclaimOrphanedTaps(launchCleanup.staleRemovalFinished(outcome))
        if destroyedDevice {
            return .destroyedEarlierDevice
        }
        return reclaimed ? .finished : .heldBack
    }

    /// Reclaims an earlier run's orphaned process taps when the launch
    /// cleanup says so, synchronously on the main thread. Each destroy
    /// carries the generation the evaluation saw and is compared against it
    /// first.
    ///
    /// - Returns: False when a quiet window armed before one of the destroys.
    ///   The taps left are owed again (`LaunchCleanup.reclaimInterrupted`).
    @discardableResult
    private func reclaimOrphanedTaps(_ action: LaunchCleanup.Action) -> Bool {
        guard case let .reclaim(scope) = action else {
            return true
        }
        let issuedIn = generationSeenOnMain
        let outcome = OrphanedProcessTapReclaimer.reclaim(
            scope: scope,
            reason: "launch",
            generation: issuedIn,
            mayDestroy: { [lifecycleHoldGeneration] in lifecycleHoldGeneration.isCurrent(issuedIn) },
            halCalls: lifecycleCalls,
            inventory: tapReclaimInventory
        )
        guard outcome.interruptedUIDs.isEmpty else {
            launchCleanup.reclaimInterrupted(scope)
            return false
        }
        return true
    }

    /// The one clock for the quiet window, the meter session's stall timeout,
    /// the lifecycle call watches, the publication retry, and the HAL
    /// worker's poll watch and log timings, which receive it.
    ///
    /// It must not count time asleep. A window armed before a sleep has to
    /// keep the rest of its settle period after the wake, and a start in
    /// flight across a sleep must not count the sleep toward its stall
    /// timeout. The app's is `ProcessInfo.processInfo.systemUptime`
    /// (`Dependencies.live()`).
    private func lifecycleNow() -> TimeInterval {
        clock()
    }

    /// The queues the HAL worker, the meters, the capture and the system
    /// notifications run their Core Audio work on.
    struct LifecycleQueues {
        let halWorker: DispatchQueue
        let microphoneMeter: DispatchQueue
        let systemOutputMeter: DispatchQueue
        let processedMicrophoneCapture: DispatchQueue
        let systemNotifications: DispatchQueue

        var all: [DispatchQueue] {
            [halWorker, microphoneMeter, systemOutputMeter, processedMicrophoneCapture, systemNotifications]
        }
    }

    /// Tests only, so that a test can wait until each queue has run what was
    /// issued to it.
    /// Tests only.
    var processedMicrophoneEngineForTesting: ProcessedMicrophoneEngine {
        processedMicrophoneEngine
    }

    var lifecycleQueuesForTesting: LifecycleQueues {
        LifecycleQueues(
            halWorker: hal.queue,
            microphoneMeter: microphoneMeter.lifecycleQueue,
            systemOutputMeter: systemOutputMeter.lifecycleQueue,
            processedMicrophoneCapture: processedMicrophoneEngine.captureQueue,
            systemNotifications: systemNotifications.listenerQueue
        )
    }

    private static func quietWindowReason(
        from previous: AudioTopology?,
        to current: AudioTopology
    ) -> String {
        guard let previous else {
            return "topology"
        }
        var reasons: [String] = []
        if previous.defaultInput != current.defaultInput {
            reasons.append("default-input")
        }
        if previous.defaultOutput != current.defaultOutput {
            reasons.append("default-output")
        }
        if previous.bluetoothDeviceIDs != current.bluetoothDeviceIDs {
            reasons.append("bluetooth-devices")
        }
        return reasons.joined(separator: ",")
    }

    /// Publishes what the panel shows of the meter's session: its display,
    /// and whether it gave up, which offers Retry.
    private func publishMicrophoneDisplay() {
        let display = meterSession.display
        if microphoneDisplay == .live, display != .live {
            levels.resetMicrophone()
        }
        publishIfChanged(\.microphoneDisplay, display)
        publishIfChanged(\.microphoneMeterGaveUp, meterSession.retriesExhausted)
    }

    /// The failed start or refusal just handled was the last `MeterSession`
    /// allows on `deviceID`: it issues no further start for that input until
    /// Retry, another input, a start of the processed microphone, which
    /// needs the meter, or a coreaudiod restart starts the count over.
    /// `microphone-ioproc give-up` is written once, with the transport class
    /// the poll shows for the input. That start released what it created
    /// before it reported, so nothing is left open. No HAL call.
    private func noteMicrophoneMeterGaveUp(on deviceID: AudioDeviceID, wasExhausted: Bool) {
        guard meterSession.retriesExhausted, !wasExhausted else {
            return
        }
        HALLifecycleLog.record(
            .microphoneIOProc,
            .giveUp,
            id: deviceID,
            transport: deviceID == inputDeviceID
                ? AudioDeviceTransportInfo.logDescription(inputTransportInfo)
                : "unread",
            generation: lifecycleHoldGeneration.current
        )
    }

    private func handleMicrophoneMeterEvent(_ event: MicrophoneMeter.Event) {
        let now = lifecycleNow()
        switch event {
        case .started(let deviceID):
            _ = meterSession.handle(.started(deviceID, now: now))
            if meterSession.phase == .running(deviceID) {
                publishIfChanged(\.microphoneError, nil)
            }
            if case .invalidated(deviceID, _) = meterSession.phase {
                // An invalidation that arrived while the start was on its way
                // applies now. The window armed for it may be long over, as
                // after a stall, so the restart waits for a quiet period and
                // a fresh poll from here too, not only its delay.
                noteLifecycleChange(reason: "meter-invalidated")
            }
            clearMicrophoneStallMessageOnceTheStartReported()
            reconcileLifecycle()

        case let .failed(deviceID, error):
            let wasExhausted = meterSession.retriesExhausted
            _ = meterSession.handle(.startFailed(deviceID, now: now))
            guard case .failed(deviceID, _, _) = meterSession.phase else {
                return
            }
            microphoneError = error.localizedDescription
            noteMicrophoneMeterGaveUp(on: deviceID, wasExhausted: wasExhausted)
            haltProcessedMicrophoneIfTheMeterGaveUp(error.localizedDescription)
            publishMicrophoneDisplay()

        case let .refused(deviceID, refusal):
            let wasExhausted = meterSession.retriesExhausted
            _ = meterSession.handle(.refusedAtStart(deviceID, refusal, now: now))
            if case .failed(deviceID, _, _) = meterSession.phase {
                // The transport could not be read as the device was opened.
                // MeterSession retries after its delay; the window makes the
                // retry wait for a quiet period and a fresh poll too, not
                // only the delay.
                noteLifecycleChange(reason: "meter-refused")
                if meterSession.retriesExhausted {
                    // It gave up, as after failed starts: say so, and do not
                    // leave a publication waiting for a meter that will not
                    // start. Earlier refusals show nothing.
                    microphoneError = Self.microphoneTransportUnreadMessage
                    noteMicrophoneMeterGaveUp(on: deviceID, wasExhausted: wasExhausted)
                    haltProcessedMicrophoneIfTheMeterGaveUp(Self.microphoneTransportUnreadMessage)
                }
            }
            clearMicrophoneStallMessageOnceTheStartReported()
            publishMicrophoneDisplay()

        case .invalidated(let deviceID):
            // No restart here. The device reconfigured under the meter, which
            // is itself a change coreaudiod is still settling, so it holds the
            // quiet window like a device change; the evaluation after the
            // window decides. MeterSession also spaces the restarts of a
            // device that keeps reconfiguring by itself, so it is never
            // reopened on every poll even without the window.
            // An invalidation for a start that has not reported back waits
            // for that start; the window holds meanwhile all the same.
            _ = meterSession.handle(.invalidated(deviceID, now: now))
            let invalidationAccepted: Bool
            if case .invalidated(deviceID, _) = meterSession.phase {
                invalidationAccepted = true
            } else {
                invalidationAccepted = meterSession.hasPendingInvalidation
            }
            if invalidationAccepted {
                noteLifecycleChange(reason: "meter-invalidated")
            }
            publishMicrophoneDisplay()

        case .interrupted(let deviceID):
            // A quiet window armed while the start was on its way to the HAL.
            // The evaluation after the window starts it again, or stops what
            // it left.
            _ = meterSession.handle(.startInterrupted(deviceID))
            clearMicrophoneStallMessageOnceTheStartReported()
            publishMicrophoneDisplay()

        case .stopInterrupted:
            // A quiet window armed while the stop was on its way to the HAL.
            // The evaluation after the window stops the meter again, or
            // starts it on the target, which releases it first.
            _ = meterSession.handle(.stopInterrupted)
            publishMicrophoneDisplay()
            reconcileLifecycle()
        }
    }

    // MARK: Processed microphone lifecycle
    //
    // Events — the user's switches, the in-use listener, engine callbacks, and
    // polls that move the default devices — only record what changed and ask
    // for an evaluation. Every step that creates, starts, stops or destroys a
    // HAL resource for the processed microphone is taken by
    // `performProcessedMicrophonePlan(holding:)` or by publication, both of
    // which wait for the quiet window. Quit is the one exception.

    /// Switched on, permitted, and not halted by a failure the user retries.
    private var processedMicrophoneIsWanted: Bool {
        processedMicrophoneEnabled
            && microphonePermission == .authorized
            && !processedMicrophoneState.isHalted
    }

    /// The processing engines hold the input, or are about to. The meter
    /// stays stopped meanwhile: both open the same physical input, and voice
    /// processing gets a broken or silent input if the meter still holds it.
    private var processingEngaged: Bool {
        processingStartInFlight || processedMicrophoneEngine.isRunning
    }

    /// Apple voice processing is by far the most expensive part of this app,
    /// and it produces audio nobody reads while no app has the published
    /// device open. Without the in-use signal, fall back to running it
    /// unconditionally rather than publishing silence.
    private var processedMicrophoneProcessingWanted: Bool {
        !processedMicrophoneDevice.isMonitoringInUse
            || processedMicrophoneInUse
            || scheduledProcessingStop != nil
    }

    /// Running engines that capture another input or run another mode than
    /// the current one, that run Apple voice processing against another
    /// output, that asked to be rebuilt, or, in every mode, whose publisher
    /// is bound to an output the poll now shows gone, involving Bluetooth, or
    /// an aggregate device that is no longer the default output. See
    /// `ProcessedMicrophoneEngineStaleness`.
    private var processedMicrophoneEngineIsStale: Bool {
        let configuration = processedMicrophoneEngine.configuration
        return ProcessedMicrophoneEngineStaleness.isStale(
            running: processedMicrophoneEngine.isRunning,
            needsRestart: processedMicrophoneEngine.needsRestart,
            modeChanged: configuration.processingMode != microphoneProcessingMode,
            inputChanged: configuration.inputDeviceID != inputDeviceID,
            runsVoiceProcessing: configuration.processingMode == .apple,
            outputChanged: configuration.outputDeviceID != outputDeviceID,
            boundPublisherOutputID: processedMicrophoneEngine.publisherOutputDeviceID,
            survey: publisherOutputSurvey
        )
    }

    /// The output devices and the default output as the poll shows them, for
    /// the publisher engine's output. An empty device list counts as unread:
    /// it is what a failed list read leaves.
    private var publisherOutputSurvey: PublisherOutputSurvey {
        PublisherOutputSurvey(
            listed: outputDevices.isEmpty ? nil : outputDevices.map { device in
                ListedOutputDevice(
                    deviceID: device.id,
                    transport: device.readTransport,
                    hasOutputChannels: device.hasOutput
                )
            },
            defaultOutputID: outputDeviceID,
            defaultOutput: outputTransportInfo
        )
    }

    /// Whether a processing start already issued may take its next HAL step:
    /// still wanted, with starts admitted by the quiet window, published, from
    /// an allowed source, and for the input and mode it was started with.
    private var processedMicrophoneStartMayProceed: Bool {
        processedMicrophoneIsWanted
            && !lifecycleStartsHeld
            && processedMicrophoneDevice.holdsPublication
            && processedMicrophoneSourceDecision() == .allowed
            && !processedMicrophoneEngineIsStale
    }

    /// Whether the processed microphone may capture from the default input,
    /// and render to an output its publisher may be bound to, from what the
    /// poll read.
    private func processedMicrophoneSourceDecision() -> ProcessedMicrophoneSourceDecision {
        let decision = ProcessedMicrophoneSourcePolicy.decide(
            usesVoiceProcessing: microphoneProcessingMode == .apple,
            inputDeviceID: inputDeviceID,
            input: inputTransportInfo,
            output: outputTransportInfo,
            bluetoothDevicePresent: bluetoothAudioDevicePresent,
            publisherOutput: PublisherOutputPolicy.choose(publisherOutputSurvey)
        )
        guard decision == .allowed else {
            return decision
        }
        // Until the poll has read whether the input is this app's own
        // published device, capturing from it could feed the device itself.
        guard inputIsProcessedMicrophone == false else {
            return .refused(.transportNotRead)
        }
        // The meter re-reads the exact device before opening it, and may
        // refuse one the poll still let through. That is a refusal, not a
        // failure, for the processed microphone too.
        if
            case let .refused(refusedID, .bluetooth) = meterSession.phase,
            refusedID == inputDeviceID
        {
            return .refused(.bluetoothInput)
        }
        for latch in [captureRefusal, voiceProcessingRefusal, publisherOutputRefusal].compactMap({ $0 })
            where sourceRefusalStands(latch)
        {
            return .refused(latch.refusal)
        }
        return decision
    }

    /// Whether a Bluetooth or Bluetooth LE audio device is connected, as the
    /// latest poll read it; nil while it cannot tell. Apple voice processing
    /// runs only while this is false.
    private var bluetoothAudioDevicePresent: Bool? {
        polledBluetoothDevices.flatMap {
            ProcessedMicrophoneSourcePolicy.bluetoothDevicePresence(
                bluetoothDeviceIDs: $0.ids,
                everyTransportRead: $0.everyTransportRead
            )
        }
    }

    /// The device a processed microphone refusal's log line names, with its
    /// transport class: the default input for a Bluetooth microphone, the
    /// lowest-numbered connected Bluetooth device for Apple voice processing
    /// refused because one is connected, and the default output otherwise.
    private func refusalLogDevice(
        _ refusal: ProcessedMicrophoneRefusal
    ) -> (id: AudioDeviceID, transport: String) {
        switch refusal {
        case .bluetoothInput:
            return (inputDeviceID, AudioDeviceTransportInfo.logDescription(inputTransportInfo))
        case .bluetoothDevicePresentForVoiceProcessing:
            guard let deviceID = polledBluetoothDevices?.ids.min() else {
                return (AudioDeviceID(kAudioObjectUnknown), "unread")
            }
            // The picker lists carry the transports the poll read; a device
            // neither of them lists is not read again here.
            let listed = (inputDevices + outputDevices).first { $0.id == deviceID }
            return (deviceID, listed?.transport.logName ?? "unread")
        case .bluetoothOutputForVoiceProcessing, .noNonBluetoothOutput, .noInput, .transportNotRead:
            return (outputDeviceID, AudioDeviceTransportInfo.logDescription(outputTransportInfo))
        }
    }

    private func sourceRefusalStands(_ latch: SourceRefusalLatch) -> Bool {
        latch.stands(
            usesVoiceProcessing: microphoneProcessingMode == .apple,
            inputDeviceID: inputDeviceID,
            input: inputTransportInfo,
            outputDeviceID: outputDeviceID,
            output: outputTransportInfo
        )
    }

    /// Derives the parts of the processed microphone's state that follow from
    /// the conditions rather than from an event. Runs on every evaluation,
    /// while the quiet window holds too, so a refusal shows at once.
    private func updateProcessedMicrophoneState() {
        // A latched refusal that no longer stands is dropped, so the same
        // devices coming back later are read afresh rather than refused on
        // the strength of an old read.
        if let latch = captureRefusal, !sourceRefusalStands(latch) {
            captureRefusal = nil
        }
        if let latch = voiceProcessingRefusal, !sourceRefusalStands(latch) {
            voiceProcessingRefusal = nil
        }
        if let latch = publisherOutputRefusal, !sourceRefusalStands(latch) {
            publisherOutputRefusal = nil
        }
        // Retries that ended on an output start over once the poll shows
        // another default output, or another output for the publisher. The
        // plan then decides from this evaluation, after any window.
        if publisherOutputRetry.isExhausted, !publisherOutputRetry.exhaustionStands(for: publisherOutputSurvey) {
            publisherOutputRetry.startOver()
            if processedMicrophoneState == .failed(Self.processedMicrophoneOutputRetriesEndedMessage) {
                processedMicrophoneState = processedMicrophoneEnabled ? .starting : .disabled
            }
        }
        guard processedMicrophoneIsWanted else {
            return
        }
        if inputIsProcessedMicrophone == true {
            haltProcessedMicrophone(
                .failed(localized("The processed microphone cannot be its own source. Make a physical microphone the default input and try again."))
            )
            return
        }

        let decision = processedMicrophoneSourceDecision()
        if case let .refused(refusal) = decision, refusal.involvesBluetooth {
            let refused = ProcessedMicrophoneState.refused(
                refusal,
                published: processedMicrophoneDevice.holdsPublication
            )
            if case .refused = processedMicrophoneState {
            } else {
                let device = refusalLogDevice(refusal)
                HALLifecycleLog.record(
                    .processedMicrophoneSource,
                    .refuse,
                    id: device.id,
                    transport: device.transport,
                    generation: lifecycleHoldGeneration.current
                )
            }
            publishIfChanged(\.processedMicrophoneState, refused)
            return
        }

        switch processedMicrophoneState {
        case .refused:
            // Allowed again, or waiting for a device to be known.
            processedMicrophoneState = settledProcessedMicrophoneState
        case .starting
            where decision == .allowed
                && processedMicrophoneEngine.hasStarted
                && !processedMicrophoneEngineIsStale:
            // Engines that kept running through a halt and a retry never
            // report a start again.
            processedMicrophoneState = .active
        default:
            break
        }
    }

    /// What an allowed processed microphone shows when no step is under way.
    private var settledProcessedMicrophoneState: ProcessedMicrophoneState {
        guard
            processedMicrophoneDevice.holdsPublication,
            !processingEngaged,
            !processedMicrophoneProcessingWanted
        else {
            return .starting
        }
        return .publishedIdle
    }

    /// The one place that starts, restarts or stops the processing engines
    /// and withdraws the publication, what a publication the quiet window
    /// interrupted left behind included.
    private func performProcessedMicrophonePlan(holding: Bool, startsHeld: Bool) {
        let now = lifecycleNow()
        guard !captureCallWatch.isStalled(now: now), !handOffStopWatch.isStalled(now: now) else {
            // Anything the plan issues would queue behind the call that has
            // not come back.
            return
        }
        if !holding, processedMicrophoneDevice.keepsInterruptedPublication {
            // Before anything else the plan decides: a stops-only release
            // rolls it back too, since a rollback only stops and destroys.
            guard rollBackInterruptedPublication() else {
                // A window armed again, and the generation this evaluation
                // carries is no longer current. Nothing more for it here.
                return
            }
        }
        if !holding, publicationInterruptions.isExhausted, processedMicrophoneIsWanted {
            // The last of the publications interrupted in a row has been
            // rolled back, and no other is issued. The halt makes no HAL
            // call, so a stops-only release gives up too.
            giveUpPublishingProcessedMicrophone()
        }
        let action = ProcessedMicrophonePlan.next(
            ProcessedMicrophonePlan.Conditions(
                enabled: processedMicrophoneIsWanted,
                published: processedMicrophoneDevice.holdsPublication,
                inUse: processedMicrophoneInUse,
                processingWanted: processedMicrophoneProcessingWanted,
                engineRunning: processingEngaged,
                engineIsStale: processedMicrophoneEngineIsStale,
                publishing: publishWhenMeterStarts,
                pendingTeardown: pendingPublicationTeardown,
                decision: processedMicrophoneSourceDecision(),
                holding: holding,
                // A capture start whose input read failed waits for its
                // spacing as a start waits for a release that admits it.
                startsHeld: startsHeld || captureInputRetry.holdsStarts(on: inputDeviceID, at: now),
                outputRetry: publisherOutputRetry.gate(at: now)
            )
        )
        switch action {
        case .none:
            break
        case .startPipeline:
            startProcessedMicrophonePipeline()
        case .startProcessing:
            startProcessedMicrophoneProcessing()
        case .restartProcessing:
            restartProcessedMicrophonePipeline()
        case .stopProcessingKeepPublication:
            stopProcessedMicrophoneProcessingKeepingPublication()
        case .completeTeardown:
            completePendingPublicationTeardown()
        }
    }

    /// Rolls back what a publication the quiet window interrupted left
    /// behind: a tap, an aggregate device, or a probe IOProc that may still be
    /// running, none of it published. Runs from the plan's step at the first
    /// evaluation the window does not hold, whatever the feature wants by
    /// then, so that nothing half-made outlives the window: not while the
    /// source is refused, and not while publication waits for the meter.
    ///
    /// The rollback is `PublicProcessedMicrophoneDevice.stop(holdToken:)`, the
    /// withdrawal's own path: the probe's stop and destroy, then the
    /// aggregate device unless a process has it open, then the tap, each
    /// compared against the generation this evaluation carries. Publication
    /// is then issued again like a first one, by this evaluation or a later
    /// one that admits starts, if it is still wanted and allowed.
    ///
    /// The device lists and the defaults are not read again here, as they
    /// are after a publication or its teardown: a device that was never
    /// published is in none of this app's lists, and the poll reads the
    /// defaults.
    ///
    /// - Returns: False when a window armed again before the rollback ended.
    ///   What remains is kept, and the next release rolls it back.
    private func rollBackInterruptedPublication() -> Bool {
        do {
            try processedMicrophoneDevice.stop(holdToken: generationSeenOnMain)
            return true
        } catch is PublicProcessedMicrophoneDevice.Interrupted {
            return false
        } catch {
            interruptedPublicationWasNotRolledBack(error)
            return true
        }
    }

    /// The rollback of an interrupted publication ran to its end and left
    /// something: a consuming app opened the half-made device during the
    /// window, so it was not destroyed, or a destroy failed. What is left is
    /// an owed teardown from here on, as after any publication that failed:
    /// it waits for that app to let go, and the panel says so.
    private func interruptedPublicationWasNotRolledBack(_ error: Error) {
        let deviceError = error as? PublicProcessedMicrophoneDeviceError
        if case .publishedDeviceInUse? = deviceError {
            processedMicrophoneInUse = true
        }
        if processedMicrophoneIsWanted {
            if let deviceError {
                handleProcessedMicrophoneDeviceError(deviceError)
            } else {
                haltProcessedMicrophone(
                    .failed(localized("Could not start the processed microphone: %@", error.localizedDescription))
                )
            }
        } else if processedMicrophoneEnabled {
            // Halted already, which stays what the panel shows.
            pendingPublicationTeardown = true
        } else if case .publishedDeviceInUse? = deviceError {
            applyDisableResult(.deferredWhileInUse)
        } else {
            applyDisableResult(.failed(error.localizedDescription))
        }
    }

    /// The quiet window interrupted
    /// `PublicationInterruptions.maximumConsecutiveInterruptions` publications
    /// in a row, with none completed in between, and what the last of them
    /// kept has been rolled back. Publishing again would create a public
    /// aggregate device and its tap only to destroy them after the next
    /// window, for as long as whatever interrupts them lasts. So nothing more
    /// is published: the processed microphone shows failed with Retry, and
    /// `processed-microphone-aggregate give-up` is written once. Retry,
    /// switching the feature off, and a publication that completes start the
    /// count over. No HAL call.
    private func giveUpPublishingProcessedMicrophone() {
        HALLifecycleLog.record(
            .processedMicrophoneAggregate,
            .giveUp,
            id: AudioObjectID(kAudioObjectUnknown),
            generation: lifecycleHoldGeneration.current,
            aggregateUID: PublicProcessedMicrophoneDevice.aggregateDeviceUID
        )
        haltProcessedMicrophone(.failed(Self.processedMicrophonePublicationsInterruptedMessage))
    }

    private static var processedMicrophonePublicationsInterruptedMessage: String {
        localized("The processed microphone stopped trying to start because audio device changes kept interrupting its setup. Choose Retry to try again.")
    }

    /// A processed microphone start found its output, `outputDeviceID`,
    /// reading no usable format. Counts it in `publisherOutputRetry`; once
    /// the retries on that output end, the processed microphone shows failed
    /// with Retry, and its plan issues nothing, neither a start nor a stop,
    /// until Retry, a switch-off, or another output. No HAL call.
    private func noteProcessedMicrophoneOutputUnavailable(_ outputDeviceID: AudioDeviceID) {
        guard processedMicrophoneEnabled else {
            return
        }
        let survey = publisherOutputSurvey
        let ended = publisherOutputRetry.outputUnavailable(
            deviceID: outputDeviceID,
            at: lifecycleNow(),
            survey: survey
        )
        guard publisherOutputRetry.isExhausted else {
            return
        }
        if ended {
            let polled = survey.defaultOutput?.deviceID == outputDeviceID
                ? survey.defaultOutput
                : survey.outputs?.first { $0.deviceID == outputDeviceID }
            HALLifecycleLog.record(
                .processedMicrophonePublisherEngine,
                .giveUp,
                id: outputDeviceID,
                transport: AudioDeviceTransportInfo.logDescription(polled?.info),
                generation: lifecycleHoldGeneration.current
            )
        }
        publishIfChanged(\.processedMicrophoneState, .failed(Self.processedMicrophoneOutputRetriesEndedMessage))
    }

    private static var processedMicrophoneOutputRetriesEndedMessage: String {
        localized("The processed microphone stopped trying to start because its output kept reporting no usable audio format. Choose Retry to try again. It also tries again when the output device changes.")
    }

    /// The read the capture made as it opened its input, `inputDeviceID`,
    /// could not read the transport or resolve an aggregate member, although
    /// the poll had. Counts it in `captureInputRetry`, which spaces the next
    /// start. Once the retries on that input end, the processed microphone
    /// halts, failed with Retry, and
    /// `processed-microphone-capture-ioproc give-up` is written once, so the
    /// input is not opened again, and the capture's IOProc perhaps created
    /// and released, at every window for as long as the read keeps failing.
    /// No HAL call.
    private func noteProcessedMicrophoneInputReadFailed(_ inputDeviceID: AudioDeviceID) {
        guard processedMicrophoneEnabled else {
            return
        }
        guard captureInputRetry.readFailed(deviceID: inputDeviceID, at: lifecycleNow()) else {
            return
        }
        HALLifecycleLog.record(
            .processedMicrophoneCaptureIOProc,
            .giveUp,
            id: inputDeviceID,
            transport: inputDeviceID == self.inputDeviceID
                ? AudioDeviceTransportInfo.logDescription(inputTransportInfo)
                : "unread",
            generation: lifecycleHoldGeneration.current
        )
        haltProcessedMicrophone(.failed(Self.processedMicrophoneInputReadsFailedMessage))
    }

    private static var processedMicrophoneInputReadsFailedMessage: String {
        localized("The processed microphone stopped trying to start because the input device’s connection type, or the devices that make up an aggregate input, could not be read as it was opened. Choose Retry to try again.")
    }

    /// Stops the feature at a state the user has to act on. The teardown a
    /// failure has always carried is owed rather than done here, so it waits
    /// for the quiet window and for any consuming app to let go.
    private func haltProcessedMicrophone(_ state: ProcessedMicrophoneState) {
        processedMicrophoneState = state
        // The halt owes its own teardown, which retries that ended must not
        // hold back.
        publisherOutputRetry.startOver()
        captureInputRetry.startOver()
        cancelScheduledProcessingStop()
        publishWhenMeterStarts = false
        resetPublicationRetry()
        pendingPublicationTeardown = true
    }

    private func resetPublicationRetry() {
        publicationAttempts = 0
        publicationRetryAt = -.infinity
    }

    /// Publishes the processed microphone once the meter runs on the current
    /// input, which is what gives this process its Core Audio process object.
    private func publishProcessedMicrophoneIfMeterRunning(now: TimeInterval) {
        guard
            publishWhenMeterStarts,
            processedMicrophoneIsWanted,
            // Three publications in a row were interrupted. The plan gives up
            // after the rollback; an evaluation that returns before the plan,
            // as one does while a capture or hand-off call is stalled, must
            // not publish a fourth time meanwhile.
            !publicationInterruptions.isExhausted,
            now >= publicationRetryAt,
            inputDeviceID != kAudioObjectUnknown,
            meterSession.target == .device(inputDeviceID),
            meterSession.phase == .running(inputDeviceID),
            processedMicrophoneSourceDecision() == .allowed
        else {
            return
        }
        publishWhenMeterStarts = false
        publishProcessedMicrophone(now: now)
    }

    /// Records the switch-on and lets the evaluation take it from there.
    /// Nothing here touches the HAL.
    private func startProcessedMicrophone() {
        guard processedMicrophoneEnabled else {
            return
        }
        // A switch-on or a retry by the user starts the output retries over,
        // the input's failed reads, and the count of interrupted publications.
        publisherOutputRetry.startOver()
        captureInputRetry.startOver()
        publicationInterruptions.startOver()
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

        pendingPublicationTeardown = false
        resetPublicationRetry()
        captureRefusal = nil
        voiceProcessingRefusal = nil
        publisherOutputRefusal = nil
        processedMicrophoneState = .starting
        levels.resetMicrophone()
        microphoneError = nil
        if meterSession.retriesExhausted {
            // A retry by the user starts the meter's attempts over. A failed
            // start leaves nothing open, so no HAL call is owed here.
            _ = meterSession.handle(.stopRequested)
        }
        reconcileLifecycle()
    }

    /// Runs only from the plan.
    private func startProcessedMicrophonePipeline() {
        guard processedMicrophoneEnabled else {
            return
        }

        // Ensure this process has a Core Audio process object even during a
        // cold launch with the saved opt-in already enabled. Publishing the
        // device translates this pid to a Core Audio process object, and that
        // object only exists once something in this process runs audio IO.
        // The meter is what runs it, on its own queue, so publication waits
        // until the meter reports it running on the current input rather than
        // assuming it. While no app is consuming the published device this
        // meter also stays on as the menu bar's microphone source, in place of
        // the processing engines.
        publishWhenMeterStarts = true
        if meterSession.retriesExhausted {
            _ = meterSession.handle(.stopRequested)
        }
    }

    /// Runs only from an evaluation that the quiet window is not holding.
    private func publishProcessedMicrophone(now: TimeInterval) {
        guard processedMicrophoneEnabled else {
            return
        }
        // Publication runs synchronously here. A listener that advanced the
        // generation since this evaluation read its admission holds it back,
        // and one that advances it while the publication is on its way stops
        // it before its next HAL call: it carries the generation the main
        // thread has seen, as every start an evaluation issues does.
        guard !lifecycleStartsHeld else {
            publishWhenMeterStarts = true
            return
        }

        do {
            _ = try processedMicrophoneDevice.start(holdToken: generationSeenOnMain)
            resetPublicationRetry()
            // Only interruptions with no completed publication between them
            // count toward giving up.
            publicationInterruptions.startOver()
            processedMicrophoneInUse = processedMicrophoneDevice.isInUse

            if processedMicrophoneProcessingWanted {
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
            refreshDevices()
        } catch is PublicProcessedMicrophoneDevice.Interrupted {
            // A quiet window armed while the publication was on its way, and
            // it stopped before its next HAL call. Not a failure: nothing is
            // rolled back inside the window, the device keeps what it
            // created, unpublished, and the plan's first step after the
            // window rolls that back. Publication waits again, for a release
            // that admits starts. The interruption is counted: at the cap of
            // interruptions in a row, the plan rolls this one back too and
            // then gives up instead of publishing again.
            publicationInterruptions.interrupted()
            publishWhenMeterStarts = true
        } catch PublicProcessedMicrophoneDeviceError.audioProcessUnavailable
            where publicationAttempts == 0
        {
            // The meter's IO has not produced a process object yet. Try once
            // more a little later, with the meter still running, instead of
            // starting anything else to make one.
            publicationAttempts = 1
            publicationRetryAt = now + Self.publicationRetryDelay
            publishWhenMeterStarts = true
        } catch let error as PublicProcessedMicrophoneDeviceError {
            handleProcessedMicrophoneDeviceError(error)
        } catch {
            haltProcessedMicrophone(
                .failed(localized("Could not start the processed microphone: %@", error.localizedDescription))
            )
        }
    }

    /// Hands the input from the meter to the processing engines. Runs only
    /// from the plan or from publication, both outside the quiet window.
    private func startProcessedMicrophoneProcessing() {
        cancelScheduledProcessingStop()
        // A meter whose start has not reported back, stalled or not, cannot
        // hand the input over: its stop would only queue behind that start,
        // and a start that then hangs would never be seen as stalled.
        guard processedMicrophoneIsWanted, !processingEngaged, !meterSession.hasStartInFlight else {
            return
        }
        guard processedMicrophoneDevice.isPublished else {
            // The publication went stale. Publishing again validates it or
            // rebuilds it — through the meter, which gives this process IO
            // while it does — before any processed audio is rendered.
            processedMicrophoneState = .starting
            startProcessedMicrophonePipeline()
            return
        }

        levels.resetMicrophone()
        processedMicrophoneState = .starting

        // The meter and the capture engine both open the physical input, and
        // voice processing gets a broken or silent input if it claims the
        // device while the meter still holds it. The meter's teardown runs on
        // its own queue, so wait for it rather than assume it already happened.
        processingStartInFlight = true
        publishWhenMeterStarts = false
        _ = meterSession.handle(.stopRequested)
        publishMicrophoneDisplay()
        let handOffToken = handOffStopWatch.issue(now: lifecycleNow())
        handOffStopDeviceID = inputDeviceID
        microphoneMeter.stop(holdToken: generationSeenOnMain) { [weak self] outcome in
            guard let self else {
                return
            }
            let stallEnded = handOffStopReported(token: handOffToken)
            guard processingStartInFlight else {
                // A stop landed while the meter was releasing the device.
                if stallEnded {
                    reconcileLifecycle()
                }
                return
            }
            processingStartInFlight = false
            // Conditions can change while the meter is releasing the device,
            // and a change that arrived meanwhile holds the window again. A
            // stop that window interrupted leaves the meter on the input, so
            // nothing takes it over until the evaluation after the window.
            guard
                outcome == .stopped,
                processedMicrophoneState == .starting,
                !processedMicrophoneEngine.isRunning,
                !captureCallWatch.isStalled(now: lifecycleNow()),
                processedMicrophoneStartMayProceed
            else {
                // Nothing took the input over, so the meter gets it back and
                // the next evaluation decides again.
                reconcileLifecycle()
                return
            }
            captureStartToken = captureCallWatch.issue(now: lifecycleNow())
            _ = processedMicrophoneEngine.start(
                configuration: .init(
                    processingMode: microphoneProcessingMode,
                    digitalGainDecibels: digitalGainDecibels,
                    inputDeviceID: inputDeviceID,
                    outputDeviceID: outputDeviceID
                ),
                holdToken: generationSeenOnMain
            )
        }
    }

    /// Records a consuming app opening or closing the published device.
    /// Nothing starts or stops here; the evaluation decides.
    private func handleProcessedMicrophoneInUseChange(_ inUse: Bool) {
        processedMicrophoneInUse = inUse
        if inUse {
            cancelScheduledProcessingStop()
        } else if processingEngaged {
            scheduleProcessingStopForIdle()
        }
        reconcileLifecycle()
    }

    /// Apps stop and restart the published device when they change format or
    /// move between preview and call modes. Processing stays wanted for a
    /// grace period after the last consumer closes it; the timer only asks
    /// for an evaluation when it ends.
    private func scheduleProcessingStopForIdle() {
        guard scheduledProcessingStop == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            scheduledProcessingStop = nil
            reconcileLifecycle()
        }
        scheduledProcessingStop = workItem
        scheduler.asyncAfter(Self.processingIdleGracePeriod, execute: workItem)
    }

    private func cancelScheduledProcessingStop() {
        scheduledProcessingStop?.cancel()
        scheduledProcessingStop = nil
    }

    /// Stops the engines and keeps the publication. Runs only from the plan:
    /// for idle, for a refused source, or because the feature is off or
    /// halted while a consumer still holds the device.
    private func stopProcessedMicrophoneProcessingKeepingPublication() {
        // The publication itself stays up: other apps keep seeing the device
        // in their input lists, reopening it starts processing again, and a
        // consumer that keeps it open receives silence meanwhile.
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
        cancelScheduledProcessingStop()
        processingStartInFlight = false
        stopProcessedMicrophoneEngine()
        levels.resetMicrophone()

        guard processedMicrophoneIsWanted else {
            // Off or halted: that state already says what happens next.
            return
        }
        if case .refused = processedMicrophoneState {
            return
        }
        processedMicrophoneState = settledProcessedMicrophoneState
    }

    /// Recovers from a missed property notification.
    ///
    /// The listener is the real signal; this only has to catch a dropped one,
    /// so it runs on the slow cadence and reads a single HAL property. Do not
    /// consult `isPublished` here: validating the publication enumerates every
    /// device in the system, which is far too much for a safety net.
    private func reconcileProcessedMicrophoneProcessing() {
        guard
            processedMicrophoneDevice.holdsPublication || pendingPublicationTeardown
        else {
            return
        }
        let inUse = processedMicrophoneDevice.isInUse
        if inUse != processedMicrophoneInUse {
            handleProcessedMicrophoneInUseChange(inUse)
        } else if
            !inUse,
            processingEngaged,
            scheduledProcessingStop == nil,
            processedMicrophoneDevice.isMonitoringInUse
        {
            scheduleProcessingStopForIdle()
        }
    }

    /// Stops the engines, validates the publication through the meter and
    /// `PublicProcessedMicrophoneDevice.start()`, and captures again on the
    /// current input and mode. Runs only from the plan.
    private func restartProcessedMicrophonePipeline() {
        // Fail closed: the publisher is stopped before checking the muted tap.
        // PublicProcessedMicrophoneDevice.start() validates and, if needed,
        // recreates the tap/aggregate before publisher audio resumes.
        cancelScheduledProcessingStop()
        processingStartInFlight = false
        processedMicrophoneState = .starting
        let stopped = stopProcessedMicrophoneEngine()
        levels.resetMicrophone()
        guard stopped else {
            // A window armed since this evaluation read its admission. What
            // the stop left counts as running with a restart owed, so the
            // plan asks for this restart again after the window.
            return
        }
        startProcessedMicrophonePipeline()
    }

    private func handleProcessedMicrophoneDeviceError(
        _ error: PublicProcessedMicrophoneDeviceError
    ) {
        switch error {
        case .unsupportedOS:
            haltProcessedMicrophone(.unavailable)
        case .permissionDenied:
            haltProcessedMicrophone(.systemAudioDenied)
        default:
            haltProcessedMicrophone(
                .failed(error.errorDescription ?? error.localizedDescription)
            )
        }
    }

    private func handleProcessedMicrophoneEngineError(
        _ error: ProcessedMicrophoneEngineError
    ) {
        guard processedMicrophoneEnabled else {
            return
        }

        if case let .voiceProcessingSourceChanged(check) = error {
            // Not a failure of the mode, and nothing was started.
            let configuration = processedMicrophoneEngine.configuration
            if let latch = SourceRefusalLatch.voiceProcessing(
                check,
                inputDeviceID: configuration.inputDeviceID,
                polledInput: inputTransportInfo,
                outputDeviceID: configuration.outputDeviceID,
                polledOutput: outputTransportInfo
            ) {
                // The same defaults now involve Bluetooth, which the poll does
                // not show. Shown as a refusal until the poll shows a change.
                voiceProcessingRefusal = latch
            } else {
                // The defaults moved, or could not be read, since the poll this
                // start was decided on. Hold a window so a fresh poll decides
                // the next try.
                noteLifecycleChange(reason: "processing-refused")
            }
            if processedMicrophoneState == .active {
                processedMicrophoneState = .starting
            }
            reconcileLifecycle()
            return
        }

        if case let .publisherOutputRefused(refusal) = error {
            // Not a failure, and nothing was created.
            switch refusal {
            case .noNonBluetoothOutput:
                if PublisherOutputPolicy.uncachedRefusalMayLatch(
                    pollChoice: PublisherOutputPolicy.choose(publisherOutputSurvey)
                ) {
                    // The poll still shows an output the publisher may be
                    // bound to, or this start would not have been issued.
                    // Shown as a refusal until the poll shows another default
                    // output or transport.
                    publisherOutputRefusal = .publisherOutput(
                        outputDeviceID: outputDeviceID,
                        polledOutput: outputTransportInfo
                    )
                } else {
                    // The poll chose a built-in output, which neither becomes
                    // Bluetooth nor goes away: the uncached read failed to
                    // read it. Try again once a quiet window has passed.
                    noteLifecycleChange(reason: "processing-refused")
                }
            case .outputsNotRead:
                // The devices could not be read as the start was about to be
                // made. Try again once a quiet window has passed.
                noteLifecycleChange(reason: "processing-refused")
            }
            if processedMicrophoneState == .active {
                processedMicrophoneState = .starting
            }
            reconcileLifecycle()
            return
        }

        if case let .outputUnavailable(outputDeviceID) = error {
            // The output read no usable format, as a device being reconfigured
            // or removed does. Not a failure of the mode, and nothing was
            // started: try again once a quiet window, and the retry's spacing,
            // have passed, unless the retries on that output have ended.
            noteLifecycleChange(reason: "processing-refused")
            if processedMicrophoneState == .active {
                processedMicrophoneState = .starting
            }
            noteProcessedMicrophoneOutputUnavailable(outputDeviceID)
            reconcileLifecycle()
            return
        }

        if case let .inputRefused(refusal) = error {
            // Not a failure. The capture released everything before reporting.
            switch refusal {
            case .bluetooth, .aggregateWithBluetoothMember:
                // Shown as a refusal until the input or its transport changes.
                captureRefusal = .captureInput(
                    deviceID: processedMicrophoneEngine.configuration.inputDeviceID,
                    polledInput: inputTransportInfo
                )
            case .transportNotRead, .aggregateWithUnresolvedMember:
                // The poll judged this input open, or no start would have
                // been issued, so a transport this read could not read, or an
                // aggregate member only this read could not resolve, is most
                // likely a read that failed once, as for the meter: not
                // latched as a Bluetooth refusal. Tried again once a quiet
                // window and the retry's spacing have passed, unless the
                // retries on that input have ended.
                noteLifecycleChange(reason: "processing-refused")
                noteProcessedMicrophoneInputReadFailed(processedMicrophoneEngine.configuration.inputDeviceID)
            case .noDevice:
                // Try again once a quiet window has passed, not on the next
                // poll.
                noteLifecycleChange(reason: "processing-refused")
            }
            if processedMicrophoneState == .active {
                processedMicrophoneState = .starting
            }
            reconcileLifecycle()
            return
        }

        let failedMode = processedMicrophoneEngine.configuration.processingMode
        if failedMode != microphoneProcessingMode {
            // This error belongs to a superseded start generation. Keep the
            // user's newer selection; the evaluation rebuilds it.
            reconcileLifecycle()
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
            processedMicrophoneState = .starting
            reconcileLifecycle()
            return
        }

        let message = error.errorDescription ?? error.localizedDescription
        haltProcessedMicrophone(.failed(message))
        reconcileLifecycle()
    }

    /// Stops the engines and withdraws the publication. Refused while a
    /// consuming app has the device open: `PublicProcessedMicrophoneDevice`
    /// reads `kAudioDevicePropertyDeviceIsRunningSomewhere` before destroying
    /// anything. Runs only outside the quiet window. When a listener has
    /// advanced the generation since the evaluation read its admission, the
    /// engines' stop is held back, and then nothing is withdrawn either, or
    /// the withdrawal ends before its next destroy (`.heldBack`). Quit does
    /// not come through here: `stop()` follows
    /// `QuitPlan`, calling `ProcessedMicrophoneEngine.stopAtQuit(in:)` and
    /// `PublicProcessedMicrophoneDevice.stop(reason:)` directly.
    @discardableResult
    private func stopProcessedMicrophoneResources() -> ProcessedMicrophoneTeardownResult {
        // Stop the publisher before destroying its muted tap so processed
        // microphone samples can never briefly reach the physical output.
        cancelScheduledProcessingStop()
        processingStartInFlight = false
        publishWhenMeterStarts = false
        guard stopProcessedMicrophoneEngine() else {
            // A listener advanced the generation after this evaluation read
            // its admission, and the engines were not stopped inside that
            // window. The tap is not destroyed under a publisher that may
            // still render into it.
            return .heldBack
        }

        // The withdrawal follows the engines' stop, which can wait in
        // coreaudiod, and its own two destroys are up to half a second apart.
        // It carries the generation this evaluation saw, like the stop, and
        // is compared immediately before each destroy.
        var result = ProcessedMicrophoneTeardownResult.completed
        do {
            try processedMicrophoneDevice.stop(holdToken: generationSeenOnMain)
        } catch is PublicProcessedMicrophoneDevice.Interrupted {
            // A window armed first. Held back before the aggregate device's
            // destroy, the publication is intact. Held back before the tap's,
            // the device is gone and the tap is kept, which the plan's
            // rollback step destroys at the release after the window. Either
            // way the teardown stays owed, and nothing is read or reported
            // inside the window.
            return .heldBack
        } catch PublicProcessedMicrophoneDeviceError.publishedDeviceInUse {
            result = .deferredWhileInUse
        } catch {
            result = .failed(error.localizedDescription)
        }

        refreshDevices()
        return result
    }

    /// Carries out an owed teardown. Runs only from the plan, which asks for
    /// it only while no consuming app is known to hold the device.
    private func completePendingPublicationTeardown() {
        guard pendingPublicationTeardown, !processedMicrophoneIsWanted else {
            return
        }

        let result = stopProcessedMicrophoneResources()
        if case .heldBack = result {
            // Still owed: the plan asks again at the release after the window.
            return
        }
        // Whether the teardown is settled. A reclaim of the earlier run's
        // taps that a window held back keeps it owed, so the plan comes back
        // after the window, finds nothing left to withdraw, and reclaims the
        // rest.
        var settled = true
        if case .completed = result {
            // An earlier run's publication, if one was left, is gone now, and
            // with it the reason its taps were kept.
            settled = reclaimOrphanedTaps(launchCleanup.publicationTeardownCompleted())
        }
        if case .deferredWhileInUse = result {
            // The device says otherwise. Wait for the listener, or the slow
            // safety net, to report it closed, rather than ask again on every
            // evaluation.
            processedMicrophoneInUse = true
        }

        guard !processedMicrophoneEnabled else {
            // Halted by a failure, which stays what the panel shows.
            switch result {
            case .completed:
                pendingPublicationTeardown = !settled
            case .deferredWhileInUse, .heldBack:
                break
            case let .failed(message):
                pendingPublicationTeardown = false
                if case let .failed(existing) = processedMicrophoneState {
                    processedMicrophoneState = .failed("\(existing) \(message)")
                }
            }
            return
        }

        switch result {
        case .completed:
            pendingPublicationTeardown = !settled
            processedMicrophoneState = .disabled
        case .deferredWhileInUse:
            processedMicrophoneState = .awaitingRelease
        case .heldBack:
            break
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
            processedMicrophoneInUse = true
            processedMicrophoneState = .awaitingRelease
        case .heldBack:
            pendingPublicationTeardown = true
        case let .failed(message):
            pendingPublicationTeardown = false
            processedMicrophoneState = .failed(
                ([message] + additionalErrors).joined(separator: " ")
            )
        }
    }

    /// Stops the system playback meter now, or once the quiet window ends.
    private func stopSystemOutputMeter() {
        // A call still waiting on the meter's queue holds the stop pending,
        // as the window does.
        guard
            systemOutputIntent.handle(.stop(holding: lifecycleIsHeld || systemOutputCallIsStalled)) == .stop
        else {
            return
        }
        systemOutputRecovery.stopped()
        issueSystemOutputMeterCall { systemOutputMeter.stop(holdToken: generationSeenOnMain) }
    }

    /// Runs only from an evaluation `reconcileLifecycle()` does not hold. With
    /// starts held, a pending rebuild stays owed and the meter keeps running
    /// until the release that admits starts rebuilds it; a pending stop is
    /// carried out. An invalidated meter's rebuild also waits for its spacing.
    private func applyPendingSystemOutputChange(startsHeld: Bool) {
        guard !systemOutputCallIsStalled else {
            // The pending change stays until the stalled call comes back.
            return
        }
        let rebuildDue = systemOutputRecovery.rebuildIsDue(at: lifecycleNow())
        switch systemOutputIntent.handle(.release(startsHeld: startsHeld, rebuildDue: rebuildDue)) {
        case .start:
            restartSystemOutputMeter()
        case .stop:
            systemOutputRecovery.stopped()
            issueSystemOutputMeterCall { systemOutputMeter.stop(holdToken: generationSeenOnMain) }
        case .none:
            break
        }
    }

    /// Rebuilds the system playback meter for the current output. While the
    /// quiet window holds starts, it shows the meter starting at once and
    /// rebuilds it once starts are admitted, however many changes asked for
    /// it.
    private func restartSystemOutputMeter() {
        guard systemOutputMonitoringEnabled else {
            return
        }
        guard #available(macOS 14.2, *) else {
            systemOutputMonitoringState = .unavailable
            return
        }
        guard !systemOutputRecovery.rebuildsExhausted else {
            // The rebuilds gave up. The rebuild stays owed and nothing is
            // issued until Retry, monitoring switched on, or an output change
            // starts them over.
            _ = systemOutputIntent.handle(.rebuild(holding: true))
            showSystemOutputRebuildOwed()
            return
        }
        guard
            systemOutputIntent.handle(.rebuild(holding: lifecycleStartsHeld || systemOutputCallIsStalled)) == .start
        else {
            // Held back until the window ends.
            levels.resetSystemOutput()
            publishIfChanged(\.systemOutputMonitoringState, .starting)
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
        // Levels are watched again once this start reports, and the spacing
        // an invalidation owed is spent.
        systemOutputRecovery.rebuildIssued()
        issueSystemOutputMeterCall {
            systemOutputMeter.start(
                deviceUID: deviceUID,
                transportDescription: AudioDeviceTransportInfo.logDescription(
                    outputTransportInfo
                ),
                excludingCurrentProcess: processedMicrophoneEnabled,
                holdToken: generationSeenOnMain
            )
        }
    }
}
