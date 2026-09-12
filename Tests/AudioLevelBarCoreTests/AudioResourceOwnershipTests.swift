import XCTest
@testable import AudioLevelBarCore

final class AudioResourceOwnershipTests: XCTestCase {
    private let namespace = AudioResourceNamespace(
        publishedMicrophoneUID: "io.github.example.app.processed-microphone.public",
        legacyPublishedMicrophoneUIDs: [
            "com.example.old.processed-microphone.public"
        ],
        privateTapAggregateUIDPrefix: "io.github.example.app.tap.",
        publishedMicrophoneTapName: "Example Processed Microphone Tap",
        systemOutputMeterTapName: "Example System Output Meter",
        bundleIdentifiers: [
            "io.github.example.app",
            "com.example.old",
        ]
    )

    func testPublishedMicrophoneUIDIsRecognized() {
        XCTAssertEqual(
            AudioResourceClassifier.ownership(
                ofAggregateUID: "io.github.example.app.processed-microphone.public",
                in: namespace
            ),
            .publishedMicrophone
        )
    }

    func testLegacyPublishedMicrophoneUIDIsRecognized() {
        XCTAssertEqual(
            AudioResourceClassifier.ownership(
                ofAggregateUID: "com.example.old.processed-microphone.public",
                in: namespace
            ),
            .legacyPublishedMicrophone
        )
    }

    func testPrivateTapAggregateIsRecognizedByPrefix() {
        XCTAssertEqual(
            AudioResourceClassifier.ownership(
                ofAggregateUID: "io.github.example.app.tap.5F2C0B8E-0000-4000-8000-000000000000",
                in: namespace
            ),
            .systemOutputMeter
        )
    }

    func testAnotherAppsAggregateIsForeign() {
        for uid in ["ZoomAudioDevice", "BlackHole2ch", "com.microsoft.teams.audio"] {
            XCTAssertEqual(
                AudioResourceClassifier.ownership(ofAggregateUID: uid, in: namespace),
                .foreign,
                "\(uid) を自分のものと誤認してはいけません"
            )
        }
    }

    /// The published UID is matched exactly, not by prefix. A cleanup sweep
    /// destroys what it matches, so a near-miss must not be treated as ours.
    func testUIDThatMerelyExtendsThePublishedUIDIsForeign() {
        XCTAssertEqual(
            AudioResourceClassifier.ownership(
                ofAggregateUID: "io.github.example.app.processed-microphone.public.backup",
                in: namespace
            ),
            .foreign
        )
    }

    func testUIDThatIsAPrefixOfThePublishedUIDIsForeign() {
        XCTAssertEqual(
            AudioResourceClassifier.ownership(
                ofAggregateUID: "io.github.example.app.processed-microphone",
                in: namespace
            ),
            .foreign
        )
    }

    func testOnlyForeignIsNotOwnedByThisApp() {
        XCTAssertFalse(AudioResourceOwnership.foreign.isOwnedByThisApp)
        for ownership in [
            AudioResourceOwnership.publishedMicrophone,
            .legacyPublishedMicrophone,
            .systemOutputMeter,
        ] {
            XCTAssertTrue(ownership.isOwnedByThisApp)
        }
    }

    /// The safety property that matters: a tap another app created is not ours
    /// no matter what it calls itself. Acting on a name match alone would
    /// destroy that app's tap.
    func testForeignBundleIsNotOursEvenWithAnIdenticalTapName() {
        XCTAssertNil(
            AudioResourceClassifier.ownership(
                ofTapWithBundleIDs: ["com.example.someoneelse"],
                name: "Example Processed Microphone Tap",
                in: namespace
            )
        )
    }

    func testTapWithNoRecordedBundleIsNotOurs() {
        XCTAssertNil(
            AudioResourceClassifier.ownership(
                ofTapWithBundleIDs: [],
                name: "Example Processed Microphone Tap",
                in: namespace
            )
        )
    }

    func testCurrentBundleTapsAreAttributedByName() {
        XCTAssertEqual(
            AudioResourceClassifier.ownership(
                ofTapWithBundleIDs: ["io.github.example.app"],
                name: "Example Processed Microphone Tap",
                in: namespace
            ),
            .publishedMicrophone
        )
        XCTAssertEqual(
            AudioResourceClassifier.ownership(
                ofTapWithBundleIDs: ["io.github.example.app"],
                name: "Example System Output Meter",
                in: namespace
            ),
            .systemOutputMeter
        )
    }

    func testLegacyBundleTapIsMarkedLegacy() {
        XCTAssertEqual(
            AudioResourceClassifier.ownership(
                ofTapWithBundleIDs: ["com.example.old"],
                name: "Example Processed Microphone Tap",
                in: namespace
            ),
            .legacyPublishedMicrophone
        )
    }

    /// A tap from one of our builds whose naming this version does not know is
    /// still ours, and still a cleanup candidate.
    func testOurBundleWithUnknownTapNameIsStillOurs() {
        XCTAssertEqual(
            AudioResourceClassifier.ownership(
                ofTapWithBundleIDs: ["com.example.old"],
                name: "Some Older Tap Name",
                in: namespace
            ),
            .legacyPublishedMicrophone
        )
    }

    func testProvisionalAttributionMatchesNamesExactly() {
        XCTAssertEqual(
            AudioResourceClassifier.provisionalOwnership(
                ofTapName: "Example Processed Microphone Tap",
                in: namespace
            ),
            .publishedMicrophone
        )
        XCTAssertNil(
            AudioResourceClassifier.provisionalOwnership(
                ofTapName: "Example Processed Microphone Tap 2",
                in: namespace
            )
        )
    }
}
