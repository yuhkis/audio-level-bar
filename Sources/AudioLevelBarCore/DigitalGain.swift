import Foundation

public enum DigitalGain {
    public static let minimumDecibels: Float = -12
    public static let maximumDecibels: Float = 12
    public static let neutralDecibels: Float = 0

    public static func clampedDecibels(_ decibels: Float) -> Float {
        guard decibels.isFinite else {
            return neutralDecibels
        }

        return min(max(decibels, minimumDecibels), maximumDecibels)
    }

    public static func amplitude(decibels: Float) -> Float {
        pow(10, clampedDecibels(decibels) / 20)
    }
}
