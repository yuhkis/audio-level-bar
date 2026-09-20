import XCTest
@testable import AudioLevelBarCore

final class LifecycleQuietWindowTests: XCTestCase {
    private func admission(
        _ window: LifecycleQuietWindow,
        at now: TimeInterval,
        fresh: TimeInterval?,
        writes: Int = 0
    ) -> LifecycleQuietWindow.Admission {
        window.admission(at: now, freshestSnapshotIssuedAt: fresh, outstandingDefaultWrites: writes)
    }

    func testUnarmedWindowNeitherHoldsNorReleases() {
        var window = LifecycleQuietWindow()

        XCTAssertFalse(window.isArmed)
        XCTAssertNil(window.releaseTime)
        XCTAssertFalse(window.isHolding(at: 100))
        XCTAssertEqual(admission(window, at: 100, fresh: nil), .full)
        XCTAssertFalse(window.takeRelease(at: 100))
        XCTAssertFalse(window.takeRelease(at: 1_000))
    }

    func testSingleChangeHoldsForTheSettlePeriod() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)

        XCTAssertTrue(window.isArmed)
        XCTAssertEqual(window.releaseTime, 103)
        XCTAssertTrue(window.isHolding(at: 100))
        XCTAssertTrue(window.isHolding(at: 102.99))
        XCTAssertFalse(window.isHolding(at: 103))
    }

    func testChangeDuringTheWindowExtendsIt() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)
        window.noteChange(at: 102)

        XCTAssertEqual(window.releaseTime, 105)
        XCTAssertTrue(window.isHolding(at: 104.9))
        XCTAssertFalse(window.takeRelease(at: 104.9))
        XCTAssertTrue(window.takeRelease(at: 105))
    }

    func testContinuousChangesReleaseAtTheCap() {
        var window = LifecycleQuietWindow()
        for offset in stride(from: 0.0, through: 14.0, by: 2.0) {
            window.noteChange(at: 100 + offset)
        }

        XCTAssertEqual(window.releaseTime, 115)
        XCTAssertTrue(window.isHolding(at: 114.99))
        XCTAssertFalse(window.isHolding(at: 115))
        XCTAssertTrue(window.takeRelease(at: 115))
    }

    func testReleaseIsTakenExactlyOnce() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)

        XCTAssertFalse(window.takeRelease(at: 102))
        XCTAssertTrue(window.takeRelease(at: 103))
        XCTAssertFalse(window.takeRelease(at: 104))
        XCTAssertFalse(window.isArmed)
        XCTAssertFalse(window.isHolding(at: 104))
    }

    func testChangeAfterSettleExpiryButBeforeTheCapHoldsAgain() throws {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)
        // Noted once the settle period has run out, before any evaluation
        // took the release: it holds again rather than being acted on at once.
        window.noteChange(at: 103.1)

        XCTAssertFalse(window.hasCarriedChange)
        XCTAssertEqual(window.firstChange, 100)
        XCTAssertEqual(window.lastChange, 103.1)
        XCTAssertEqual(try XCTUnwrap(window.releaseTime), 106.1, accuracy: 1e-9)
        XCTAssertTrue(window.isHolding(at: 103.1))
        XCTAssertEqual(admission(window, at: 103.1, fresh: 103.1), .hold)
        XCTAssertFalse(window.takeRelease(at: 103.1))

        XCTAssertEqual(admission(window, at: 106.2, fresh: 106.2), .full)
        XCTAssertTrue(window.takeRelease(at: 106.2))
        XCTAssertFalse(window.isArmed)
    }

    func testChangeExactlyAtTheCapIsCarriedIntoTheNextWindow() {
        var window = LifecycleQuietWindow()
        for offset in stride(from: 0.0, through: 14.0, by: 2.0) {
            window.noteChange(at: 100 + offset)
        }
        XCTAssertEqual(window.releaseTime, 115)

        // A change at the cap, and more after it, do not extend the window.
        window.noteChange(at: 115)
        window.noteChange(at: 116)
        XCTAssertEqual(window.releaseTime, 115)
        XCTAssertFalse(window.isHolding(at: 116))
        XCTAssertEqual(window.carriedFirstChange, 115)
        XCTAssertEqual(window.carriedLastChange, 116)

        XCTAssertTrue(window.takeRelease(at: 116))
        XCTAssertEqual(window.firstChange, 115)
        XCTAssertEqual(window.lastChange, 116)
        XCTAssertEqual(window.releaseTime, 119)
        XCTAssertTrue(window.isHolding(at: 116))
    }

    func testCarriedChangesKeepTheirOwnCap() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)
        // No evaluation takes the release for a long time while changes keep
        // coming. Until the cap they extend the window; from the cap on they
        // are carried, and the carried window is capped from its own first
        // change.
        for offset in stride(from: 10.0, through: 30.0, by: 2.0) {
            window.noteChange(at: 100 + offset)
        }
        XCTAssertEqual(window.lastChange, 114)
        XCTAssertEqual(window.releaseTime, 115)
        XCTAssertEqual(window.carriedFirstChange, 116)
        XCTAssertEqual(window.carriedLastChange, 130)

        XCTAssertTrue(window.takeRelease(at: 130))
        XCTAssertEqual(window.firstChange, 116)
        XCTAssertEqual(window.releaseTime, 131)
        XCTAssertTrue(window.isHolding(at: 130))
        XCTAssertFalse(window.takeRelease(at: 130))

        // Its cap cut the settle period of the change at 130 short. The rest
        // of that period still holds.
        XCTAssertTrue(window.takeRelease(at: 131))
        XCTAssertTrue(window.isArmed)
        XCTAssertEqual(window.releaseTime, 133)
        XCTAssertTrue(window.isHolding(at: 132))
        XCTAssertTrue(window.takeRelease(at: 133))
        XCTAssertFalse(window.isArmed)
    }

    func testChangesThatNeverStopStillReleaseAtLeastEveryCap() {
        // A change on every poll, noted before the evaluation that follows it,
        // as the owner does, with that poll already applied.
        var window = LifecycleQuietWindow()
        var releases: [TimeInterval] = []
        var now: TimeInterval = 0
        while now <= 61 {
            window.noteChange(at: now)
            let admitted = admission(window, at: now, fresh: now)
            XCTAssertNotEqual(admitted, .full, "nothing starts while the changes keep coming, at \(now)")
            if admitted == .stopsOnly {
                XCTAssertTrue(window.takeRelease(at: now))
                releases.append(now)
            }
            now += 0.25
        }

        XCTAssertEqual(releases, [15, 30, 45, 60], "stops still happen at least every cap")
        XCTAssertTrue(window.isHolding(at: now), "the next window holds after each release")
    }

    func testStartsAreAdmittedThreeSecondsAfterTheLastChangeOfAStream() {
        var window = LifecycleQuietWindow()
        var admissions: [(TimeInterval, LifecycleQuietWindow.Admission)] = []
        var now: TimeInterval = 0
        while now <= 30 {
            if now <= 20 {
                window.noteChange(at: now)
            }
            let admitted = admission(window, at: now, fresh: now)
            if admitted != .hold {
                admissions.append((now, admitted))
                if window.isArmed {
                    XCTAssertTrue(window.takeRelease(at: now))
                }
            }
            now += 0.25
        }

        XCTAssertEqual(admissions.first?.0, 15)
        XCTAssertEqual(admissions.first?.1, .stopsOnly)
        let firstFull = admissions.first { $0.1 == .full }
        XCTAssertEqual(firstFull?.0, 23, "the first start comes 3 s after the last change at 20")
        XCTAssertFalse(
            admissions.contains { $0.0 < 23 && $0.1 == .full },
            "no evaluation between the cap and 3 s of quiet admits starts"
        )
    }

    func testCapForcedReleaseAdmitsStopsOnly() throws {
        var window = LifecycleQuietWindow()
        for change in [100, 102.5, 105, 107.5, 110, 112.5, 114.9] {
            window.noteChange(at: change)
        }
        XCTAssertEqual(window.releaseTime, 115)

        XCTAssertEqual(admission(window, at: 115, fresh: 115), .stopsOnly)
        XCTAssertTrue(window.takeRelease(at: 115))

        // Starts wait for the rest of the settle period of the change at
        // 114.9, and stops are held again meanwhile.
        XCTAssertTrue(window.isArmed)
        XCTAssertEqual(try XCTUnwrap(window.releaseTime), 117.9, accuracy: 1e-9)
        XCTAssertEqual(admission(window, at: 116, fresh: 116), .hold)
        XCTAssertEqual(admission(window, at: 118, fresh: 118), .full)
        XCTAssertTrue(window.takeRelease(at: 118))
        XCTAssertFalse(window.isArmed)
    }

    func testCarriedChangeAdmitsStopsOnly() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)
        window.noteChange(at: 112)
        // At the cap, and 3 s after the last change: the settle period alone
        // would admit starts, but a change is carried past the cap.
        window.noteChange(at: 115)
        XCTAssertTrue(window.hasCarriedChange)

        XCTAssertEqual(admission(window, at: 115, fresh: 115), .stopsOnly)
        XCTAssertTrue(window.takeRelease(at: 115))
        XCTAssertEqual(admission(window, at: 115, fresh: 115), .hold, "the carried window holds")
        XCTAssertEqual(admission(window, at: 118, fresh: 118), .full)
    }

    func testReleaseWaitsForASnapshotIssuedAfterReleaseTime() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)

        XCTAssertEqual(admission(window, at: 104, fresh: nil), .hold, "no poll has applied")
        XCTAssertEqual(admission(window, at: 104, fresh: 102.9), .hold, "the poll was issued before the window's end")
        XCTAssertEqual(admission(window, at: 200, fresh: 102.9), .hold, "the cap does not release on a stale poll")
        XCTAssertEqual(admission(window, at: 104, fresh: 103), .full)
    }

    func testOutstandingDefaultWriteHoldsUntilCap() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)

        XCTAssertEqual(admission(window, at: 104, fresh: 104, writes: 1), .hold)
        XCTAssertEqual(admission(window, at: 114.9, fresh: 114.9, writes: 1), .hold)
        XCTAssertEqual(
            admission(window, at: 115, fresh: 115, writes: 1),
            .stopsOnly,
            "a write that never completes cannot hold stops past the cap, nor admit starts"
        )
        XCTAssertEqual(admission(window, at: 115, fresh: 115, writes: 0), .full)
    }

    func testFullReleaseAfterSettleWithFreshSnapshot() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)

        XCTAssertEqual(admission(window, at: 102.9, fresh: 102.9), .hold)
        XCTAssertEqual(admission(window, at: 103, fresh: 103), .full)
        XCTAssertTrue(window.takeRelease(at: 103))
        XCTAssertFalse(window.isArmed)
    }

    func testPickerWriteThatWaitsBehindASlowPollDoesNotLetThatPollRelease() {
        var window = LifecycleQuietWindow()
        var writes = DefaultDeviceWrites<String>()

        // A poll is issued at 99.9 and blocks on the HAL queue. The pick at
        // 100 arms the window, and its write waits behind the poll.
        window.noteChange(at: 100)
        writes.begin("output", epoch: 2)

        // The poll applies at 103.3 with the device from before the pick.
        XCTAssertTrue(writes.snapshotPredatesOutstandingWrite("output", snapshotEpoch: 1))
        XCTAssertEqual(admission(window, at: 103.3, fresh: 99.9, writes: writes.count), .hold)

        // The write completes at 104 and re-arms the window.
        writes.end("output", epoch: 2)
        window.noteChange(at: 104)
        XCTAssertEqual(admission(window, at: 104, fresh: 99.9, writes: writes.count), .hold)
        XCTAssertEqual(admission(window, at: 104.3, fresh: 104.1, writes: writes.count), .hold)
        XCTAssertEqual(admission(window, at: 107.1, fresh: 107.05, writes: writes.count), .full)
    }

    func testTimeEarlierThanTheLastChangeIsClamped() {
        var window = LifecycleQuietWindow()
        window.noteChange(at: 100)
        window.noteChange(at: 99)

        XCTAssertEqual(window.lastChange, 100)
        XCTAssertEqual(window.releaseTime, 103)
        XCTAssertTrue(window.isHolding(at: 50))
        XCTAssertFalse(window.takeRelease(at: 50))
        XCTAssertTrue(window.takeRelease(at: 103))
    }

    private func topology(
        input: UInt32 = 10,
        output: UInt32 = 20,
        bluetooth: Set<UInt32> = []
    ) -> AudioTopology {
        AudioTopology(defaultInput: input, defaultOutput: output, bluetoothDeviceIDs: bluetooth)
    }

    func testFirstTopologyArmsNothing() {
        XCTAssertFalse(AudioTopology.armsQuietWindow(previous: nil, current: topology()))
        XCTAssertFalse(
            AudioTopology.armsQuietWindow(previous: nil, current: topology(bluetooth: [30]))
        )
    }

    func testUnchangedTopologyArmsNothing() {
        XCTAssertFalse(
            AudioTopology.armsQuietWindow(
                previous: topology(bluetooth: [30]),
                current: topology(bluetooth: [30])
            )
        )
    }

    func testDefaultDeviceChangesArm() {
        XCTAssertTrue(
            AudioTopology.armsQuietWindow(previous: topology(), current: topology(input: 11))
        )
        XCTAssertTrue(
            AudioTopology.armsQuietWindow(previous: topology(), current: topology(output: 21))
        )
    }

    func testBluetoothDeviceArrivalOrDepartureArms() {
        XCTAssertTrue(
            AudioTopology.armsQuietWindow(previous: topology(), current: topology(bluetooth: [30]))
        )
        XCTAssertTrue(
            AudioTopology.armsQuietWindow(previous: topology(bluetooth: [30]), current: topology())
        )
        XCTAssertTrue(
            AudioTopology.armsQuietWindow(
                previous: topology(bluetooth: [30]),
                current: topology(bluetooth: [31])
            )
        )
    }

    func testNonBluetoothArrivalWithoutDefaultChangeArmsNothing() {
        // Runs the same cache the HAL worker derives the Bluetooth set from,
        // so the test fails if a USB arrival ever leaks into that set.
        let transports: [UInt32: AudioDeviceTransport] = [
            10: .builtIn, 20: .builtIn, 30: .bluetooth, 40: .usb, 50: .bluetoothLE
        ]
        var cache = DeviceTransportCache()
        cache.update(listing: [10, 20, 30]) { transports[$0] }
        let before = topology(bluetooth: cache.bluetoothDeviceIDs)

        cache.update(listing: [10, 20, 30, 40]) { transports[$0] }
        let afterUSB = topology(bluetooth: cache.bluetoothDeviceIDs)
        XCTAssertFalse(AudioTopology.armsQuietWindow(previous: before, current: afterUSB))

        cache.update(listing: [10, 20, 30, 40, 50]) { transports[$0] }
        let afterBluetooth = topology(bluetooth: cache.bluetoothDeviceIDs)
        XCTAssertTrue(AudioTopology.armsQuietWindow(previous: afterUSB, current: afterBluetooth))

        // A failed device-list read is not every Bluetooth device leaving.
        cache.update(listing: nil) { transports[$0] }
        XCTAssertFalse(
            AudioTopology.armsQuietWindow(
                previous: afterBluetooth,
                current: topology(bluetooth: cache.bluetoothDeviceIDs)
            )
        )
    }
}

final class DefaultDeviceWritesTests: XCTestCase {
    func testSnapshotIssuedBeforeAnOutstandingDefaultWriteDoesNotMoveThatDirection() {
        var writes = DefaultDeviceWrites<String>()
        writes.begin("output", epoch: 5)

        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes.snapshotPredatesOutstandingWrite("output", snapshotEpoch: 4))
        XCTAssertFalse(writes.snapshotPredatesOutstandingWrite("output", snapshotEpoch: 5), "issued after the pick")
        XCTAssertFalse(writes.snapshotPredatesOutstandingWrite("input", snapshotEpoch: 4), "another direction")

        writes.begin("output", epoch: 7)
        XCTAssertTrue(
            writes.snapshotPredatesOutstandingWrite("output", snapshotEpoch: 6),
            "a poll between two picks has not seen the later one"
        )

        writes.end("output", epoch: 5)
        XCTAssertEqual(writes.count, 1)
        writes.end("output", epoch: 7)
        XCTAssertEqual(writes.count, 0)
        XCTAssertFalse(writes.snapshotPredatesOutstandingWrite("output", snapshotEpoch: 4))

        writes.end("output", epoch: 7)
        XCTAssertEqual(writes, DefaultDeviceWrites<String>(), "a completion that was already counted changes nothing")
    }
}
