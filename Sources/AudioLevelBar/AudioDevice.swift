import AudioLevelBarCore
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannelCount: Int
    let outputChannelCount: Int
    /// The transport as read, or nil when the read failed. Decisions that
    /// must not mistake a failed read for a transport, such as the publisher
    /// output's, use this.
    let readTransport: AudioDeviceTransport?

    init(
        id: AudioDeviceID,
        name: String,
        uid: String,
        inputChannelCount: Int,
        outputChannelCount: Int,
        transport: AudioDeviceTransport?
    ) {
        self.id = id
        self.name = name
        self.uid = uid
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        readTransport = transport
    }

    /// The transport for the device lists, where an unreadable one only
    /// picks an icon: `.unknown` when it was not read.
    var transport: AudioDeviceTransport {
        readTransport ?? .unknown
    }

    var hasInput: Bool {
        inputChannelCount > 0
    }

    var hasOutput: Bool {
        outputChannelCount > 0
    }

    func systemImageName(for direction: AudioDirection) -> String {
        AudioDeviceSymbol.systemName(
            direction: direction == .input ? .input : .output,
            name: name,
            uid: uid,
            transport: transport
        )
    }
}

enum AudioDirection {
    case input
    case output

    var scope: AudioObjectPropertyScope {
        switch self {
        case .input:
            return kAudioDevicePropertyScopeInput
        case .output:
            return kAudioDevicePropertyScopeOutput
        }
    }

    var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .input:
            return kAudioHardwarePropertyDefaultInputDevice
        case .output:
            return kAudioHardwarePropertyDefaultOutputDevice
        }
    }
}

struct AudioControlSnapshot {
    let volume: Float?
    let volumeIsAdjustable: Bool
    let isMuted: Bool?
    let muteIsAdjustable: Bool
}
