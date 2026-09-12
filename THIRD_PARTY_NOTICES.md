# Third-party notices

**English** | [日本語](THIRD_PARTY_NOTICES.ja.md)

Audio Level Bar's own license and the licenses of third-party components are handled separately. The app's code is covered by the MIT License in the root [`LICENSE`](LICENSE). The grant follows origin rather than directory. `ThirdParty/` holds the upstream license texts, and `Vendor/` holds the static library the upstream code is compiled into; neither is covered by it, and the license, copyright, and PATENTS file of each upstream project take precedence. The C ABI wrapper listed below is Audio Level Bar's own code and is MIT like the rest of the app. Every source file of the wrapper and of its smoke test carries an SPDX header saying so, and the README and build metadata beside them are this project's own as well.

## WebRTC noise suppression

`Vendor/WebRTCNoiseSuppression.xcframework` is a build binary that statically links the following components for arm64 macOS.

- webrtc-audio-processing 2.1
- Abseil 20240722.0
- The Ooura FFT, SPL square-root, FFT, PFFFT, and RNNoise code bundled with WebRTC
- A small C ABI wrapper belonging to Audio Level Bar

The pinned sources, patches, SHA-256 of the vendored static library, the regeneration procedure, and the smoke test are recorded in [ThirdParty/WebRTCNoiseSuppression/README.md](ThirdParty/WebRTCNoiseSuppression/README.md). The upstream notices are kept verbatim in [ThirdParty/WebRTCNoiseSuppression/LICENSES](ThirdParty/WebRTCNoiseSuppression/LICENSES); `make app` bundles them into the app and `make verify-app` checks them against the originals.

This file does not replace the upstream license texts. When using or redistributing, read each original in the directory above.
