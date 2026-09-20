// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AudioLevelBar",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "AudioLevelBar", targets: ["AudioLevelBar"])
    ],
    targets: [
        .binaryTarget(
            name: "WebRTCNoiseSuppression",
            path: "Vendor/WebRTCNoiseSuppression.xcframework"
        ),
        .target(
            name: "AudioLevelBarCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Catches the Objective-C exceptions AVFAudio raises when a device
        // changes under the processed microphone's engines.
        .target(
            name: "ObjCExceptionShim"
        ),
        .executableTarget(
            name: "AudioLevelBar",
            dependencies: [
                "AudioLevelBarCore",
                "ObjCExceptionShim",
                "WebRTCNoiseSuppression"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("c++")
            ]
        ),
        .testTarget(
            name: "AudioLevelBarCoreTests",
            dependencies: ["AudioLevelBarCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // The app target's HAL lifecycle wiring, through a fake
        // HALLifecycleCalls. These tests never reach coreaudiod.
        .testTarget(
            name: "AudioLevelBarTests",
            dependencies: ["AudioLevelBar", "AudioLevelBarCore", "ObjCExceptionShim"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
