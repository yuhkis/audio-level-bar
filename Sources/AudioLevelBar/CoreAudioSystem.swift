import AudioToolbox
import AudioLevelBarCore
import CoreAudio
import Foundation

enum CoreAudioSystemError: LocalizedError {
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .operationFailed(operation, status):
            return "\(operation) failed (Core Audio status \(status))."
        }
    }
}

/// What an IOProc on a device's input receives.
struct InputStreamFormat: Equatable {
    let sampleFormat: PCMSampleFormat
    /// Channels summed over every input stream.
    let channelCount: Int
    let sampleRate: Double
}

final class CoreAudioSystem {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Which elements of a device actually carry a control, and which of those
    /// accept writes.
    private struct ControlLayout {
        let addresses: [AudioObjectPropertyAddress]
        let settableAddresses: [AudioObjectPropertyAddress]
    }

    private struct ControlLayoutKey: Hashable {
        let deviceID: AudioDeviceID
        let scope: AudioObjectPropertyScope
        let selector: AudioObjectPropertySelector
    }

    /// Discovering a control layout costs 33 `AudioObjectHasProperty` round
    /// trips — the main element plus channels 1...32 — and the layout is asked
    /// for twice per `controls(for:direction:)` and again on every write. At the
    /// 0.25 s refresh that would be hundreds of HAL calls per second to
    /// re-learn a device shape that changes only when the hardware does.
    ///
    /// The cache is dropped whole whenever the set of devices changes, and
    /// again on a timer, because a device can also reconfigure its channel
    /// layout in place without appearing or disappearing.
    private let cacheLock = NSLock()
    private var controlLayoutCache: [ControlLayoutKey: ControlLayout] = [:]
    private var controlLayoutCacheFilled = DispatchTime.now()
    private var lastSeenDeviceIDs: Set<AudioDeviceID> = []

    private static let controlLayoutCacheLifetimeSeconds: Double = 30

    func devices(for direction: AudioDirection) -> [AudioDevice] {
        listedDevices(for: direction) ?? []
    }

    /// The devices `devices(for:)` lists, or nil when the device list itself
    /// could not be read. The processed microphone's publisher engine chooses
    /// its output from this, read uncached, by the same criteria the device
    /// pickers use.
    func listedDevices(for direction: AudioDirection) -> [AudioDevice]? {
        deviceIDs()?
            .compactMap(audioDevice)
            .filter { device in
                let hasChannels = direction == .input
                    ? device.hasInput
                    : device.hasOutput
                return hasChannels && canBeDefaultDevice(
                    device.id,
                    direction: direction
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func defaultDevice(for direction: AudioDirection) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    func deviceUID(for deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
    }

    @discardableResult
    /// - Returns: The status of the write.
    func setDefaultDevice(_ deviceID: AudioDeviceID, for direction: AudioDirection) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: direction.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            size,
            &mutableDeviceID
        )
        return status
    }

    func controls(for deviceID: AudioDeviceID, direction: AudioDirection) -> AudioControlSnapshot {
        let volumeLayout = controlLayout(
            selector: kAudioDevicePropertyVolumeScalar,
            deviceID: deviceID,
            scope: direction.scope
        )
        let muteLayout = controlLayout(
            selector: kAudioDevicePropertyMute,
            deviceID: deviceID,
            scope: direction.scope
        )
        let volumeAddresses = volumeLayout.addresses
        let muteAddresses = muteLayout.addresses

        let volumes = preferredValues(
            from: volumeAddresses,
            reader: { readFloat(deviceID: deviceID, address: $0) }
        )
        let averageVolume: Float? = volumes.isEmpty
            ? nil
            : volumes.reduce(0, +) / Float(volumes.count)

        let muteValues = preferredValues(
            from: muteAddresses,
            reader: { readUInt32(deviceID: deviceID, address: $0) }
        )
        let muted: Bool? = muteValues.isEmpty
            ? nil
            : muteValues.allSatisfy { $0 != 0 }

        return AudioControlSnapshot(
            volume: averageVolume,
            volumeIsAdjustable: !volumeLayout.settableAddresses.isEmpty,
            isMuted: muted,
            muteIsAdjustable: !muteLayout.settableAddresses.isEmpty
        )
    }

    @discardableResult
    /// Writes every settable volume element of the direction.
    ///
    /// - Returns: The first status other than `noErr` among the writes,
    ///   `kAudioHardwareUnknownPropertyError` when no element is settable, or
    ///   `noErr`.
    func setVolume(
        _ volume: Float,
        deviceID: AudioDeviceID,
        direction: AudioDirection
    ) -> OSStatus {
        let clamped = min(max(volume, 0), 1)
        let addresses = settablePropertyAddresses(
            selector: kAudioDevicePropertyVolumeScalar,
            deviceID: deviceID,
            scope: direction.scope
        )

        guard !addresses.isEmpty else {
            return kAudioHardwareUnknownPropertyError
        }

        return addresses.reduce(noErr) { result, address in
            var address = address
            var mutableValue = clamped
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &mutableValue
            )
            return result != noErr ? result : status
        }
    }

    @discardableResult
    /// Writes every settable mute element of the direction.
    ///
    /// - Returns: The first status other than `noErr` among the writes,
    ///   `kAudioHardwareUnknownPropertyError` when no element is settable, or
    ///   `noErr`.
    func setMuted(
        _ muted: Bool,
        deviceID: AudioDeviceID,
        direction: AudioDirection
    ) -> OSStatus {
        let addresses = settablePropertyAddresses(
            selector: kAudioDevicePropertyMute,
            deviceID: deviceID,
            scope: direction.scope
        )

        guard !addresses.isEmpty else {
            return kAudioHardwareUnknownPropertyError
        }

        return addresses.reduce(noErr) { result, address in
            var address = address
            var mutableValue: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &mutableValue
            )
            return result != noErr ? result : status
        }
    }

    /// Every device the HAL lists, or nil when the list could not be read.
    /// An empty array is a successful read of no devices, which a caller that
    /// tracks arrivals and departures must not confuse with a failed one.
    func deviceIDs() -> [AudioDeviceID]? {
        guard let deviceIDs = objectIDList(
            of: systemObject,
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        ) else {
            return nil
        }
        // A device arriving or leaving can also renumber the survivors, and an
        // AudioDeviceID is reusable, so a cached layout could end up describing
        // different hardware. Drop the cache rather than reason about which
        // entries stayed valid.
        noteCurrentDeviceIDs(deviceIDs)
        return deviceIDs
    }

    /// The sub-devices currently active in an aggregate, in the order Core
    /// Audio lists them, or nil when the list could not be read.
    func activeSubDeviceIDs(of aggregateID: AudioDeviceID) -> [AudioDeviceID]? {
        objectIDList(
            of: aggregateID,
            selector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    /// Every sub-device an aggregate names, active or not
    /// (`kAudioAggregateDevicePropertyFullSubDeviceList`), in the order Core
    /// Audio lists them, each resolved from its UID to the device that has it
    /// now. A UID no device has, as for a headset that is not connected, or
    /// one that could not be translated, is nil. nil when the list could not
    /// be read.
    func fullSubDeviceIDs(of aggregateID: AudioDeviceID) -> [AudioDeviceID?]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else {
            return nil
        }
        let uids = value.takeRetainedValue() as NSArray
        return uids.map { element in
            (element as? String).flatMap(deviceID(forUID:))
        }
    }

    /// `kAudioHardwarePropertyTranslateUIDToDevice`: the device that has the
    /// UID now, or nil when none has or the read failed.
    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    /// Reads the transport of exactly this device and, for an aggregate, the
    /// transports of its active sub-devices and of its full composition,
    /// nested aggregates included. Nothing is cached, which is what
    /// the meter's lifecycle queue needs immediately before it opens a device.
    /// nil when the device's own transport could not be read, so that a
    /// failed read is never mistaken for a transport that rules Bluetooth out.
    func transportInfo(for deviceID: AudioDeviceID) -> AudioDeviceTransportInfo? {
        transportInfo(for: deviceID) { readTransport(deviceID: $0) }
    }

    /// The same, with the per-device transport read supplied by the caller,
    /// so the HAL worker can answer it from its cache. The sub-device lists of
    /// an aggregate, and the translation of its members' UIDs, are always
    /// read, because they change while the ID stays.
    /// See `AudioDeviceTransportInfo.read` for how failed reads count.
    func transportInfo(
        for deviceID: AudioDeviceID,
        transportOf: (AudioDeviceID) -> AudioDeviceTransport?
    ) -> AudioDeviceTransportInfo? {
        AudioDeviceTransportInfo.read(
            deviceID: deviceID,
            transportOf: transportOf,
            activeSubDevicesOf: { activeSubDeviceIDs(of: $0) },
            fullSubDevicesOf: { fullSubDeviceIDs(of: $0) }
        )
    }

    /// The format the device's input streams deliver to an IOProc, or nil
    /// when the device has no input stream, a stream's format cannot be read,
    /// the streams are not all the same native-endian float format, or a
    /// stream reports a sample rate `SampleRatePolicy` does not accept.
    ///
    /// An IOProc receives each stream in its virtual format. `channelCount`
    /// is the total over every input stream, which is how many samples per
    /// frame the level math sees across the buffer list.
    func inputStreamFormat(for deviceID: AudioDeviceID) -> InputStreamFormat? {
        guard
            let streamIDs = objectIDList(
                of: deviceID,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioDevicePropertyScopeInput
            ),
            !streamIDs.isEmpty
        else {
            return nil
        }

        var sampleFormat: PCMSampleFormat?
        var sampleRate: Double = 0
        var channelCount = 0
        for streamID in streamIDs {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var description = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard
                AudioObjectGetPropertyData(
                    streamID,
                    &address,
                    0,
                    nil,
                    &size,
                    &description
                ) == noErr,
                let streamFormat = PCMSampleFormat(description),
                description.mChannelsPerFrame > 0,
                SampleRatePolicy.isUsable(description.mSampleRate)
            else {
                return nil
            }
            if let sampleFormat, sampleFormat != streamFormat {
                return nil
            }
            sampleFormat = streamFormat
            if sampleRate == 0 {
                sampleRate = description.mSampleRate
            }
            channelCount += Int(description.mChannelsPerFrame)
        }

        guard let sampleFormat else {
            return nil
        }
        return InputStreamFormat(
            sampleFormat: sampleFormat,
            channelCount: channelCount,
            sampleRate: sampleRate
        )
    }

    /// The largest IO buffer, in frames, the device may hand an IOProc, from
    /// `kAudioDevicePropertyBufferFrameSizeRange`. nil when it could not be
    /// read. A capture sizes the scratch storage its IOProc copies into from
    /// this, before it starts, so the IO thread never allocates.
    func maximumBufferFrameSize(for deviceID: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &range
            ) == noErr,
            range.mMaximum.isFinite,
            range.mMaximum >= 1
        else {
            return nil
        }
        return Int(min(range.mMaximum, Double(Int32.max)))
    }

    private func objectIDList(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(
            objectID,
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return nil
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            return []
        }
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        let status = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }

        guard status == noErr else {
            return nil
        }
        // The list can shrink between the size and the data read.
        let readCount = Int(size) / MemoryLayout<AudioObjectID>.size
        return Array(objectIDs.prefix(readCount))
    }

    private func audioDevice(_ deviceID: AudioDeviceID) -> AudioDevice? {
        guard let name = stringProperty(
            kAudioObjectPropertyName,
            deviceID: deviceID
        ) else {
            return nil
        }

        let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
            ?? String(deviceID)
        let inputChannelCount = channelCount(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        )
        let outputChannelCount = channelCount(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput
        )
        // nil when unread: the device lists show `.unknown` for it, and the
        // publisher output waits for a read rather than refusing it.
        let transport = readTransport(deviceID: deviceID)

        guard inputChannelCount > 0 || outputChannelCount > 0 else {
            return nil
        }

        return AudioDevice(
            id: deviceID,
            name: name,
            uid: uid,
            inputChannelCount: inputChannelCount,
            outputChannelCount: outputChannelCount,
            transport: transport
        )
    }

    private func canBeDefaultDevice(
        _ deviceID: AudioDeviceID,
        direction: AudioDirection
    ) -> Bool {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: direction.scope,
            mElement: kAudioObjectPropertyElementMain
        )

        // Older or third-party drivers do not always implement this property.
        // In that case, keep a device that has real channels instead of hiding
        // a potentially valid microphone or speaker.
        guard let value = readUInt32(deviceID: deviceID, address: address) else {
            return true
        }
        return value != 0
    }

    /// Transport of one device, for callers outside the device-list path, or
    /// nil when it could not be read.
    func transport(for deviceID: AudioDeviceID) -> AudioDeviceTransport? {
        readTransport(deviceID: deviceID)
    }

    private func readTransport(deviceID: AudioDeviceID) -> AudioDeviceTransport? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard let rawValue = readUInt32(deviceID: deviceID, address: address) else {
            return nil
        }
        return AudioDeviceTransport(transportType: rawValue)
    }

    private func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )

        guard status == noErr, let value else {
            return nil
        }

        return value.takeRetainedValue() as String
    }

    private func channelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr,
            size >= UInt32(MemoryLayout<UInt32>.size)
        else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            storage
        ) == noErr else {
            return 0
        }

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    /// Returns the cached layout, discovering it only when it is missing or
    /// stale.
    ///
    /// The HAL probing happens outside the lock. Holding a mutex across
    /// `AudioObjectHasProperty` would move a slow coreaudiod from blocking one
    /// caller to blocking every caller on the mutex, which is the failure this
    /// whole effort exists to remove. A concurrent miss just discovers the same
    /// layout twice and stores the same answer.
    private func controlLayout(
        selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> ControlLayout {
        let key = ControlLayoutKey(
            deviceID: deviceID,
            scope: scope,
            selector: selector
        )

        cacheLock.lock()
        let age = Double(
            DispatchTime.now().uptimeNanoseconds
                &- controlLayoutCacheFilled.uptimeNanoseconds
        ) / 1_000_000_000
        if age > Self.controlLayoutCacheLifetimeSeconds {
            controlLayoutCache.removeAll(keepingCapacity: true)
            controlLayoutCacheFilled = DispatchTime.now()
        }
        let cached = controlLayoutCache[key]
        cacheLock.unlock()

        if let cached {
            return cached
        }

        let addresses = discoverPropertyAddresses(
            selector: selector,
            deviceID: deviceID,
            scope: scope
        )
        let layout = ControlLayout(
            addresses: addresses,
            settableAddresses: addresses.filter {
                isSettable(deviceID: deviceID, address: $0)
            }
        )

        cacheLock.lock()
        controlLayoutCache[key] = layout
        cacheLock.unlock()
        return layout
    }

    /// Drops every cached layout so the next read pays full discovery cost.
    /// Exists for measurement; the app never needs to call it.
    func forgetControlLayouts() {
        invalidateControlLayoutCache()
    }

    /// Drops every cached layout. Called when the device set changes, since an
    /// `AudioDeviceID` can be reused by different hardware.
    /// Drops every cached control layout and the device set it was learned
    /// for. coreaudiod restarted, and a device ID may now name other hardware.
    func forgetControlLayoutCache() {
        cacheLock.lock()
        lastSeenDeviceIDs = []
        cacheLock.unlock()
        invalidateControlLayoutCache()
    }

    private func invalidateControlLayoutCache() {
        cacheLock.lock()
        controlLayoutCache.removeAll(keepingCapacity: true)
        controlLayoutCacheFilled = DispatchTime.now()
        cacheLock.unlock()
    }

    private func noteCurrentDeviceIDs(_ deviceIDs: [AudioDeviceID]) {
        let current = Set(deviceIDs)
        cacheLock.lock()
        let changed = current != lastSeenDeviceIDs
        lastSeenDeviceIDs = current
        cacheLock.unlock()
        if changed {
            invalidateControlLayoutCache()
        }
    }

    private func propertyAddresses(
        selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyAddress] {
        controlLayout(
            selector: selector,
            deviceID: deviceID,
            scope: scope
        ).addresses
    }

    private func discoverPropertyAddresses(
        selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyAddress] {
        let master = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var addresses: [AudioObjectPropertyAddress] = []
        if hasProperty(deviceID: deviceID, address: master) {
            addresses.append(master)
        }

        addresses.append(contentsOf: (1...32).compactMap { channel -> AudioObjectPropertyAddress? in
            let candidate = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: AudioObjectPropertyElement(channel)
            )
            return hasProperty(deviceID: deviceID, address: candidate) ? candidate : nil
        })
        return addresses
    }

    private func settablePropertyAddresses(
        selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyAddress] {
        let settable = controlLayout(
            selector: selector,
            deviceID: deviceID,
            scope: scope
        ).settableAddresses

        if let master = settable.first(where: {
            $0.mElement == kAudioObjectPropertyElementMain
        }) {
            return [master]
        }

        return settable
    }

    private func readFloat(
        deviceID: AudioDeviceID,
        address originalAddress: AudioObjectPropertyAddress
    ) -> Float? {
        var address = originalAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private func readUInt32(
        deviceID: AudioDeviceID,
        address originalAddress: AudioObjectPropertyAddress
    ) -> UInt32? {
        var address = originalAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private func preferredValues<Value>(
        from addresses: [AudioObjectPropertyAddress],
        reader: (AudioObjectPropertyAddress) -> Value?
    ) -> [Value] {
        if
            let master = addresses.first(where: {
                $0.mElement == kAudioObjectPropertyElementMain
            }),
            let value = reader(master)
        {
            return [value]
        }

        return addresses
            .filter { $0.mElement != kAudioObjectPropertyElementMain }
            .compactMap(reader)
    }

    private func isSettable(
        deviceID: AudioDeviceID,
        address originalAddress: AudioObjectPropertyAddress
    ) -> Bool {
        var address = originalAddress
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private func hasProperty(
        deviceID: AudioDeviceID,
        address originalAddress: AudioObjectPropertyAddress
    ) -> Bool {
        var address = originalAddress
        return AudioObjectHasProperty(deviceID, &address)
    }
}
