import Foundation

/// The order in which a lifecycle owner releases what it holds, one HAL call
/// at a time, and what it still holds after each call.
///
/// An owner builds one from what it holds, asks for `nextStep`, compares the
/// quiet window's generation immediately before every step that is a
/// lifecycle call, and records each step with `complete(_:)` or
/// `noteIsRunning(_:)` only after that call has returned. A teardown that
/// stops at a mismatch therefore leaves consistent state for the next start
/// or stop after the window: a stopped IOProc, or an aggregate device with no
/// IOProc, or a tap with no aggregate device.
///
/// The order keeps two invariants. An aggregate device is never destroyed
/// while an IOProc exists on it, and a process tap is never destroyed while
/// the aggregate device that lists it exists.
public struct LifecycleTeardown: Equatable {
    /// What became of the IOProc, when the owner holds one.
    public enum IOProc: Equatable {
        case none
        /// Created, and `AudioDeviceStart` was never called.
        case created
        /// `AudioDeviceStart` was called and did not return `noErr`, or has
        /// not returned. Whether the IO runs anyway is read before the IOProc
        /// is destroyed.
        case startUnconfirmed
        /// Read running after a start that did not return `noErr`.
        case runningAfterUnconfirmedStart
        case started
    }

    public enum Step: Equatable {
        /// Read `kAudioDevicePropertyDeviceIsRunning` on the IOProc's device.
        /// A read, not a lifecycle call.
        case readIsRunning
        /// `AudioDeviceStop`.
        case stop
        /// `AudioDeviceDestroyIOProcID`.
        case destroyIOProc
        /// `AudioHardwareDestroyAggregateDevice`.
        case destroyAggregate
        /// `AudioHardwareDestroyProcessTap`.
        case destroyProcessTap

        /// Whether the quiet window's generation is compared before it.
        public var isLifecycleCall: Bool {
            self != .readIsRunning
        }
    }

    public private(set) var ioProc: IOProc
    public private(set) var holdsAggregate: Bool
    public private(set) var holdsTap: Bool

    public init(ioProc: IOProc, holdsAggregate: Bool = false, holdsTap: Bool = false) {
        self.ioProc = ioProc
        self.holdsAggregate = holdsAggregate
        self.holdsTap = holdsTap
    }

    /// The next call, or nil once nothing is held.
    public var nextStep: Step? {
        switch ioProc {
        case .started, .runningAfterUnconfirmedStart:
            return .stop
        case .startUnconfirmed:
            return .readIsRunning
        case .created:
            return .destroyIOProc
        case .none:
            break
        }
        if holdsAggregate {
            return .destroyAggregate
        }
        if holdsTap {
            return .destroyProcessTap
        }
        return nil
    }

    /// Whether the next stop is for IO that reported running after a start
    /// that did not return `noErr`.
    public var stopFollowsUnconfirmedStart: Bool {
        ioProc == .runningAfterUnconfirmedStart
    }

    /// Records that `step`, a lifecycle call, has returned. Whatever status
    /// it returned, the handle is not called again: a device that vanished
    /// answers with a bad device or bad object status.
    public mutating func complete(_ step: Step) {
        switch step {
        case .readIsRunning:
            break
        case .stop:
            ioProc = .created
        case .destroyIOProc:
            ioProc = .none
        case .destroyAggregate:
            holdsAggregate = false
        case .destroyProcessTap:
            holdsTap = false
        }
    }

    /// Records the `kAudioDevicePropertyDeviceIsRunning` read. `running` is
    /// true only for a read that succeeded with a nonzero value.
    public mutating func noteIsRunning(_ running: Bool) {
        guard ioProc == .startUnconfirmed else {
            return
        }
        ioProc = running ? .runningAfterUnconfirmedStart : .created
    }
}
