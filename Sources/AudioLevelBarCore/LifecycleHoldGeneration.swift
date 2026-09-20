import Foundation

/// A counter the owner advances every time the quiet window arms or re-arms.
///
/// A HAL start is issued only while the window is not holding, but it runs on
/// a lifecycle queue and can reach its create or `AudioDeviceStart` call much
/// later: behind a HAL call that is taking its time, or after a hop through
/// the main thread. The start takes the generation when it is issued and
/// compares it immediately before each create and start. A different value
/// means a window armed meanwhile, and the start stops before that call.
///
/// Safe to use from any thread except a real-time IO thread: it locks.
public final class LifecycleHoldGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init() {}

    /// The token a start takes when it is issued.
    public var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Called whenever the quiet window arms or re-arms.
    public func advance() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    /// Whether no window has armed since `token` was taken.
    public func isCurrent(_ token: UInt64) -> Bool {
        current == token
    }

    /// Whether a call issued with `token` may be made now. A nil token marks
    /// a call the quiet window does not hold, such as a stop at Quit.
    public func allows(_ token: UInt64?) -> Bool {
        token.map(isCurrent) ?? true
    }
}
