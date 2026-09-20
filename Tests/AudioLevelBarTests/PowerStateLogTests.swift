import AppKit
import AudioLevelBarCore
import XCTest
@testable import AudioLevelBar

/// Sleep and wake lines, from a substituted notification center.
final class PowerStateLogTests: XCTestCase {
    override func tearDown() {
        HALLifecycleLog.observer = nil
        super.tearDown()
    }

    func testSleepAndWakeAreLoggedWithTheCurrentGeneration() {
        let lock = NSLock()
        var lines: [String] = []
        HALLifecycleLog.observer = { line in
            guard line.hasPrefix("power ") else {
                return
            }
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        let center = NotificationCenter()
        let generation = LifecycleHoldGeneration()
        generation.advance()
        let log = PowerStateLog(center: center, holdGeneration: generation)
        log.start()
        log.start()

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        generation.advance()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(lines, ["power will-sleep gen=1", "power did-wake gen=2"])
    }

    func testTheDefaultCenterIsTheWorkspaceCenterThatPostsSleepAndWake() {
        let log = PowerStateLog(holdGeneration: LifecycleHoldGeneration())
        XCTAssertTrue(log.observedCenter === NSWorkspace.shared.notificationCenter)
        XCTAssertFalse(log.observedCenter === NotificationCenter.default)
    }

    func testNothingIsLoggedAfterTheLogIsReleased() {
        var count = 0
        HALLifecycleLog.observer = { line in
            if line.hasPrefix("power ") {
                count += 1
            }
        }
        let center = NotificationCenter()
        var log: PowerStateLog? = PowerStateLog(center: center, holdGeneration: LifecycleHoldGeneration())
        log?.start()
        log = nil

        center.post(name: NSWorkspace.willSleepNotification, object: nil)

        XCTAssertEqual(count, 0)
    }
}
