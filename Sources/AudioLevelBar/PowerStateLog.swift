import AppKit
import AudioLevelBarCore
import Foundation

/// Writes the system's sleep and wake to the hal-lifecycle log, and tells the
/// owner of each.
///
/// Going to sleep and waking reconfigure the built-in audio devices through
/// the same configuration changes a Bluetooth headset causes, and coreaudiod's
/// own lines for them do not say they belong to a sleep. A hardware check
/// needs these lines to place them. Nothing is stopped, started or held here;
/// the owner decides what sleep and wake mean for it, after the line is
/// written.
final class PowerStateLog {
    private let center: NotificationCenter
    private let holdGeneration: LifecycleHoldGeneration
    private var observers: [NSObjectProtocol] = []
    /// Main thread, after the will-sleep line.
    var onWillSleep: (() -> Void)?
    /// Main thread, after the did-wake line.
    var onDidWake: (() -> Void)?

    /// `NSWorkspace`'s notification center, the only one that posts the sleep
    /// and wake notifications. `NotificationCenter.default` never does.
    static var defaultCenter: NotificationCenter {
        NSWorkspace.shared.notificationCenter
    }

    /// - Parameter center: `defaultCenter`; a test substitutes its own.
    init(
        center: NotificationCenter = PowerStateLog.defaultCenter,
        holdGeneration: LifecycleHoldGeneration
    ) {
        self.center = center
        self.holdGeneration = holdGeneration
    }

    /// The center observed, for a test.
    var observedCenter: NotificationCenter {
        center
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    /// Main thread. Starts observing; a second call does nothing.
    func start() {
        guard observers.isEmpty else {
            return
        }
        let holdGeneration = holdGeneration
        observers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                HALLifecycleLog.power(.willSleep, generation: holdGeneration.current)
                self?.onWillSleep?()
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                HALLifecycleLog.power(.didWake, generation: holdGeneration.current)
                self?.onDidWake?()
            }
        ]
    }
}
