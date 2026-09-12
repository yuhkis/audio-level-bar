import AudioLevelBarCore
import CoreAudio
import Darwin
import Foundation

enum SystemOutputMeterError: LocalizedError {
    case unsupportedOS
    case permissionDenied
    case audioProcessUnavailable
    case unsupportedFormat
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return localized("Monitoring the system playback level requires macOS 14.2 or later.")
        case .permissionDenied:
            return localized("System audio recording is not allowed.")
        case .audioProcessUnavailable:
            return localized("Audio Level Bar could not exclude itself from system playback monitoring.")
        case .unsupportedFormat:
            return localized("The system playback audio format could not be read.")
        case let .operationFailed(operation, status):
            return localized("%1$@ failed (Core Audio status %2$d).", operation, status)
        }
    }
}

final class SystemOutputMeter {
    /// 20 Hz while a SwiftUI meter is on screen.
    private static let detailedEmissionIntervalNanoseconds: UInt64 = 50_000_000
    /// 4 Hz otherwise. Only the menu bar item consumes levels then, and it
    /// redraws every 0.5 s.
    private static let idleEmissionIntervalNanoseconds: UInt64 = 250_000_000

    var onLevel: ((Float, Float) -> Void)?
    var onStarted: (() -> Void)?
    var onError: ((SystemOutputMeterError) -> Void)?

    private let processingQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.system-output-meter",
        qos: .userInteractive
    )
    private let lifecycleQueue = DispatchQueue(
        label: "io.github.yuhkis.audio-level-bar.system-output-meter.lifecycle",
        qos: .userInitiated
    )
    private let sessionLock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var deviceStarted = false
    private var sessionID = UUID()

    /// Only ever touched on `processingQueue`, which also serializes every
    /// `consume(_:...)` call, so the interval can be retuned without a lock in
    /// the audio callback.
    private final class EmissionState {
        var lastEmissionNanoseconds: UInt64 = 0
        var intervalNanoseconds = SystemOutputMeter.idleEmissionIntervalNanoseconds
    }

    private let emissionState = EmissionState()

    private enum LifecycleCancellation: Error {
        case superseded
    }

    func start(
        deviceUID: String,
        excludingCurrentProcess: Bool = false
    ) {
        let newSessionID = replaceSession()

        guard #available(macOS 14.2, *) else {
            lifecycleQueue.async { [self] in
                stopResources()
            }
            report(.unsupportedOS, sessionID: newSessionID)
            return
        }

        // AudioDeviceStart can wait in Core Audio for an unbounded amount of
        // time on a broken or reconfiguring route. Keep every HAL lifecycle
        // operation serialized, but never run it on the UI thread.
        lifecycleQueue.async { [self] in
            stopResources()
            guard isCurrentSession(newSessionID) else {
                return
            }

            do {
                try configureAndStart(
                    deviceUID: deviceUID,
                    excludingCurrentProcess: excludingCurrentProcess,
                    sessionID: newSessionID
                )
                guard isCurrentSession(newSessionID) else {
                    stopResources()
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard self?.isCurrentSession(newSessionID) == true else {
                        return
                    }
                    self?.onStarted?()
                }
            } catch LifecycleCancellation.superseded {
                stopResources()
            } catch let error as SystemOutputMeterError {
                stopResources()
                report(error, sessionID: newSessionID)
            } catch {
                stopResources()
                report(
                    .operationFailed(localized("Starting system playback level monitoring"), -1),
                    sessionID: newSessionID
                )
            }
        }
    }

    func stop() {
        invalidateSession()
        lifecycleQueue.async { [self] in
            stopResources()
        }
    }

    /// Raises the level emission rate while a SwiftUI meter can show it.
    func setDetailedLevelUpdatesEnabled(_ enabled: Bool) {
        let interval = enabled
            ? Self.detailedEmissionIntervalNanoseconds
            : Self.idleEmissionIntervalNanoseconds
        processingQueue.async { [emissionState] in
            emissionState.intervalNanoseconds = interval
        }
    }

    private func stopResources() {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            if deviceStarted {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
            }
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }

        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        deviceStarted = false
    }

    @available(macOS 14.2, *)
    private func configureAndStart(
        deviceUID: String,
        excludingCurrentProcess: Bool,
        sessionID: UUID
    ) throws {
        let excludedProcesses: [AudioObjectID]
        if excludingCurrentProcess {
            excludedProcesses = [try currentAudioProcessObjectID()]
        } else {
            excludedProcesses = []
        }

        let tapDescription = CATapDescription(
            excludingProcesses: excludedProcesses,
            deviceUID: deviceUID,
            stream: 0
        )
        tapDescription.name = "Audio Level Bar System Output Meter"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(tapDescription, &newTapID),
            operation: localized("Creating the system audio tap")
        )
        tapID = newTapID

        let tapUID = try readTapUID(tapID)
        let format = try readTapFormat(tapID)
        guard
            format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mBitsPerChannel == 32 || format.mBitsPerChannel == 64
        else {
            throw SystemOutputMeterError.unsupportedFormat
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Level Bar System Output Meter",
            kAudioAggregateDeviceUIDKey: "io.github.yuhkis.audio-level-bar.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]
        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &newAggregateDeviceID
            ),
            operation: localized("Creating the system audio aggregate device")
        )
        aggregateDeviceID = newAggregateDeviceID

        var newIOProcID: AudioDeviceIOProcID?
        let emissionState = self.emissionState
        processingQueue.async {
            emissionState.lastEmissionNanoseconds = 0
        }
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &newIOProcID,
                aggregateDeviceID,
                processingQueue
            ) { [weak self] _, inputData, _, _, _ in
                self?.consume(
                    inputData,
                    sampleBitWidth: format.mBitsPerChannel,
                    sessionID: sessionID,
                    emissionState: emissionState
                )
            },
            operation: localized("Creating the system audio IOProc")
        )
        guard let newIOProcID else {
            throw SystemOutputMeterError.operationFailed(
                localized("Creating the system audio IOProc"),
                kAudioHardwareUnspecifiedError
            )
        }
        ioProcID = newIOProcID

        guard isCurrentSession(sessionID) else {
            throw LifecycleCancellation.superseded
        }

        try check(
            AudioDeviceStart(aggregateDeviceID, newIOProcID),
            operation: localized("Starting system audio recording")
        )
        deviceStarted = true
    }

    private func consume(
        _ inputData: UnsafePointer<AudioBufferList>,
        sampleBitWidth: UInt32,
        sessionID: UUID,
        emissionState: EmissionState
    ) {
        // Buffers arrive about every 10 ms and only one in every emission
        // interval is reported. Discard the rest before summing them: the
        // reported values are unchanged, and the per-sample loop stops running
        // for buffers nothing will ever read.
        let now = DispatchTime.now().uptimeNanoseconds
        guard
            now - emissionState.lastEmissionNanoseconds
                >= emissionState.intervalNanoseconds
        else {
            return
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        var sumOfSquares: Double = 0
        var peak: Double = 0
        var sampleCount = 0

        for buffer in bufferList {
            guard let data = buffer.mData else {
                continue
            }

            if sampleBitWidth == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                let samples = data.assumingMemoryBound(to: Float32.self)
                for index in 0..<count {
                    let amplitude = abs(Double(samples[index]))
                    sumOfSquares += amplitude * amplitude
                    peak = max(peak, amplitude)
                }
                sampleCount += count
            } else if sampleBitWidth == 64 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float64>.size
                let samples = data.assumingMemoryBound(to: Float64.self)
                for index in 0..<count {
                    let amplitude = abs(samples[index])
                    sumOfSquares += amplitude * amplitude
                    peak = max(peak, amplitude)
                }
                sampleCount += count
            }
        }

        // An empty buffer must not start the next interval.
        guard sampleCount > 0 else {
            return
        }
        emissionState.lastEmissionNanoseconds = now

        let rms = sqrt(sumOfSquares / Double(sampleCount))
        let rmsDecibels = MeterScale.decibels(amplitude: Float(rms))
        let peakDecibels = MeterScale.decibels(amplitude: Float(peak))
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(sessionID) == true else {
                return
            }
            self?.onLevel?(rmsDecibels, peakDecibels)
        }
    }

    @available(macOS 14.2, *)
    private func readTapUID(_ tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                &value
            ),
            operation: localized("Reading the system audio tap UID")
        )
        guard let value else {
            throw SystemOutputMeterError.operationFailed(
                localized("Reading the system audio tap UID"),
                kAudioHardwareUnspecifiedError
            )
        }
        return value.takeRetainedValue() as String
    }

    @available(macOS 14.2, *)
    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                &format
            ),
            operation: localized("Reading the system audio tap format")
        )
        return format
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status != kAudioDevicePermissionsError else {
            throw SystemOutputMeterError.permissionDenied
        }
        guard status == noErr else {
            throw SystemOutputMeterError.operationFailed(operation, status)
        }
    }

    private func currentAudioProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &pid,
                &size,
                &processObjectID
            ),
            operation: localized("Reading the Audio Level Bar audio process object")
        )
        guard processObjectID != kAudioObjectUnknown else {
            throw SystemOutputMeterError.audioProcessUnavailable
        }
        return processObjectID
    }

    private func replaceSession() -> UUID {
        let newSessionID = UUID()
        sessionLock.lock()
        sessionID = newSessionID
        sessionLock.unlock()
        return newSessionID
    }

    private func invalidateSession() {
        _ = replaceSession()
    }

    private func isCurrentSession(_ candidate: UUID) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionID == candidate
    }

    private func report(
        _ error: SystemOutputMeterError,
        sessionID: UUID
    ) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSession(sessionID) == true else {
                return
            }
            self?.onError?(error)
        }
    }
}
