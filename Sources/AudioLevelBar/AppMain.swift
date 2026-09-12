import AppKit
import AudioLevelBarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var audioState: AudioState?
    private var statusBarController: StatusBarController?

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
        state.start()
        statusController.showControlWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusBarController?.showControlWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stop()
        audioState?.stop()
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
