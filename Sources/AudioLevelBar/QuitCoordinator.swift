import AudioLevelBarCore
import Foundation

/// Quit on the main thread: the termination callbacks, the menu bar item,
/// and `AudioState`'s deferral and teardown, in the order `QuitSequence`
/// allows.
///
/// A Quit request first stops `AudioState` polling and evaluating, and reads
/// how long the teardown waits for a quiet window that holds
/// (`AudioState.requestQuit()`). The menu bar item is removed next, at once,
/// so the app visibly quits whether or not the teardown waits. With no
/// deferral the teardown runs immediately and termination proceeds. With one,
/// termination is answered later. When the deferral comes due, the window is
/// read again (`AudioState.remainingQuitDeferral()`): a change noted
/// meanwhile defers the teardown again, never past the deadline the request
/// fixed, and otherwise the teardown runs and termination is let through. A
/// second Quit meanwhile changes nothing, and a termination that never asked
/// tears down once.
final class QuitCoordinator {
    enum Reply: Equatable {
        /// `NSApplication.TerminateReply.terminateNow`.
        case now
        /// `NSApplication.TerminateReply.terminateLater`.
        case later
    }

    private var sequence = QuitSequence()
    private var statusItemRemoved = false
    private let scheduler: any AudioStateScheduler
    private let requestQuit: () -> TimeInterval
    private let remainingDeferral: () -> TimeInterval
    private let removeStatusItem: () -> Void
    private let tearDown: () -> Void
    private let letTerminationProceed: () -> Void

    /// - Parameters:
    ///   - scheduler: Where the deferred teardown is scheduled on the main
    ///     thread.
    ///   - requestQuit: `AudioState.requestQuit()`.
    ///   - remainingDeferral: `AudioState.remainingQuitDeferral()`.
    ///   - removeStatusItem: Removes the menu bar item and closes the panels.
    ///   - tearDown: `AudioState.stop()`.
    ///   - letTerminationProceed:
    ///     `NSApplication.reply(toApplicationShouldTerminate: true)`.
    init(
        scheduler: any AudioStateScheduler,
        requestQuit: @escaping () -> TimeInterval,
        remainingDeferral: @escaping () -> TimeInterval,
        removeStatusItem: @escaping () -> Void,
        tearDown: @escaping () -> Void,
        letTerminationProceed: @escaping () -> Void
    ) {
        self.scheduler = scheduler
        self.requestQuit = requestQuit
        self.remainingDeferral = remainingDeferral
        self.removeStatusItem = removeStatusItem
        self.tearDown = tearDown
        self.letTerminationProceed = letTerminationProceed
    }

    /// `applicationShouldTerminate(_:)`.
    func applicationShouldTerminate() -> Reply {
        switch sequence.request(deferral: requestQuit) {
        case .tearDownNow:
            removeStatusItemOnce()
            tearDown()
            return .now
        case let .deferTeardown(delay):
            removeStatusItemOnce()
            scheduleDeferralEnd(after: delay)
            return .later
        case .alreadyDeferred:
            return .later
        case .alreadyTornDown:
            return .now
        }
    }

    /// `applicationWillTerminate(_:)`. Tears down only if nothing has yet.
    func applicationWillTerminate() {
        guard sequence.willTerminate() else {
            return
        }
        removeStatusItemOnce()
        tearDown()
    }

    private func scheduleDeferralEnd(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.deferralEnded()
        }
        scheduler.asyncAfter(delay, execute: item)
    }

    private func deferralEnded() {
        switch sequence.deferralEnded(remaining: remainingDeferral) {
        case .tearDown:
            tearDown()
            letTerminationProceed()
        case let .deferAgain(delay):
            scheduleDeferralEnd(after: delay)
        case .nothing:
            break
        }
    }

    private func removeStatusItemOnce() {
        guard !statusItemRemoved else {
            return
        }
        statusItemRemoved = true
        removeStatusItem()
    }
}
