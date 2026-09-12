import Foundation

public enum MeterScale {
    public static let displayFloorDecibels: Float = -60
    public static let calculationFloorDecibels: Float = -80

    public static func decibels(
        amplitude: Float,
        floor: Float = calculationFloorDecibels
    ) -> Float {
        guard amplitude.isFinite, amplitude > 0 else {
            return floor
        }

        return max(floor, 20 * log10(amplitude))
    }

    public static func normalized(
        decibels: Float,
        floor: Float = displayFloorDecibels
    ) -> Float {
        guard decibels.isFinite, floor < 0 else {
            return 0
        }

        return min(max((decibels - floor) / -floor, 0), 1)
    }

    public static func menuText(decibels: Float) -> String {
        guard decibels.isFinite, decibels > displayFloorDecibels else {
            return "-inf"
        }

        return String(format: "%+.0f", decibels)
    }
}
