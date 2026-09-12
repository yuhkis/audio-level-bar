import Foundation

public enum AudioDeviceSymbolDirection {
    case input
    case output
}

public enum AudioDeviceTransport: Equatable {
    case builtIn
    case aggregate
    case virtual
    case pci
    case usb
    case fireWire
    case bluetooth
    case bluetoothLE
    case hdmi
    case displayPort
    case airPlay
    case avb
    case thunderbolt
    case continuityCapture
    case unknown
}

public enum AudioDeviceSymbol {
    public static func systemName(
        direction: AudioDeviceSymbolDirection,
        name: String,
        uid: String,
        transport: AudioDeviceTransport
    ) -> String {
        let identity = "\(name) \(uid)".lowercased()

        if containsAny(identity, ["iphone", "ipad"]) || transport == .continuityCapture {
            return "iphone"
        }
        if containsAny(identity, ["macbook", "builtinmicrophone", "builtinspeaker"]) {
            return "laptopcomputer"
        }
        if containsAny(identity, [
            "airpods", "earphone", "headphone", "headset",
            "イヤホン", "ヘッドフォン", "ヘッドホン"
        ]) {
            return "headphones"
        }

        switch direction {
        case .output:
            return outputSystemName(identity: identity, transport: transport)
        case .input:
            return inputSystemName(transport: transport)
        }
    }

    private static func outputSystemName(
        identity: String,
        transport: AudioDeviceTransport
    ) -> String {
        switch transport {
        case .builtIn:
            return "laptopcomputer"
        case .hdmi, .displayPort:
            return "display"
        case .airPlay:
            return containsAny(identity, ["apple tv", "appletv", "テレビ", " tv"])
                ? "appletv.fill"
                : "hifispeaker.fill"
        case .bluetooth, .bluetoothLE, .pci, .usb, .fireWire, .avb, .thunderbolt:
            return "hifispeaker.fill"
        case .aggregate, .virtual:
            return "waveform"
        case .continuityCapture, .unknown:
            return "speaker.wave.2.fill"
        }
    }

    private static func inputSystemName(transport: AudioDeviceTransport) -> String {
        switch transport {
        case .builtIn:
            return "laptopcomputer"
        case .bluetooth, .bluetoothLE:
            return "headphones"
        case .aggregate, .virtual:
            return "waveform"
        case .continuityCapture:
            return "iphone"
        case .pci, .usb, .fireWire, .hdmi, .displayPort, .airPlay, .avb,
                .thunderbolt, .unknown:
            return "mic.fill"
        }
    }

    private static func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains { text.contains($0) }
    }
}
