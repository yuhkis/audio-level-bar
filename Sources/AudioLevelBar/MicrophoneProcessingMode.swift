import AudioLevelBarCore
import Foundation

enum MicrophoneProcessingMode: String, CaseIterable, Identifiable {
    case off
    case apple
    case webRTCLow
    case webRTCModerate
    case webRTCHigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return localized("Off")
        case .apple:
            return localized("Apple voice processing")
        case .webRTCLow:
            return localized("WebRTC noise suppression (low)")
        case .webRTCModerate:
            return localized("WebRTC noise suppression (moderate)")
        case .webRTCHigh:
            return localized("WebRTC noise suppression (high)")
        }
    }
}
