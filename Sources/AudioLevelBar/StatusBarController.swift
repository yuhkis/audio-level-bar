import AppKit
import AudioLevelBarCore
import SwiftUI

final class StatusBarController: NSObject {
    private static let statusItemWidth: CGFloat = 42
    private static let statusItemRefreshInterval: TimeInterval = 0.5
    private static let bartenderBundleIdentifier = "com.surteesstudios.Bartender"
    private static let bartenderIdentityHoldDuration: TimeInterval = 8
    private static var statusItemMenuHint: String {
        localized("Right-click for the settings menu")
    }

    private let state: AudioState
    private let meterColorSettings: MeterColorSettings
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let popoverPresentation = ControlPanelPresentation()
    private let windowPresentation = ControlPanelPresentation()
    private var controlWindow: NSWindow?
    private var controlWindowShowsLiveContent = false
    private var updateTimer: Timer?
    private var meterImage: NSImage?
    private var renderedMeterSnapshot: StatusBarMeterSnapshot?
    private var heldMeterSnapshot: StatusBarMeterSnapshot?
    private var identityHoldUntil: Date?
    private var lastToolTip: String?
    private var lastAccessibilityLabel: String?
    private var lastAccessibilityValue: String?

    init(state: AudioState, meterColorSettings: MeterColorSettings) {
        self.state = state
        self.meterColorSettings = meterColorSettings
        statusItem = NSStatusBar.system.statusItem(withLength: Self.statusItemWidth)
        super.init()

        statusItem.autosaveName = AudioLevelBarIdentity.statusItemAutosaveName
        configureStatusItem()
        configureBartenderCompatibility()
        configurePopover()
        startUpdatingMeter()
    }

    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        popover.delegate = nil
        popover.close()
        popover.contentViewController = nil
        controlWindow?.delegate = nil
        controlWindow?.close()
        controlWindow = nil
        controlWindowShowsLiveContent = false
        state.setLevelMetersVisible(false)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc
    func showControlWindow() {
        let window: NSWindow
        if let existingWindow = controlWindow {
            window = existingWindow
        } else {
            window = makeControlWindow()
            controlWindow = window
        }

        if !controlWindowShowsLiveContent {
            window.contentViewController = makeContentViewController(
                presentation: windowPresentation
            )
            controlWindowShowsLiveContent = true
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateLevelMeterVisibility()
    }

    @objc
    func showSettings() {
        popoverPresentation.showsSettings = true

        guard let button = statusItem.button else {
            windowPresentation.showsSettings = true
            showControlWindow()
            return
        }

        if !popover.isShown {
            showPopover(from: button)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.identifier = NSUserInterfaceItemIdentifier(
            AudioLevelBarIdentity.statusItemAutosaveName
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        updateMeter()
        let image = StatusBarMeterImage.make { [weak self] in
            self?.renderedMeterSnapshot
        }
        meterImage = image
        button.image = image
        button.needsDisplay = true
    }

    private func configureBartenderCompatibility() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        if !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bartenderBundleIdentifier
        ).isEmpty {
            beginBartenderIdentityHold()
        }
    }

    private func beginBartenderIdentityHold() {
        heldMeterSnapshot = renderedMeterSnapshot
        identityHoldUntil = Date().addingTimeInterval(
            Self.bartenderIdentityHoldDuration
        )
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(
            width: ControlPanelLayout.width,
            height: ControlPanelLayout.height
        )
        popover.delegate = self
        // The SwiftUI content is built on show and released on close. A
        // retained NSHostingController keeps observing AudioState, so a
        // closed popover would relayout the whole 400x640 tree on every
        // meter update.
    }

    private func makeControlWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ControlPanelLayout.width,
                height: ControlPanelLayout.height
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Audio Level Bar"
        window.contentViewController = makeIdleContentViewController()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func makeContentViewController(
        presentation: ControlPanelPresentation
    ) -> NSViewController {
        NSHostingController(
            rootView: PopoverView(
                state: state,
                meterColorSettings: meterColorSettings,
                presentation: presentation
            )
        )
    }

    private func makeStatusItemMenu() -> NSMenu {
        let menu = NSMenu()
        // Muting is the most frequent thing to want from the menu bar, so it
        // belongs here rather than behind the popup and a small glyph inside
        // it.
        // The menu is rebuilt on every right-click, so these titles can state
        // the current state rather than toggle blindly.
        menu.addItem(
            muteMenuItem(
                title: state.outputMuted == true
                    ? localized("Unmute Speaker")
                    : localized("Mute Speaker"),
                action: #selector(toggleOutputMute),
                isEnabled: state.outputMuteIsAdjustable && state.outputMuted != nil,
                keyEquivalent: "m",
                modifiers: .command
            )
        )
        menu.addItem(
            muteMenuItem(
                title: state.inputMuted == true
                    ? localized("Unmute Microphone")
                    : localized("Mute Microphone"),
                action: #selector(toggleInputMute),
                isEnabled: state.inputMuteIsAdjustable && state.inputMuted != nil,
                keyEquivalent: "m",
                modifiers: [.command, .shift]
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(title: localized("Settings…"), action: #selector(showSettings), target: self)
        )
        menu.addItem(
            menuItem(
                title: localized("Open Control Window"),
                action: #selector(showControlWindow),
                target: self
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: localized("Quit Audio Level Bar"),
                action: #selector(NSApplication.terminate(_:)),
                target: NSApp,
                keyEquivalent: "q"
            )
        )
        return menu
    }

    private func muteMenuItem(
        title: String,
        action: Selector,
        isEnabled: Bool,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = menuItem(
            title: title,
            action: action,
            target: self,
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifiers
        // A device that reports no mute control, or none yet, leaves the item
        // visible but dimmed. Hiding it would make the menu's shape depend on
        // the current device.
        item.isEnabled = isEnabled
        if !isEnabled {
            item.action = nil
        }
        return item
    }

    @objc private func toggleOutputMute() {
        state.toggleOutputMute()
    }

    @objc private func toggleInputMute() {
        state.toggleInputMute()
    }

    private func menuItem(
        title: String,
        action: Selector,
        target: AnyObject?,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = target
        return item
    }

    /// Keeps the closed window at its size and screen position without
    /// keeping its SwiftUI tree alive.
    private func makeIdleContentViewController() -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: ControlPanelLayout.width,
                height: ControlPanelLayout.height
            )
        )
        return controller
    }

    private func updateLevelMeterVisibility() {
        let controlWindowIsVisible = controlWindowShowsLiveContent
            && controlWindow?.isVisible == true
        state.setLevelMetersVisible(popover.isShown || controlWindowIsVisible)
    }

    private func startUpdatingMeter() {
        let timer = Timer(
            timeInterval: Self.statusItemRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.updateMeter()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    private func updateMeter() {
        guard let button = statusItem.button else {
            return
        }

        // Recheck here as well as on show and close: hiding the app takes the
        // control window off screen without a close notification.
        updateLevelMeterVisibility()

        let showsLiveSystemOutput = state.systemOutputMonitoringEnabled
        let outputIsMuted = state.outputMuted == true
        let inputIsMuted = state.inputMuted == true
        let systemOutputDecibels = state.levels.systemOutput.rmsDecibels
        let microphoneDecibels = state.levels.microphone.rmsDecibels
        let outputText: String
        if showsLiveSystemOutput {
            outputText = state.systemOutputMonitoringState == .active
                ? compactDecibelText(systemOutputDecibels)
                : "--"
        } else if let volume = state.outputVolume {
            outputText = String(format: "%.0f%%", volume * 100)
        } else {
            outputText = "--"
        }

        let microphoneText: String
        let microphoneIsMetering = state.microphoneLevelIsLive
        if microphoneIsMetering {
            microphoneText = microphoneDecibels > MeterScale.displayFloorDecibels
                ? String(format: "%.0f", microphoneDecibels)
                : "−∞"
        } else {
            // Denied, a Bluetooth input the app does not open, or a start not
            // yet running. Either way nothing is being measured, which is not
            // the same as measuring silence.
            microphoneText = "--"
        }

        let outputLevel: CGFloat?
        if showsLiveSystemOutput, state.systemOutputMonitoringState == .active {
            outputLevel = CGFloat(
                MeterScale.normalized(decibels: systemOutputDecibels)
            )
        } else if showsLiveSystemOutput {
            outputLevel = nil
        } else {
            outputLevel = state.outputVolume.map {
                CGFloat(min(max($0, 0), 1))
            }
        }
        let outputMarker = showsLiveSystemOutput
            ? state.outputVolume.map { CGFloat(min(max($0, 0), 1)) }
            : nil
        let microphoneLevel = microphoneIsMetering
            ? CGFloat(MeterScale.normalized(decibels: microphoneDecibels))
            : nil
        let inputGain = state.inputVolume.map {
            CGFloat(min(max($0, 0), 1))
        }
        let outputColorBand = meterColorSettings.band(
            for: outputLevel.map { Float($0) },
            in: .systemOutput
        )
        let microphoneColorBand = meterColorSettings.band(
            for: microphoneLevel.map { Float($0) },
            in: .microphone
        )

        let snapshot = StatusBarMeterSnapshot(
            outputLevel: quantizedMeterLevel(outputLevel),
            outputText: outputText,
            outputColorBand: outputColorBand,
            outputMarker: quantizedMeterLevel(outputMarker),
            outputShowsLiveLevel: showsLiveSystemOutput,
            outputMuted: outputIsMuted,
            inputMuted: inputIsMuted,
            microphoneLevel: quantizedMeterLevel(microphoneLevel),
            microphoneText: microphoneText,
            microphoneColorBand: microphoneColorBand,
            inputGain: quantizedMeterLevel(inputGain)
        )
        let visualSnapshot: StatusBarMeterSnapshot
        if let identityHoldUntil, identityHoldUntil > Date() {
            visualSnapshot = heldMeterSnapshot ?? snapshot
        } else {
            self.identityHoldUntil = nil
            heldMeterSnapshot = nil
            visualSnapshot = snapshot
        }
        if renderedMeterSnapshot != visualSnapshot {
            renderedMeterSnapshot = visualSnapshot
            meterImage?.recache()
            button.needsDisplay = true
        }
        let outputAccessibilityText: String
        let toolTip: String
        let accessibilityLabel: String
        if showsLiveSystemOutput {
            let outputVolumeText = state.outputVolume.map {
                localized(", output volume %.0f percent", $0 * 100)
            } ?? ""
            let muteText = outputIsMuted ? localized(", speaker is muted") : ""
            outputAccessibilityText = localized(
                "system playback %1$@ decibels%2$@%3$@",
                outputText,
                outputVolumeText,
                muteText
            )
            toolTip = outputIsMuted
                ? localized("Audio Level Bar — Speaker muted. Top: system playback level (white line: output volume). Bottom: microphone input level (white line: input gain)")
                : localized("Audio Level Bar — Top: system playback level (white line: output volume). Bottom: microphone input level (white line: input gain)")
            accessibilityLabel = outputIsMuted
                ? localized("Audio Level Bar. Speaker muted. The top row is the system playback level and the white line is the output volume. The bottom row is the microphone input level and the white line is the input gain")
                : localized("Audio Level Bar. The top row is the system playback level and the white line is the output volume. The bottom row is the microphone input level and the white line is the input gain")
        } else {
            let muteText = outputIsMuted ? localized(", muted") : ""
            outputAccessibilityText = localized("speaker %1$@%2$@", outputText, muteText)
            toolTip = outputIsMuted
                ? localized("Audio Level Bar — Speaker muted. Top: speaker volume setting. Bottom: microphone input level (white line: input gain)")
                : localized("Audio Level Bar — Top: speaker volume setting. Bottom: microphone input level (white line: input gain)")
            accessibilityLabel = outputIsMuted
                ? localized("Audio Level Bar. Speaker muted. The top row is the speaker volume setting. The bottom row is the microphone input level and the white line is the input gain")
                : localized("Audio Level Bar. The top row is the speaker volume setting. The bottom row is the microphone input level and the white line is the input gain")
        }
        let inputGainText = inputGain.map {
            localized(", input gain %.0f percent", $0 * 100)
        } ?? ""
        let inputMuteText = inputIsMuted ? localized(", microphone is muted") : ""
        let accessibilityValue: String
        if state.microphonePermission == .authorized, !microphoneIsMetering {
            accessibilityValue = localized(
                "%1$@, microphone level not measured%2$@%3$@",
                outputAccessibilityText,
                inputGainText,
                inputMuteText
            )
        } else {
            accessibilityValue = localized(
                "%1$@, microphone %2$@ decibels%3$@%4$@",
                outputAccessibilityText,
                microphoneText,
                inputGainText,
                inputMuteText
            )
        }
        if lastToolTip != toolTip {
            button.toolTip = localized("%1$@. %2$@", toolTip, Self.statusItemMenuHint)
            lastToolTip = toolTip
        }
        if lastAccessibilityLabel != accessibilityLabel {
            button.setAccessibilityLabel(accessibilityLabel)
            lastAccessibilityLabel = accessibilityLabel
        }
        if lastAccessibilityValue != accessibilityValue {
            button.setAccessibilityValue(accessibilityValue)
            lastAccessibilityValue = accessibilityValue
        }
    }

    private func quantizedMeterLevel(_ level: CGFloat?) -> CGFloat? {
        level.map { (min(max($0, 0), 1) * 64).rounded() / 64 }
    }

    private func compactDecibelText(_ decibels: Float) -> String {
        decibels > MeterScale.displayFloorDecibels
            ? String(format: "%.0f", decibels)
            : "−∞"
    }

    @objc
    private func workspaceApplicationDidLaunch(_ notification: Notification) {
        guard
            let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication,
            application.bundleIdentifier == Self.bartenderBundleIdentifier
        else {
            return
        }
        beginBartenderIdentityHold()
    }

    @objc
    private func handleStatusItemClick() {
        guard let button = statusItem.button else {
            return
        }

        if isSecondaryClick(NSApp.currentEvent) {
            showStatusItemMenu(from: button)
        } else {
            togglePopover(from: button)
        }
    }

    private func isSecondaryClick(_ event: NSEvent?) -> Bool {
        guard let event else {
            return false
        }

        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            return true
        case .leftMouseUp, .leftMouseDown:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    private func showStatusItemMenu(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        }

        // NSStatusBarButton is flipped, so maxY is the edge next to the desktop.
        makeStatusItemMenu().popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.maxY + 5),
            in: button
        )
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverPresentation.showsSettings = false
            showPopover(from: button)
        }
    }

    private func showPopover(from button: NSStatusBarButton) {
        popover.contentViewController = makeContentViewController(
            presentation: popoverPresentation
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        updateLevelMeterVisibility()
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        updateLevelMeterVisibility()
        // Release the hosting controller after AppKit finishes closing, not
        // from inside its own close notification.
        DispatchQueue.main.async { [weak self] in
            guard let self, !popover.isShown else {
                return
            }
            popover.contentViewController = nil
        }
    }
}

extension StatusBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === controlWindow else {
            return
        }
        controlWindowShowsLiveContent = false
        updateLevelMeterVisibility()
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                let window = controlWindow,
                !controlWindowShowsLiveContent
            else {
                return
            }
            window.contentViewController = makeIdleContentViewController()
        }
    }
}

private struct StatusBarMeterSnapshot: Equatable {
    let outputLevel: CGFloat?
    let outputText: String
    let outputColorBand: MeterColorBand
    let outputMarker: CGFloat?
    let outputShowsLiveLevel: Bool
    let outputMuted: Bool
    let inputMuted: Bool
    let microphoneLevel: CGFloat?
    let microphoneText: String
    let microphoneColorBand: MeterColorBand
    let inputGain: CGFloat?
}

private enum StatusBarMeterImage {
    private static let imageSize = NSSize(width: 34, height: 22)
    private static let barHorizontalInset: CGFloat = 1.5
    private static let barHeight: CGFloat = 3
    private static let barCornerRadius: CGFloat = 1.5
    private static let labelFont = NSFont.monospacedDigitSystemFont(
        ofSize: 6.2,
        weight: .medium
    )
    private static let baseSymbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: 6.5,
        weight: .medium
    )

    static func make(
        snapshotProvider: @escaping () -> StatusBarMeterSnapshot?
    ) -> NSImage {
        let image = NSImage(size: imageSize, flipped: false) { bounds in
            guard let snapshot = snapshotProvider() else {
                return true
            }
            drawLabel(
                symbolName: snapshot.outputMuted ? "speaker.slash.fill" : "speaker.fill",
                symbolColor: snapshot.outputMuted ? .systemRed : .labelColor,
                text: snapshot.outputText,
                textColor: snapshot.outputMuted ? .systemRed : .labelColor,
                in: NSRect(x: bounds.minX, y: bounds.minY + 14, width: bounds.width, height: 7.5)
            )
            drawBar(
                in: NSRect(
                    x: bounds.minX + barHorizontalInset,
                    y: bounds.minY + 10.75,
                    width: bounds.width - barHorizontalInset * 2,
                    height: barHeight
                ),
                level: snapshot.outputLevel,
                colorBand: snapshot.outputColorBand,
                markerLevel: snapshot.outputMarker,
                isMuted: snapshot.outputMuted
            )
            drawLabel(
                symbolName: snapshot.inputMuted ? "mic.slash.fill" : "mic.fill",
                symbolColor: snapshot.inputMuted ? .systemRed : .labelColor,
                text: snapshot.microphoneText,
                textColor: snapshot.inputMuted ? .systemRed : .labelColor,
                in: NSRect(x: bounds.minX, y: bounds.minY + 3, width: bounds.width, height: 7.5)
            )
            drawBar(
                in: NSRect(
                    x: bounds.minX + barHorizontalInset,
                    y: bounds.minY + 0.25,
                    width: bounds.width - barHorizontalInset * 2,
                    height: barHeight
                ),
                level: snapshot.microphoneLevel,
                colorBand: snapshot.microphoneColorBand,
                markerLevel: snapshot.inputGain,
                isMuted: snapshot.inputMuted
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawLabel(
        symbolName: String,
        symbolColor: NSColor,
        text: String,
        textColor: NSColor = .labelColor,
        in rect: NSRect
    ) {
        let symbolSize: CGFloat = 6.5
        let symbolRect = NSRect(
            x: rect.minX,
            y: rect.midY - symbolSize / 2,
            width: symbolSize,
            height: symbolSize
        )
        NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?
        .withSymbolConfiguration(
            baseSymbolConfiguration.applying(
                NSImage.SymbolConfiguration(hierarchicalColor: symbolColor)
            )
        )?
        .draw(in: symbolRect)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: textColor
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: symbolRect.maxX + 1.5,
                y: rect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    private static func drawBar(
        in rect: NSRect,
        level: CGFloat?,
        colorBand: MeterColorBand,
        markerLevel: CGFloat?,
        isMuted: Bool = false
    ) {
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: barCornerRadius,
            yRadius: barCornerRadius
        ).fill()

        if let level {
            let clampedLevel = min(max(level, 0), 1)
            if clampedLevel > 0 {
                let fillRect = NSRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width * clampedLevel,
                    height: rect.height
                )
                fillColor(for: colorBand).setFill()
                NSBezierPath(
                    roundedRect: fillRect,
                    xRadius: min(barCornerRadius, fillRect.width / 2),
                    yRadius: barCornerRadius
                ).fill()
            }
        }

        if let markerLevel {
            drawGainMarker(at: markerLevel, in: rect, isMuted: isMuted)
        }
    }

    private static func drawGainMarker(
        at level: CGFloat,
        in rect: NSRect,
        isMuted: Bool
    ) {
        let markerX = min(
            max(rect.minX + rect.width * min(max(level, 0), 1), rect.minX + 0.5),
            rect.maxX - 0.5
        )
        let markerRect = NSRect(
            x: markerX - 0.5,
            y: rect.minY - 0.5,
            width: 1,
            height: rect.height + 1
        )

        NSColor.black.withAlphaComponent(0.5).setStroke()
        let outline = NSBezierPath()
        outline.lineWidth = 2
        outline.move(to: NSPoint(x: markerRect.midX, y: markerRect.minY))
        outline.line(to: NSPoint(x: markerRect.midX, y: markerRect.maxY))
        outline.stroke()

        // The marker shows the volume or gain, which is what mute silences.
        (isMuted ? NSColor.systemRed : NSColor.white).setFill()
        markerRect.fill()
    }

    private static func fillColor(for band: MeterColorBand) -> NSColor {
        switch band {
        case .neutral:
            return NSColor.secondaryLabelColor
        case .green:
            return NSColor.systemGreen
        case .red:
            return NSColor.systemRed
        }
    }
}
