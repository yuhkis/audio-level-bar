import Foundation
import XCTest
@testable import AudioLevelBar

/// The shim that keeps an Objective-C exception from AVFAudio from ending the
/// process. Nothing here touches Core Audio.
final class ObjCExceptionCatcherTests: XCTestCase {
    func testAnExceptionRaisedInTheBlockIsThrownAsAnError() {
        XCTAssertThrowsError(
            try catchingObjCException { () -> Void in
                NSException(
                    name: .invalidArgumentException,
                    reason: "required condition is false",
                    userInfo: nil
                ).raise()
            }
        ) { error in
            XCTAssertEqual(
                error as? CaughtObjCException,
                CaughtObjCException(
                    name: "NSInvalidArgumentException",
                    reason: "required condition is false"
                )
            )
        }
    }

    func testAnExceptionRaisedInsideObjectiveCCodeIsCaught() {
        let empty = NSArray()
        XCTAssertThrowsError(try catchingObjCException { empty.object(at: 1) }) { error in
            XCTAssertEqual((error as? CaughtObjCException)?.name, NSExceptionName.rangeException.rawValue)
        }
    }

    func testABlockThatReturnsRunsOnceAndHandsBackItsValue() throws {
        var runs = 0
        let value = try catchingObjCException { () -> Int in
            runs += 1
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(runs, 1)
    }
}
