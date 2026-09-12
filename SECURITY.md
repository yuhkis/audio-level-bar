# Security policy

**English** | [日本語](SECURITY.ja.md)

## Supported version

The latest state of `main` is covered, together with the most recent release once one has been tagged. Earlier tags are not.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security → Report a vulnerability). Do not post unfixed vulnerabilities, credentials, personal information, audio data, or device-specific logs to a public issue.

Include the affected version or commit, the conditions to reproduce, the safe behavior you expected, and a minimal reproduction. Acknowledgement and disclosure timing are arranged individually, after the scope of impact has been confirmed.

This app uses microphone and system audio permissions, and can create Core Audio process taps and aggregate devices. Permission boundaries, unintended storage or transmission of audio, interference with other processes, and stranded devices or taps are all treated as security problems.
