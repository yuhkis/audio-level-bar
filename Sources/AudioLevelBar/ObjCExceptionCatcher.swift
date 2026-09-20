import Foundation
import ObjCExceptionShim

/// An Objective-C exception a framework call raised, caught before it could
/// end the process.
struct CaughtObjCException: Error, Equatable {
    let name: String
    let reason: String

    /// `name: reason`, for an error message.
    var detail: String {
        "\(name): \(reason)"
    }
}

/// Runs `body` and returns its result, or throws the Objective-C exception it
/// raised as a `CaughtObjCException`.
///
/// The processed microphone's `AVAudioEngine`s run on the main thread, and
/// AVFAudio raises an exception instead of returning an error when a device
/// changes under a call. Uncaught, that ends the process while its published
/// device, its process tap and any IO it started are still in place.
///
/// An exception unwinds through `body` without running Swift cleanup, so keep
/// `body` to the framework call itself and do the work around it outside.
func catchingObjCException<T>(_ body: () -> T) throws -> T {
    var result: T?
    if let exception = ALBCatchObjCException({ result = body() }) {
        throw CaughtObjCException(
            name: exception.name.rawValue,
            reason: exception.reason ?? "no reason given"
        )
    }
    guard let result else {
        // Unreachable: the block either returned, setting the result, or
        // raised, which is handled above.
        throw CaughtObjCException(name: "NSInternalInconsistencyException", reason: "no result")
    }
    return result
}
