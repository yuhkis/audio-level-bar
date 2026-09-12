import AudioLevelBarCore
import CoreAudio
import SwiftUI

enum ControlPanelLayout {
    static let width: CGFloat = 400
    static let height: CGFloat = 640
}

struct PopoverView: View {
    @ObservedObject var state: AudioState
    @ObservedObject var meterColorSettings: MeterColorSettings
    @ObservedObject var presentation: ControlPanelPresentation

    private var showsSettings: Bool {
        presentation.showsSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                if showsSettings {
                    displaySettingsSection
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        outputSection
                        Divider()
                        inputSection
                    }
                }
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: ControlPanelLayout.width, height: ControlPanelLayout.height)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Audio Level Bar")
                    .font(.headline)
                Text(showsSettings
                    ? localized("Meter display settings")
                    : localized("Default input and output devices and levels"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                presentation.showsSettings.toggle()
            } label: {
                Label(
                    showsSettings ? localized("Back") : localized("Settings"),
                    systemImage: showsSettings ? "chevron.backward" : "gearshape"
                )
                .foregroundStyle(Color.primary)
            }
            .buttonStyle(.borderless)
            Button(localized("Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.primary)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                outputMuteControl

                Picker(localized("Output Device"), selection: outputDeviceBinding) {
                    ForEach(state.outputDevices) { device in
                        Label(
                            device.name,
                            systemImage: device.systemImageName(for: .output)
                        )
                        .labelStyle(.titleAndIcon)
                        .tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                if state.outputMuted == true {
                    Text(localized("Muted"))
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                        .accessibilityLabel(localized("Speaker is muted"))
                }

                // Trailing, after the muted badge, so the button keeps its
                // place when muting adds or removes that badge. An AirPlay
                // receiver only becomes a Core Audio device once it is
                // connected, so the picker to its left cannot offer one; this
                // hands off to the macOS UI that can.
                airPlayControl
            }

            SystemOutputMeterView(
                levels: state.levels,
                meterColorSettings: meterColorSettings,
                monitoringEnabled: state.systemOutputMonitoringEnabled,
                isMonitoringActive: state.systemOutputMonitoringState == .active,
                outputVolume: state.outputVolume,
                outputIsMuted: state.outputMuted == true
            )

            VStack(alignment: .leading, spacing: 4) {
                if state.outputVolumeIsAdjustable, let outputVolume = state.outputVolume {
                    HStack(spacing: 8) {
                        Text(localized("Output volume"))
                        Spacer()
                        // Red while muted, so the number agrees with the icon
                        // and the badge instead of quietly reporting a level
                        // nothing is playing at.
                        Text(percentageText(outputVolume))
                            .monospacedDigit()
                            .foregroundStyle(
                                state.outputMuted == true
                                    ? Color.red
                                    : Color.secondary
                            )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { outputVolume },
                            set: state.setOutputVolume
                        ),
                        in: 0...1
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(localized("Speaker volume"))
                } else {
                    unavailableControlText(localized("macOS cannot change the volume of this output device."))
                }
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                inputMuteControl

                Picker(localized("Input Device"), selection: inputDeviceBinding) {
                    ForEach(state.inputDevices) { device in
                        Label(
                            device.name,
                            systemImage: device.systemImageName(for: .input)
                        )
                        .labelStyle(.titleAndIcon)
                        .tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                if state.inputMuted == true {
                    Text(localized("Muted"))
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                        .accessibilityLabel(localized("Microphone is muted"))
                }
            }

            MicrophoneMeterView(
                levels: state.levels,
                meterColorSettings: meterColorSettings,
                inputVolume: state.inputVolume,
                showsProcessedSource: state.processedMicrophoneState == .active,
                inputIsMuted: state.inputMuted == true
            )

            VStack(alignment: .leading, spacing: 4) {
                if state.inputVolumeIsAdjustable, let inputVolume = state.inputVolume {
                    HStack(spacing: 8) {
                        Text(localized("Input gain"))
                        Spacer()
                        Text(percentageText(inputVolume))
                            .monospacedDigit()
                            .foregroundStyle(
                                state.inputMuted == true
                                    ? Color.red
                                    : Color.secondary
                            )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { inputVolume },
                            set: state.setInputVolume
                        ),
                        in: 0...1
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(localized("Microphone input gain"))
                } else {
                    unavailableControlText(localized("The gain of this input device is adjusted on the device itself."))
                }
            }

            if let error = state.microphoneError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                HStack {
                    Text(state.microphonePermission.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if state.microphonePermission == .denied {
                        Button(localized("Open Settings")) {
                            state.openMicrophonePrivacySettings()
                        }
                        .controlSize(.small)
                    }
                }
            }

            if state.showsBluetoothMonitoringNote {
                Text(localized("This Bluetooth microphone is metered only while this popup or the control window is open, because opening it switches the headset into call mode and lowers playback quality. While both are closed, the menu bar shows --. “Always monitor Bluetooth microphones” in Settings changes this."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            processedMicrophoneControls
        }
    }

    private var processedMicrophoneControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                localized("Use processed microphone (experimental)"),
                isOn: processedMicrophoneBinding
            )

            Text(localized("A local virtual input is published only while this is on. Your macOS default input is left alone. Processing runs only while an app has this input open."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.processedMicrophoneEnabled {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(localized("Digital gain"))
                        Spacer()
                        Text(digitalGainText)
                            .monospacedDigit()
                        Button("0 dB") {
                            state.resetDigitalGain()
                        }
                        .controlSize(.small)
                        .disabled(state.digitalGainDecibels == 0)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Slider(
                        value: digitalGainBinding,
                        in: Double(DigitalGain.minimumDecibels)...Double(DigitalGain.maximumDecibels),
                        step: 0.5
                    )
                    .accessibilityLabel(localized("Processed microphone digital gain"))
                    .accessibilityValue(digitalGainText)
                }

                Picker(
                    localized("Processing mode"),
                    selection: microphoneProcessingModeBinding
                ) {
                    ForEach(MicrophoneProcessingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(state.processedMicrophoneState == .starting)

                Text(localized("Apple provides echo cancellation and noise suppression (no AGC); WebRTC provides noise suppression only. When comparing them, turn off the consuming app’s own processing so it is not applied twice."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = state.microphoneProcessingMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if state.processedMicrophoneState == .publishedIdle {
                    Text(localized("Choose “Audio Level Bar Microphone” in the microphone settings of the app you want to use. Until it is chosen, 🎙 shows the unprocessed microphone level."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    processedMicrophoneStatusText
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    processedMicrophoneStatusActions
                }

                VStack(alignment: .leading, spacing: 6) {
                    processedMicrophoneStatusText
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer()
                        processedMicrophoneStatusActions
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                state.openSoundSettings()
            } label: {
                Label(localized("Sound Settings"), systemImage: "speaker.wave.2.fill")
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.borderless)
            .help(localized("Open the macOS Sound settings"))
        }
    }

    private var displaySettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            systemOutputMonitoringSettings
            Divider()
            microphoneMonitoringSettings
            Divider()
            meterColorSection
        }
    }

    private var systemOutputMonitoringSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(localized("System playback level"), systemImage: "waveform")
                .font(.headline)

            Toggle(localized("Monitor the system playback level"), isOn: systemOutputMonitoringBinding)

            Text(localized("When this is on, the colored bar is the actual system playback signal (dBFS) and the white line is where the output volume is set. The first use needs the macOS system audio recording permission."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(state.systemOutputMonitoringState.description)
                    .font(.caption2)
                    .foregroundStyle(systemOutputStatusColor)
                Spacer()
                if state.systemOutputMonitoringState == .starting {
                    ProgressView()
                        .controlSize(.small)
                }
                if state.systemOutputMonitoringState == .denied {
                    Button(localized("Open Settings")) {
                        state.openSystemAudioPrivacySettings()
                    }
                    .controlSize(.small)
                    Button(localized("Retry")) {
                        state.retrySystemOutputMonitoring()
                    }
                    .controlSize(.small)
                } else if case .failed = state.systemOutputMonitoringState {
                    Button(localized("Retry")) {
                        state.retrySystemOutputMonitoring()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var microphoneMonitoringSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(localized("Microphone monitoring"), systemImage: "mic.fill")
                .font(.headline)

            Toggle(
                localized("Always monitor Bluetooth microphones"),
                isOn: bluetoothAlwaysMonitorBinding
            )

            Text(localized("Opening a Bluetooth microphone switches the headset into call mode and lowers playback quality for as long as it stays open. When this is off, a Bluetooth default input is metered only while this popup or the control window is showing, and the menu bar shows -- the rest of the time. Other microphones, and any input while the processed microphone is on, are always metered."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meterColorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(localized("Color by level"), systemImage: "paintpalette.fill")
                .font(.headline)

            Text(localized("Thresholds are set separately for the speaker and the microphone. A live signal maps −60 to 0 dBFS onto 0 to 100%, and a speaker with system playback monitoring off uses the output volume percentage instead."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            thresholdGroup(
                channel: .systemOutput,
                title: localized("Speaker"),
                systemImage: "speaker.wave.2.fill",
                note: localized("The playback level cannot be changed from here, so green means “sound really is coming through” and red means “quite loud, possibly too loud.” The defaults are green at 25% (−45 dBFS / volume 25%) and red at 90% (−6 dBFS / volume 90%).")
            )

            Divider()

            thresholdGroup(
                channel: .microphone,
                title: localized("Microphone"),
                systemImage: "mic.fill",
                note: localized("The defaults suit speech recognition and meetings: green at −30 dBFS (50%) and red at −6 dBFS (90%). Aim for mostly green while you speak, without sticking at red, and adjust the input gain to match.")
            )
        }
    }

    private func thresholdGroup(
        channel: MeterColorChannel,
        title: String,
        systemImage: String,
        note: String
    ) -> some View {
        let thresholds = meterColorSettings.thresholds(for: channel)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(localized("Reset to defaults")) {
                    meterColorSettings.reset(channel)
                }
                .controlSize(.small)
            }

            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            thresholdControl(
                title: localized("Level that turns green"),
                color: .green,
                value: greenThresholdBinding(for: channel),
                range: 0...max(
                    0,
                    Double(thresholds.redThreshold) - meterColorSettings.minimumGap
                ),
                accessibilityPrefix: title
            )

            thresholdControl(
                title: localized("Level that turns red"),
                color: .red,
                value: redThresholdBinding(for: channel),
                range: min(
                    1,
                    Double(thresholds.greenThreshold) + meterColorSettings.minimumGap
                )...1,
                accessibilityPrefix: title
            )
        }
    }

    private var processedMicrophoneStatusText: some View {
        Text(state.processedMicrophoneState.description)
            .font(.caption2)
            .foregroundStyle(processedMicrophoneStatusColor)
    }

    @ViewBuilder
    private var processedMicrophoneStatusActions: some View {
        if state.processedMicrophoneState == .starting {
            ProgressView()
                .controlSize(.small)
        }

        switch state.processedMicrophoneState {
        case .microphoneDenied:
            Button(localized("Open Settings")) {
                state.openMicrophonePrivacySettings()
            }
            .controlSize(.small)
        case .systemAudioDenied:
            Button(localized("Open Settings")) {
                state.openSystemAudioPrivacySettings()
            }
            .controlSize(.small)
            Button(localized("Retry")) {
                state.retryProcessedMicrophone()
            }
            .controlSize(.small)
        case .failed:
            Button(localized("Retry")) {
                state.retryProcessedMicrophone()
            }
            .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func thresholdControl(
        title: String,
        color: Color,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        accessibilityPrefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(title)
                Spacer()
                Text(thresholdText(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Slider(value: value, in: range)
                .tint(color)
                .accessibilityLabel(localized("%1$@ %2$@", accessibilityPrefix, title))
                .accessibilityValue(thresholdText(value.wrappedValue))
        }
    }

    private var outputDeviceBinding: Binding<AudioDeviceID> {
        Binding(
            get: { state.outputDeviceID },
            set: state.selectOutputDevice
        )
    }

    private var inputDeviceBinding: Binding<AudioDeviceID> {
        Binding(
            get: { state.inputDeviceID },
            set: state.selectInputDevice
        )
    }

    private var processedMicrophoneBinding: Binding<Bool> {
        Binding(
            get: { state.processedMicrophoneEnabled },
            set: state.setProcessedMicrophoneEnabled
        )
    }

    private var microphoneProcessingModeBinding: Binding<MicrophoneProcessingMode> {
        Binding(
            get: { state.microphoneProcessingMode },
            set: state.setMicrophoneProcessingMode
        )
    }

    private var digitalGainBinding: Binding<Double> {
        Binding(
            get: { Double(state.digitalGainDecibels) },
            set: { state.setDigitalGainDecibels(Float($0)) }
        )
    }

    private var digitalGainText: String {
        if abs(state.digitalGainDecibels) < 0.05 {
            return "0.0 dB"
        }
        return String(format: "%+.1f dB", state.digitalGainDecibels)
    }

    private func greenThresholdBinding(
        for channel: MeterColorChannel
    ) -> Binding<Double> {
        Binding(
            get: {
                Double(meterColorSettings.thresholds(for: channel).greenThreshold)
            },
            set: { meterColorSettings.setGreenThreshold($0, for: channel) }
        )
    }

    private func redThresholdBinding(
        for channel: MeterColorChannel
    ) -> Binding<Double> {
        Binding(
            get: {
                Double(meterColorSettings.thresholds(for: channel).redThreshold)
            },
            set: { meterColorSettings.setRedThreshold($0, for: channel) }
        )
    }

    private var bluetoothAlwaysMonitorBinding: Binding<Bool> {
        Binding(
            get: { state.bluetoothMicrophoneAlwaysMonitored },
            set: state.setBluetoothMicrophoneAlwaysMonitored
        )
    }

    private var systemOutputMonitoringBinding: Binding<Bool> {
        Binding(
            get: { state.systemOutputMonitoringEnabled },
            set: state.setSystemOutputMonitoringEnabled
        )
    }

    private var systemOutputStatusColor: Color {
        switch state.systemOutputMonitoringState {
        case .denied, .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var processedMicrophoneStatusColor: Color {
        switch state.processedMicrophoneState {
        case .active:
            return .green
        case .microphoneDenied, .systemAudioDenied, .failed:
            return .red
        case .awaitingRelease:
            // Nothing is broken, but the switch the user just moved has not
            // taken effect yet, so it should not read as a settled state.
            return .orange
        default:
            return .secondary
        }
    }

    private var footerText: String {
        if state.processedMicrophoneState == .active {
            return localized("🔊 is the speaker side and 🎙 is the processed microphone signal. The microphone’s white line is the device input gain. Processed audio goes to a virtual input inside this Mac; Audio Level Bar neither stores nor sends it over the network.")
        }
        if state.systemOutputMonitoringEnabled {
            return localized("The colored 🔊 bar is the system playback signal and its white line is the output volume; the colored 🎙 bar is the input signal and its white line is the input gain. Audio samples are discarded right after the level is computed, never stored or sent.")
        }
        return localized("🔊 is the output volume setting; the colored 🎙 bar is the input signal and its white line is the input gain. While the microphone is monitored, the orange macOS in-use indicator is lit. Audio is never stored or sent.")
    }

    private func thresholdText(_ normalizedValue: Double) -> String {
        let percent = Int((normalizedValue * 100).rounded())
        let decibels = Double(MeterScale.displayFloorDecibels) * (1 - normalizedValue)
        return String(format: "%d%% / %.0f dBFS", percent, decibels)
    }

    private func unavailableControlText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Hands off to the macOS Sound settings, which is the only place an
    /// AirPlay receiver can be connected.
    ///
    /// A receiver on the network is not a Core Audio device, so the picker
    /// beside this button cannot offer one. Once connected there it arrives in
    /// that picker as an ordinary output device.
    private var airPlayControl: some View {
        Button {
            state.openAirPlayOutputSettings()
        } label: {
            Image(systemName: "airplayaudio")
                .font(.headline)
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.primary)
        .help(localized("Choose an AirPlay destination in macOS Sound settings"))
        .accessibilityLabel(localized("AirPlay…"))
    }

    /// The section's icon is the mute control.
    ///
    /// Muting is a frequent action and needs to look like one. A borderless
    /// glyph beside the percentage readout, in caption size and secondary
    /// colour, reads as part of the label; a second icon next to the slider
    /// reads as a button but puts two speakers and two microphones on screen at
    /// once. The header icon is already there, already large, and already the
    /// thing that says which device this section is about — so it carries the
    /// action, and there is no duplicate.
    ///
    /// Speaker and microphone deliberately share one shape. Showing mute state
    /// on the speaker while the microphone keeps a fixed `mic.fill` makes the
    /// same action look as though it works on one and does nothing on the
    /// other.
    @ViewBuilder
    private var outputMuteControl: some View {
        muteControl(
            isAdjustable: state.outputMuteIsAdjustable,
            muted: state.outputMuted,
            onSymbol: "speaker.wave.3.fill",
            offSymbol: "speaker.slash.fill",
            shortcut: KeyboardShortcut("m", modifiers: .command),
            mutedHelp: localized("Unmute the speaker (⌘M)"),
            unmutedHelp: localized("Mute the speaker (⌘M)"),
            mutedLabel: localized("Unmute the speaker"),
            unmutedLabel: localized("Mute the speaker"),
            plainLabel: localized("Speaker"),
            toggle: state.toggleOutputMute
        )
    }

    @ViewBuilder
    private var inputMuteControl: some View {
        muteControl(
            isAdjustable: state.inputMuteIsAdjustable,
            muted: state.inputMuted,
            onSymbol: "mic.fill",
            offSymbol: "mic.slash.fill",
            shortcut: KeyboardShortcut("m", modifiers: [.command, .shift]),
            mutedHelp: localized("Unmute the microphone (⇧⌘M)"),
            unmutedHelp: localized("Mute the microphone (⇧⌘M)"),
            mutedLabel: localized("Unmute the microphone"),
            unmutedLabel: localized("Mute the microphone"),
            plainLabel: localized("Microphone"),
            toggle: state.toggleInputMute
        )
    }

    /// Renders a button when the device accepts mute, and a plain status icon
    /// when it does not. A device with no mute control still needs its section
    /// icon, and a button that cannot do anything is worse than no button.
    @ViewBuilder
    private func muteControl(
        isAdjustable: Bool,
        muted: Bool?,
        onSymbol: String,
        offSymbol: String,
        shortcut: KeyboardShortcut,
        mutedHelp: String,
        unmutedHelp: String,
        mutedLabel: String,
        unmutedLabel: String,
        plainLabel: String,
        toggle: @escaping () -> Void
    ) -> some View {
        if isAdjustable, let muted {
            Button(action: toggle) {
                Image(systemName: muted ? offSymbol : onSymbol)
                    .font(.headline)
                    .frame(width: 18)
                    // The state colour belongs on the glyph, not only on the
                    // button. A bordered button drops its tint entirely while
                    // its window is not the active one, so a muted speaker or
                    // microphone left to the tint alone draws in the plain
                    // label colour — white on a dark panel — and reads as
                    // unmuted, while the red badge beside the picker says
                    // otherwise. Measured on macOS 26.6 with the tint alone:
                    // 256 red pixels in the glyph while the panel was key, 0
                    // while it was inactive, with the slashed symbol correct in
                    // both. Colouring the label survives that state, and the
                    // tint below still fills the bezel while the panel is
                    // active.
                    .foregroundStyle(muted ? Color.red : Color.accentColor)
            }
            .buttonStyle(.bordered)
            .tint(muted ? .red : .accentColor)
            .keyboardShortcut(shortcut)
            .help(muted ? mutedHelp : unmutedHelp)
            .accessibilityLabel(muted ? mutedLabel : unmutedLabel)
        } else {
            Image(systemName: muted == true ? offSymbol : onSymbol)
                .foregroundStyle(muted == true ? Color.red : Color.primary)
                .font(.headline)
                .frame(width: 18)
                .accessibilityLabel(plainLabel)
        }
    }
}

/// Observes `AudioLevels` instead of `AudioState` so a 20 Hz level update
/// relayouts this meter alone, not the device pickers and settings around it.
private struct SystemOutputMeterView: View {
    @ObservedObject var levels: AudioLevels
    @ObservedObject var meterColorSettings: MeterColorSettings
    let monitoringEnabled: Bool
    let isMonitoringActive: Bool
    let outputVolume: Float?
    let outputIsMuted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LargeLevelMeter(
                value: meterValue,
                tint: meterTint,
                primaryText: meterText,
                accessibilityLabelText: accessibilityLabel,
                markerValue: monitoringEnabled ? outputVolume : nil,
                isMuted: outputIsMuted
            )

            if monitoringEnabled {
                peakRow(text: peakText, isMuted: outputIsMuted)
            }
        }
    }

    private var showsLiveLevel: Bool {
        monitoringEnabled && isMonitoringActive
    }

    private var meterValue: Float {
        guard monitoringEnabled else {
            return outputVolume ?? 0
        }
        return showsLiveLevel
            ? MeterScale.normalized(decibels: levels.systemOutput.rmsDecibels)
            : 0
    }

    private var meterText: String {
        guard monitoringEnabled else {
            return percentageText(outputVolume)
        }
        guard showsLiveLevel else {
            return "-- dBFS"
        }
        return decibelText(levels.systemOutput.rmsDecibels)
    }

    private var peakText: String {
        guard showsLiveLevel else {
            return "-- dBFS"
        }
        return decibelText(levels.systemOutput.peakDecibels)
    }

    private var meterTint: Color {
        guard monitoringEnabled else {
            return levelTint(
                for: outputVolume,
                in: .systemOutput,
                settings: meterColorSettings
            )
        }
        guard showsLiveLevel else {
            return .gray
        }
        return levelTint(
            for: MeterScale.normalized(decibels: levels.systemOutput.rmsDecibels),
            in: .systemOutput,
            settings: meterColorSettings
        )
    }

    private var accessibilityLabel: String {
        let baseLabel = monitoringEnabled
            ? localized("Current system playback level. The white line is the output volume")
            : localized("Speaker volume")
        return outputIsMuted ? localized("%@. Speaker is muted", baseLabel) : baseLabel
    }
}

private struct MicrophoneMeterView: View {
    @ObservedObject var levels: AudioLevels
    @ObservedObject var meterColorSettings: MeterColorSettings
    let inputVolume: Float?
    let showsProcessedSource: Bool
    let inputIsMuted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LargeLevelMeter(
                value: MeterScale.normalized(
                    decibels: levels.microphone.rmsDecibels
                ),
                tint: levelTint(
                    for: MeterScale.normalized(
                        decibels: levels.microphone.rmsDecibels
                    ),
                    in: .microphone,
                    settings: meterColorSettings
                ),
                primaryText: decibelText(levels.microphone.rmsDecibels),
                accessibilityLabelText: accessibilityLabel,
                markerValue: inputVolume,
                isMuted: inputIsMuted
            )

            peakRow(
                text: decibelText(levels.microphone.peakDecibels),
                isMuted: inputIsMuted
            )
        }
    }

    private var accessibilityLabel: String {
        let base = showsProcessedSource
            ? localized("Current processed microphone input level. The white line is the device input gain")
            : localized("Current microphone input level. The white line is the input gain")
        return inputIsMuted ? localized("%@. Microphone is muted", base) : base
    }
}

private func peakRow(text: String, isMuted: Bool = false) -> some View {
    HStack {
        Text(localized("Peak"))
            .foregroundStyle(.secondary)
        Spacer()
        Text(text)
            .monospacedDigit()
            .foregroundStyle(isMuted ? Color.red : Color.primary)
    }
    .font(.caption)
}

private func levelTint(
    for level: Float?,
    in channel: MeterColorChannel,
    settings: MeterColorSettings
) -> Color {
    switch settings.band(for: level, in: channel) {
    case .neutral:
        return .gray
    case .green:
        return .green
    case .red:
        return .red
    }
}

private func percentageText(_ value: Float?) -> String {
    guard let value else {
        return "--%"
    }
    return String(format: "%.0f%%", value * 100)
}

private func decibelText(_ value: Float) -> String {
    guard value > MeterScale.displayFloorDecibels else {
        return "−∞ dBFS"
    }
    return String(format: "%.1f dBFS", value)
}
