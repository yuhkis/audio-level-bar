import AppKit
import AudioLevelBarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var audioState: AudioState?
    private var statusBarController: StatusBarController?
    private var quitCoordinator: QuitCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        migrateStatusItemPositionIfNeeded()
        let state = AudioState()
        let meterColorSettings = MeterColorSettings()
        let statusController = StatusBarController(
            state: state,
            meterColorSettings: meterColorSettings
        )
        audioState = state
        statusBarController = statusController
        quitCoordinator = QuitCoordinator(
            scheduler: MainRunLoopScheduler(),
            requestQuit: { state.requestQuit() },
            remainingDeferral: { state.remainingQuitDeferral() },
            removeStatusItem: { statusController.stop() },
            tearDown: { state.stop() },
            letTerminationProceed: {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        )
        state.start()
        statusController.showControlWindow()
    }

    /// Quit, from the menu item or an Apple event. While the quiet window
    /// holds, the menu bar item goes at once and the teardown waits until
    /// 3 s after the last change the window noted, at most
    /// `QuitPlan.deferralMaximum` after the request; see `QuitCoordinator`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let quitCoordinator else {
            return .terminateNow
        }
        switch quitCoordinator.applicationShouldTerminate() {
        case .now:
            return .terminateNow
        case .later:
            return .terminateLater
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusBarController?.showControlWindow()
        return false
    }

    /// Tears down only when Quit's own sequence has not already, as for a
    /// termination that bypassed `applicationShouldTerminate(_:)`.
    func applicationWillTerminate(_ notification: Notification) {
        guard let quitCoordinator else {
            statusBarController?.stop()
            audioState?.stop()
            return
        }
        quitCoordinator.applicationWillTerminate()
    }

    private func migrateStatusItemPositionIfNeeded() {
        let defaults = UserDefaults.standard
        let currentKey = statusItemPositionKey(
            autosaveName: AudioLevelBarIdentity.statusItemAutosaveName
        )
        let legacyKeys = AudioLevelBarIdentity
            .legacyStatusItemAutosaveNames
            .map(statusItemPositionKey)
        SettingsDomainMigration.copyFirstAvailableValue(
            from: legacyKeys,
            to: currentKey,
            in: defaults
        )
    }

    private func statusItemPositionKey(autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }
}

@main
enum AudioLevelBarMain {
    private static let appDelegate = AppDelegate()
    private static var instanceLock: ProcessInstanceLock?

    static func main() {
        if CommandLine.arguments.contains("--build-info") {
            print(AudioLevelBarBuildInfo.report)
            return
        }

        if CommandLine.arguments.contains("--diagnose") {
            AudioDiagnostics.run()
            return
        }

        if CommandLine.arguments.contains("--reclaim-taps") {
            AudioDiagnostics.runTapReclamation()
            return
        }

        if AudioLevelBarIdentity.activateConflictingInstanceIfPresent() {
            return
        }

        do {
            instanceLock = try ProcessInstanceLock(
                identifier: AudioLevelBarIdentity.bundleIdentifier
            )
        } catch {
            _ = AudioLevelBarIdentity.activateConflictingInstanceIfPresent()
            FileHandle.standardError.write(
                Data("Audio Level Bar is already running or cannot acquire its instance lock: \(error)\n".utf8)
            )
            return
        }

        // A copy that does not take this lock (an older bundle on the same
        // Mac) would otherwise race the launch, so the check is repeated after
        // the lock narrows the window.
        if AudioLevelBarIdentity.activateConflictingInstanceIfPresent() {
            instanceLock = nil
            return
        }

        let application = NSApplication.shared
        application.delegate = appDelegate
        application.run()
    }
}
