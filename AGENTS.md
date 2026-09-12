# Audio Level Bar agent instructions

These product and safety boundaries hold for every change. Read a task reference below only when it applies.

## Product and safety boundaries

- Do not record, persist, or transmit audio samples. System-output capture and the processed microphone are explicit opt-ins: keep `NSAudioCaptureUsageDescription` in the bundle, and obtain the additional system-audio recording permission only when one of them is enabled.
- With system-output monitoring off, the menu-bar speaker value is the macOS output volume setting. With monitoring on, the colored meter and number are live system-playback RMS dBFS, and the white marker is the output volume setting.
- The menu-bar microphone value is live RMS dBFS from the current macOS default input — except that a Bluetooth default input is metered only while a panel is showing, unless the user enabled “Always monitor Bluetooth microphones” or the processed microphone is on (that feature keeps metering continuous). While paused the value is `--`, never a measured silence: opening a Bluetooth microphone degrades the headset's playback for as long as it stays open, so the meter must not hold one open with nobody looking.
- Label the adjustable microphone scalar as input gain, not microphone level. Show sliders only when Core Audio reports that the property is settable, and never infer 100% for a device that does not report a volume property.
- Never destroy an aggregate device while another process has it open, in the app or in a throwaway experiment: it stops coreaudiod answering any process on the machine, and SIP means the only way back is a restart. Read `kAudioDevicePropertyDeviceIsRunningSomewhere` first.
- Never force quit while the processed microphone is published; that is one of the ways to leave Core Audio wedged for the whole machine. Quit through the app's own Quit item or `osascript -e 'tell application id "io.github.yuhkis.audio-level-bar" to quit'`.
- At the start and at the end of a change, check the branch, the index, the changed paths, and the upstream state that matters. Preserve unrelated work, and stage only this task's paths.

## Read for the current task

| Task | Reference |
| --- | --- |
| Change behavior or architecture | The relevant sections of [README.md](README.md) and [DESIGN.md](DESIGN.md); keep the English and Japanese READMEs consistent |
| Change Core Audio or verify devices | [Audio verification](docs/development.md#audio-verification); record the baseline before changing device or volume state, and restore it afterward |
| Build a candidate, sign, or install | [Build and installation](docs/development.md#build-and-installation); commit before building, and verify the bundle itself |
| Change user-facing strings | [Localization](docs/development.md#localization) |
| Change vendored code, dependencies, or publication policy | [CONTRIBUTING.md](CONTRIBUTING.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and the relevant section of [ROADMAP.md](ROADMAP.md) |

## Completion

- Update `README.md` and `README.ja.md`, or `DESIGN.md`, in the same change whenever adding or changing a command, preference, keyboard shortcut, permission, or user-visible behavior. The two READMEs carry the same content in English and Japanese; changing one without the other leaves the pair inconsistent. `DESIGN.md` and `ROADMAP.md` are Japanese-only by decision.
- Run the checks that cover the change and report their results. Documentation-only work needs a diff and a check of the links it carries, not audio-device tests or a candidate build; see [verification scope](docs/development.md#verification-scope) for code and app changes.
- Distinguish the source, the built candidate, the installed app, and real-device verification. A passing unit test or a moving meter does not establish GUI, permission, or consuming-app audio behavior. Say explicitly what was not verified.
