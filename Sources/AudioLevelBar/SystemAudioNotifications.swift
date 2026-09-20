import AudioLevelBarCore
import CoreAudio
import Foundation

/// Listens on the HAL system object for default-device changes, device-list
/// changes and a coreaudiod restart. See `HALSystemNotification`.
///
/// The listener block makes no HAL read and no lifecycle call. For a
/// notification that arms the quiet window it advances the window's
/// generation at once, on the listener queue, so a start or stop already on
/// its way stops at its next check without waiting for the main thread; then
/// it tells the owner on the main thread. The poll stays the source of device
/// IDs and the fallback for a notification that never arrives.
///
/// This narrows the time between a change and the hold; it cannot close it.
/// A Bluetooth device can begin reconfiguring before any client is notified,
/// and a call already inside `AudioDeviceStart` is not interrupted.
final class SystemAudioNotifications {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Delivered on the main thread, once per notification in each callback.
    var onNotification: ((HALSystemNotification) -> Void)?
    /// Called on the listener queue for a coreaudiod restart, right after the
    /// generation advanced and before the main thread hears of it. The owner
    /// drops what its lifecycle owners held here, without a HAL call, so a
    /// stop the main thread issues before its own recovery runs finds nothing
    /// left to destroy under an ID the new server may have reissued. Set it
    /// before `start()`.
    var onServiceRestartedOnListenerQueue: (() -> Void)?

    /// Internal rather than private so a test can wait for it.
    let listenerQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.system-notifications",
        qos: .userInitiated
    )
    private let halCalls: any HALLifecycleCalls
    private let holdGeneration: LifecycleHoldGeneration
    /// Listener-queue confined.
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var registeredAddresses: [AudioObjectPropertyAddress] = []

    init(halCalls: any HALLifecycleCalls, holdGeneration: LifecycleHoldGeneration) {
        self.halCalls = halCalls
        self.holdGeneration = holdGeneration
    }

    /// Registers the listeners on the listener queue, so the main thread does
    /// not wait on coreaudiod for it. A listener that cannot be added is
    /// logged and skipped; the poll still notices the change.
    func start() {
        listenerQueue.async { [self] in
            guard listenerBlock == nil else {
                return
            }
            let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
                self?.handle(count: count, addresses: addresses)
            }
            listenerBlock = block
            for notification in HALSystemNotification.allCases {
                let address = AudioObjectPropertyAddress(
                    mSelector: notification.selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = halCalls.addPropertyListener(
                    deviceID: Self.systemObject,
                    address: address,
                    queue: listenerQueue,
                    block: block
                )
                if status == noErr {
                    registeredAddresses.append(address)
                } else {
                    HALLifecycleLog.record(
                        .systemListener,
                        .create,
                        id: Self.systemObject,
                        status: status,
                        generation: holdGeneration.current
                    )
                }
            }
        }
    }

    /// Removes the listeners on the listener queue. Nothing waits for it:
    /// at Quit the main thread must not block on coreaudiod for this.
    func stop() {
        listenerQueue.async { [self] in
            guard let listenerBlock else {
                return
            }
            for address in registeredAddresses {
                halCalls.removePropertyListener(
                    deviceID: Self.systemObject,
                    address: address,
                    queue: listenerQueue,
                    block: listenerBlock
                )
            }
            registeredAddresses = []
            self.listenerBlock = nil
        }
    }

    /// Listener queue.
    private func handle(count: UInt32, addresses: UnsafePointer<AudioObjectPropertyAddress>) {
        var notifications: [HALSystemNotification] = []
        for address in UnsafeBufferPointer(start: addresses, count: Int(count)) {
            if
                let notification = HALSystemNotification(selector: address.mSelector),
                !notifications.contains(notification)
            {
                notifications.append(notification)
            }
        }
        guard !notifications.isEmpty else {
            return
        }
        if let source = notifications.lazy.compactMap(\.quietWindowReason).first {
            holdGeneration.advance()
            HALLifecycleLog.quietWindowAdvance(source: source, generation: holdGeneration.current)
        }
        if notifications.contains(where: \.resetsHALState) {
            onServiceRestartedOnListenerQueue?()
        }
        DispatchQueue.main.async { [weak self] in
            for notification in notifications {
                self?.onNotification?(notification)
            }
        }
    }
}
