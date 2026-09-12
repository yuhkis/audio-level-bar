# Contributing

**English** | [日本語](CONTRIBUTING.ja.md)

Issues and pull requests are welcome. This is a personal project built in spare time, so no response or turnaround is promised, and a change that does not fit the project's direction may be declined; see Project status in [README.md](README.md).

The app's own code is provided under the MIT License in the root [`LICENSE`](LICENSE). Sending a pull request assumes you can provide your change under that same MIT License, and that any third-party work it contains is identified with its source and license.

## Getting started

1. Clone the repository onto an Apple Silicon Mac
2. Run `make setup-dev` once on that Mac. It points `core.hooksPath` at `scripts/git-hooks`, creates the template for `.local/private-patterns.txt`, and pins your own Git identity to this clone
3. Run `make test` for the UI-independent unit tests
4. Run `make build` to compile the app itself
5. Run `make ci` to check metadata, localization, the vendored library, and the app bundle
6. When you change a user-facing setting, command, permission, or display, update `README.md` (and `README.ja.md`) or `DESIGN.md` in the same change

`make ci` builds the app bundle, and `scripts/build-app.sh` refuses to reuse a build number for different contents. A second local `make ci` after any change therefore fails with "Refusing to reuse …" until you remove `dist/`. Do that rather than changing the build number: leave `CFBundleVersion` in `Resources/Info.plist` alone in a pull request, so that concurrent pull requests do not conflict on that one line, and the maintainer bumps it when the next deployment candidate is prepared. GitHub Actions starts without a `dist/` directory and is unaffected.

For verification that writes to Core Audio or real devices, record the default device, volume, and input gain before you start, and restore them afterwards. `make diagnose` is read-only, and is not run in CI.

## Rules for any change

- Do not record, persist, or transmit audio samples
- Keep system playback capture and the processed microphone explicit opt-ins
- Never assume 100% for a volume a device does not report
- Do not show a slider for a property that cannot be changed
- User-facing text goes through `localized(...)`, keyed by its English wording, with the Japanese translation added to `Resources/ja.lproj/Localizable.strings` in the same change. `make check-localization` fails on a key missing from either table, used by nothing, or whose English table entry is not identical to its key
- When changing `ThirdParty/` or `Vendor/`, update the source, pinned version, SHA-256, license, and regeneration steps at the same time
- Do not treat the GUI, TCC, or audio quality in a consuming app as verified on the strength of unit tests or a moving meter

## Verification notes in a pull request

Say which commands you ran, which macOS and Xcode you used, which audio devices were connected, and what you did and did not confirm on real hardware. Do not attach secrets, personal absolute paths, audio data, or the contents of the TCC database.
