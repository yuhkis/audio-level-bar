import AudioLevelBarCore
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannelCount: Int
    let outputChannelCount: Int
    let transport: AudioDeviceTransport

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
