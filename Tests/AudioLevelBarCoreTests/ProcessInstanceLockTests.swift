import AudioLevelBarCore
import Foundation
import XCTest

final class ProcessInstanceLockTests: XCTestCase {
    func testDifferentIdentifiersCanBeLockedTogether() throws {
        let directory = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstLock = try ProcessInstanceLock(
            identifier: "test.first",
            directory: directory
        )
        XCTAssertNoThrow(
            try ProcessInstanceLock(
                identifier: "test.second",
                directory: directory
            )
        )
        _ = firstLock
    }

    func testIdentifierCannotEscapeLockDirectory() {
        XCTAssertThrowsError(
            try ProcessInstanceLock(
                identifier: "../outside",
                directory: temporaryLockDirectory()
            )
        ) { error in
            XCTAssertEqual(
                error as? ProcessInstanceLock.LockError,
                .invalidIdentifier
            )
        }
    }

    func testSecondLockForSameIdentifierIsRejectedUntilFirstIsReleased() throws {
        let directory = temporaryLockDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        var firstLock: ProcessInstanceLock? = try ProcessInstanceLock(
            identifier: "test.app",
            directory: directory
        )
        XCTAssertThrowsError(
            try ProcessInstanceLock(
                identifier: "test.app",
                directory: directory
            )
        ) { error in
            XCTAssertEqual(
                error as? ProcessInstanceLock.LockError,
                .alreadyLocked
            )
        }

        firstLock = nil
        XCTAssertNoThrow(
            try ProcessInstanceLock(
                identifier: "test.app",
                directory: directory
            )
        )
        _ = firstLock
    }

    private func temporaryLockDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProcessInstanceLockTests.\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
