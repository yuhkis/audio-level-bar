import AudioLevelBarCore
import CoreAudio
import XCTest
@testable import AudioLevelBar

/// The HAL system-object listeners, through a fake that never reaches
/// coreaudiod.
final class SystemAudioNotificationsTests: XCTestCase {
    private let timeout: TimeInterval = 5
    private let systemObject = SystemAudioNotifications.systemObject

    private func startedNotifications(
        hal: FakeHALLifecycleCalls,
        generation: LifecycleHoldGeneration
    ) -> SystemAudioNotifications {
        let notifications = SystemAudioNotifications(halCalls: hal, holdGeneration: generation)
        notifications.start()
        notifications.listenerQueue.sync {}
        return notifications
    }

    func testListensOnTheSystemObjectForEveryNotification() {
        let hal = FakeHALLifecycleCalls()
        _ = startedNotifications(hal: hal, generation: LifecycleHoldGeneration())

        XCTAssertEqual(
            hal.listenerSelectors(on: systemObject),
            HALSystemNotification.allCases.map(\.selector)
        )
        XCTAssertEqual(
            hal.lifecycleCalls,
            [],
            "registering listeners creates, starts, stops and destroys nothing"
        )
    }

    func testDefaultDeviceChangeAdvancesTheGenerationBeforeTheMainThreadHearsOfIt() {
        let hal = FakeHALLifecycleCalls()
        let generation = LifecycleHoldGeneration()
        let notifications = startedNotifications(hal: hal, generation: generation)
        let delivered = expectation(description: "delivered")
        var received: [HALSystemNotification] = []
        notifications.onNotification = { notification in
            XCTAssertTrue(Thread.isMainThread)
            received.append(notification)
            delivered.fulfill()
        }
        let token = generation.current

        notifications.listenerQueue.sync {
            hal.fireListener(
                deviceID: systemObject,
                selector: HALSystemNotification.defaultOutput.selector
            )
        }
        XCTAssertFalse(generation.isCurrent(token), "advanced on the listener queue, before main ran")
        XCTAssertTrue(received.isEmpty)

        wait(for: [delivered], timeout: timeout)
        XCTAssertEqual(received, [.defaultOutput])
    }

    func testServiceRestartAdvancesTheGeneration() {
        let hal = FakeHALLifecycleCalls()
        let generation = LifecycleHoldGeneration()
        let notifications = startedNotifications(hal: hal, generation: generation)
        let delivered = expectation(description: "delivered")
        notifications.onNotification = { notification in
            XCTAssertEqual(notification, .serviceRestarted)
            delivered.fulfill()
        }
        let token = generation.current

        notifications.listenerQueue.sync {
            hal.fireListener(
                deviceID: systemObject,
                selector: HALSystemNotification.serviceRestarted.selector
            )
        }

        XCTAssertFalse(generation.isCurrent(token))
        wait(for: [delivered], timeout: timeout)
    }

    func testDeviceListChangeLeavesTheGenerationAlone() {
        let hal = FakeHALLifecycleCalls()
        let generation = LifecycleHoldGeneration()
        let notifications = startedNotifications(hal: hal, generation: generation)
        let delivered = expectation(description: "delivered")
        notifications.onNotification = { notification in
            XCTAssertEqual(notification, .devices)
            delivered.fulfill()
        }
        let token = generation.current

        notifications.listenerQueue.sync {
            hal.fireListener(
                deviceID: systemObject,
                selector: HALSystemNotification.devices.selector
            )
        }

        wait(for: [delivered], timeout: timeout)
        XCTAssertTrue(
            generation.isCurrent(token),
            "the app's own aggregate devices change the list; only the poll decides"
        )
    }

    func testServiceRestartForgetsOnTheListenerQueueBeforeTheMainThreadHearsOfIt() {
        let hal = FakeHALLifecycleCalls()
        let generation = LifecycleHoldGeneration()
        let meterHAL = FakeHALLifecycleCalls()
        let meter = SystemOutputMeter(halCalls: meterHAL, holdGeneration: generation)
        let started = expectation(description: "started")
        meter.onStarted = { started.fulfill() }
        meter.start(deviceUID: "output")
        wait(for: [started], timeout: timeout)
        meter.onStarted = nil
        let built = meterHAL.lifecycleCalls

        let notifications = SystemAudioNotifications(halCalls: hal, holdGeneration: generation)
        notifications.onServiceRestartedOnListenerQueue = {
            meter.forgetAfterServiceRestart()
        }
        notifications.start()
        notifications.listenerQueue.sync {}
        let lines = LineCollector()
        HALLifecycleLog.observer = { lines.append($0) }
        defer { HALLifecycleLog.observer = nil }

        notifications.listenerQueue.sync {
            hal.fireListener(
                deviceID: systemObject,
                selector: HALSystemNotification.serviceRestarted.selector
            )
        }
        // A stop the main thread issues before its own recovery runs, with
        // the generation current after the advance.
        meter.stop()
        meter.lifecycleQueue.sync {}

        XCTAssertEqual(meterHAL.lifecycleCalls, built, "nothing is destroyed under an ID the new server may reuse")
        XCTAssertTrue(
            lines.values.contains("quiet-window advance source=service-restarted gen=\(generation.current)"),
            "the advance on the listener queue writes its own line"
        )
    }

    func testDeviceListChangeWritesNoAdvanceLine() {
        let hal = FakeHALLifecycleCalls()
        let notifications = startedNotifications(hal: hal, generation: LifecycleHoldGeneration())
        let lines = LineCollector()
        HALLifecycleLog.observer = { lines.append($0) }
        defer { HALLifecycleLog.observer = nil }
        var forgot = false
        notifications.onServiceRestartedOnListenerQueue = { forgot = true }

        notifications.listenerQueue.sync {
            hal.fireListener(deviceID: systemObject, selector: HALSystemNotification.devices.selector)
        }

        XCTAssertFalse(lines.values.contains { $0.hasPrefix("quiet-window advance") })
        XCTAssertFalse(forgot)
    }

    func testStopRemovesEveryListener() {
        let hal = FakeHALLifecycleCalls()
        let notifications = startedNotifications(hal: hal, generation: LifecycleHoldGeneration())

        notifications.stop()
        notifications.listenerQueue.sync {}

        XCTAssertEqual(hal.listenerSelectors(on: systemObject), [])
        XCTAssertEqual(
            hal.calls.filter { $0 == .removePropertyListener(systemObject) }.count,
            HALSystemNotification.allCases.count
        )
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
}
