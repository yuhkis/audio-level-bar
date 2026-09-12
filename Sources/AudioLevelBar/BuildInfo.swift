import Foundation

enum AudioLevelBarBuildInfo {
    private static let unavailable = "unknown"

    static var version: String {
        bundleString("CFBundleShortVersionString")
    }

    static var build: String {
        bundleString("CFBundleVersion")
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? unavailable
    }

    static var gitCommit: String {
        bundleString("AudioLevelBarGitCommit")
    }

    static var gitState: String {
        bundleString("AudioLevelBarGitState")
    }

    static var sourceFingerprint: String {
        bundleString("AudioLevelBarSourceFingerprint")
    }

    static var provenanceTimestamp: String {
        bundleString("AudioLevelBarProvenanceTimestamp")
    }

    static var report: String {
        [
            "Audio Level Bar \(version) (build \(build))",
            "Bundle ID: \(bundleIdentifier)",
            "Git commit: \(gitCommit)",
            "Git state: \(gitState)",
            "Source fingerprint: \(sourceFingerprint)",
            "Provenance timestamp: \(provenanceTimestamp)",
        ].joined(separator: "\n")
    }

    private static func bundleString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? unavailable
    }
}
