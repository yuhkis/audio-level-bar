# Development reference

Use the section that matches the change. The product and safety boundaries that hold for every change are in [AGENTS.md](../AGENTS.md); the detail lives here so that a task loads the guidance it needs rather than the whole instruction set.

## Verification scope

| Change | Evidence to collect |
| --- | --- |
| Documentation or instructions only | The diff, the links and anchors it contains, and consistency with the documented commands and behavior |
| UI-independent level calculations | `make test`, the unit tests for those calculations |
| User-facing text | `make check-localization`, plus an app check when the display or the layout changes |
| Core Audio, permissions, devices, or volume writes | The automated checks that apply, and the real-device cases below |
| Build, bundle, signing, or a deployment candidate | `make ci` and candidate verification, plus real-device checks for the behavior the candidate changes |

`make ci` builds the app bundle, so the build-number rule below applies to it whatever the change was; read that section before running it in a checkout that still holds a candidate in `dist/`.

## Audio verification

- Before Core Audio changes, run `make test` and `make diagnose` when practical to establish a baseline. `make diagnose` must stay read-only: it enumerates the real devices and their control capabilities without altering volume or the selected devices.
- GUI, microphone permission, device switching, and volume writes require explicit real-device testing. Preserve the original default devices, volume, and input gain before a write test, and restore them afterward.
- Test built-in audio first, then the connected external or virtual devices that matter to the change: a USB audio interface, a wireless microphone system, AirPods, Teams Audio, ZoomAudioDevice, and BlackHole. Include unplug/replug and sleep/wake for anything that touches device or resource lifecycle. Record which devices were unavailable and which cases went untested.
- Anything that creates and destroys Core Audio resources repeatedly has to be exercised well past the point where it starts passing, and the cycle count reported. A change that rebuilt the published microphone's aggregate device on every idle transition survived three consecutive sessions, and three was the number its verification happened to use. It failed on the fifth, in a way that left the device missing from every app's input list, and was reverted. A few passes in a row do not close this.
- Never destroy an aggregate device while another process has it open, in the app or in a throwaway experiment. Read `kAudioDevicePropertyDeviceIsRunningSomewhere` first. A wedged `coreaudiod` stops answering any process on the machine, and while SIP is enabled the only way back is a restart.

For processed-microphone changes, select the affected cases from [DESIGN.md's real-device verification](../DESIGN.md#加工済みマイクの実機検証), and preserve its contracts for the physical default input, the opt-in, consuming apps, idle, and teardown. The [known limitation](../README.md#known-limitation-a-second-open-in-the-same-process-is-silent) records why rebuilding the publication on every idle transition was withdrawn; do not reintroduce it.

## Build and installation

When preparing a deployment candidate:

1. Bump `CFBundleVersion` in `Resources/Info.plist`, and commit the code, its documentation, and the bump together before building.
2. Run `make app`, then `make verify-app` against `dist/Audio Level Bar.app`.
3. Carry out the real-device verification the change calls for against that candidate.
4. Quit the app normally, run `make install`, and verify the installed app. [Installing and everyday use](../README.md#installing-and-everyday-use) covers the separate login-agent step, and what to confirm when the same bundle is carried to more than one Mac.

`make app` embeds the commit SHA, the clean/dirty state of the working tree, a source fingerprint, and a provenance timestamp. The fingerprint covers every tracked file and every untracked file that is not ignored, documentation included. `scripts/build-app.sh` compares the commit, the state, and the fingerprint against a bundle already in `dist/` that carries the same version and build number, and refuses to reuse that pair for a different snapshot; with no such bundle there is nothing to compare against, which is why a fresh CI checkout is unaffected. Building before committing therefore spends a build number on the previous commit and a dirty tree, and the committed bundle then costs a second one to say the same thing — commit first.

The build number identifies a deployment candidate, not a commit:

- Bump it for a change that is going to be built, verified on hardware, and installed, and commit the bump with the change it covers.
- A commit that builds and installs nothing — a documentation-only change, for instance — needs no bump. `make ci` builds the app, so running it again locally while `dist/` still holds a candidate carrying the same build number is refused whatever changed; remove `dist/` and run it again rather than spending a build number, and build the candidate again when the next one is actually being prepared.
- A pull request from outside the project is the exception in both directions: it leaves `CFBundleVersion` alone and removes `dist/` between local runs, so that concurrent pull requests do not conflict on that one line, and the maintainer bumps the build number when the next deployment candidate is prepared.

`make app` signs ad hoc by default. `CODESIGN_IDENTITY` names a certificate explicitly; one is never selected automatically from the keychain, which may hold a certificate issued to someone else (the same contract as wkr-macos). A certificate signature adds the hardened runtime and the audio-input entitlement it requires. [Building and running](../README.md#building-and-running) has the command and the signature verification contract.

`make install` refuses while the app is running. Quit it through its own Quit item or run:

```console
osascript -e 'tell application id "io.github.yuhkis.audio-level-bar" to quit'
```

Never force quit while the processed microphone is published; that is one of the ways to leave Core Audio wedged for the whole machine.

## Localization

User-facing text goes through `localized(...)` from `Sources/AudioLevelBarCore/Localization.swift`. The key is the English wording, so a bundle without a translation, a `swift run` build, and the tests all fall back to readable English. Add the Japanese to `Resources/ja.lproj/Localizable.strings` and the identity entry to `Resources/en.lproj/Localizable.strings` in the same change; `make check-localization` fails on a key missing from either table, used by nothing, or whose English table entry is not identical to its key.

Keep the key and the opening `localized(` in one expression that a newline-folded grep can find, and do not use a multi-line string literal as a key — the extractor in `scripts/check-localization.sh` will not see it.

`AudioDiagnostics` and `AudioResourceInventory` are the `--diagnose` and `--reclaim-taps` command line output. They run outside the app bundle, where no string table is available, so their text stays English and is not localized. The Japanese substrings in `AudioDeviceSymbol` are device-name matching patterns, not display text.
