# WebRTC noise-suppression binary

`Vendor/WebRTCNoiseSuppression.xcframework` contains an arm64 macOS static
library built from:

- checked-in static library SHA-256:
  `bed0622218382fa663d0315cc6e1abe110a7753e10754b0bef77b6d1fcb47b43`

- webrtc-audio-processing 2.1
  - archive SHA-256: `ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe`
- Abseil 20240722.0
  - source SHA-256: `f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3`
  - WrapDB patch SHA-256: `12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b`

The local C bridge enables only WebRTC noise suppression. Echo cancellation,
both automatic gain controllers, and the high-pass filter remain disabled.
Weak, medium, and strong map to WebRTC's Low, Moderate, and High levels. The
bridge accepts arbitrary mono Float32 callback sizes through a preallocated
10 ms FIFO, adding one fixed 10 ms block of latency.

Rebuild the checked-in binary from the repository root:

```console
scripts/build-webrtc-noise-suppression.sh
```

The script downloads and verifies both pinned source archives, targets macOS
14.2 on arm64, checks Mach-O deployment targets with `vtool`, builds the
XCFramework, and runs the C smoke test. The smoke test covers all three
suppression levels at 44.1 and 48 kHz, arbitrary callback boundaries, fixed
10 ms latency, finite output progression, and in-place processing. For an
offline rebuild, set
`ALB_WEBRTC_ARCHIVE` to a previously downloaded, hash-matching
`webrtc-audio-processing-2.1.tar.xz`. Set `ALB_MESON_PACKAGE_CACHE` to a
directory containing the pinned Abseil source and WrapDB patch archives for a
fully offline rebuild; otherwise Meson downloads them from the configured URLs
and verifies the hashes above.

The upstream notices are retained under `LICENSES/`, including the notices for
the statically linked Ooura FFT, SPL square-root routine, FFT, PFFFT, RNNoise,
WebRTC, and Abseil code.
