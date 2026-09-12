// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Yuhki Shiraishi
//
// This file belongs to Audio Level Bar, not to the upstream projects it is
// built against. It sits beside them, but it is covered by the MIT License
// in the repository root, not by the upstream licenses listed in
// THIRD_PARTY_NOTICES.md.

#include "WebRTCNoiseSuppression.h"

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

static int fail(const char *message) {
    fprintf(stderr, "WebRTCNoiseSuppression smoke test failed: %s\n", message);
    return 1;
}

static int fail_case(const char *message, uint32_t sample_rate_hz, int32_t level) {
    fprintf(
        stderr,
        "WebRTCNoiseSuppression smoke test failed at %u Hz, level %d: %s\n",
        sample_rate_hz,
        level,
        message);
    return 1;
}

static int run_case(uint32_t sample_rate_hz, int32_t level) {
    const char *error = NULL;
    ALBWebRTCNoiseSuppressor *suppressor =
        ALBWebRTCNoiseSuppressorCreate(sample_rate_hz, level, &error);
    if (suppressor == NULL) {
        fprintf(
            stderr,
            "create failed at %u Hz, level %d: %s\n",
            sample_rate_hz,
            level,
            error == NULL ? "unknown" : error);
        return 1;
    }

    const uint32_t block_frames = sample_rate_hz / 100;
    if (ALBWebRTCNoiseSuppressorLatencyFrames(suppressor) != block_frames) {
        ALBWebRTCNoiseSuppressorDestroy(suppressor);
        return fail_case(
            "latency was not one 10 ms block",
            sample_rate_hz,
            level);
    }

    // Two complete 10 ms blocks plus a short in-place callback. The maximum
    // case is 2 * 480 + 19 frames at 48 kHz.
    float input[979];
    float output[979];
    const size_t total_frames = (size_t)block_frames * 2 + 19;
    for (size_t index = 0; index < total_frames; ++index) {
        const float seconds = (float)index / (float)sample_rate_hz;
        const float envelope = 0.72f + 0.28f * sinf(seconds * 18.8495559f);
        input[index] = envelope * (
            0.34f * sinf(seconds * 1130.97336f)
            + 0.16f * sinf(seconds * 2261.94671f));
        output[index] = 99.0f;
    }

    const int32_t first_chunk = 137;
    const int32_t first_remainder = (int32_t)block_frames - first_chunk;
    if (ALBWebRTCNoiseSuppressorProcess(
            suppressor,
            input,
            output,
            first_chunk) != 0 ||
        ALBWebRTCNoiseSuppressorProcess(
            suppressor,
            input + first_chunk,
            output + first_chunk,
            first_remainder) != 0) {
        ALBWebRTCNoiseSuppressorDestroy(suppressor);
        return fail_case(
            "arbitrary callback sizes returned an error",
            sample_rate_hz,
            level);
    }
    for (size_t index = 0; index < block_frames; ++index) {
        if (output[index] != 0.0f) {
            ALBWebRTCNoiseSuppressorDestroy(suppressor);
            return fail_case(
                "initial 10 ms latency was not silence",
                sample_rate_hz,
                level);
        }
    }

    const int32_t second_chunk = (int32_t)block_frames / 3;
    const int32_t second_remainder = (int32_t)block_frames - second_chunk;
    if (ALBWebRTCNoiseSuppressorProcess(
            suppressor,
            input + block_frames,
            output + block_frames,
            second_chunk) != 0 ||
        ALBWebRTCNoiseSuppressorProcess(
            suppressor,
            input + block_frames + second_chunk,
            output + block_frames + second_chunk,
            second_remainder) != 0) {
        ALBWebRTCNoiseSuppressorDestroy(suppressor);
        return fail_case(
            "second arbitrary-size block returned an error",
            sample_rate_hz,
            level);
    }

    double output_energy = 0.0;
    for (size_t index = block_frames; index < block_frames * 2; ++index) {
        if (!isfinite(output[index])) {
            ALBWebRTCNoiseSuppressorDestroy(suppressor);
            return fail_case(
                "processed output was not finite",
                sample_rate_hz,
                level);
        }
        output_energy += (double)output[index] * (double)output[index];
    }
    if (output_energy <= 1e-8) {
        ALBWebRTCNoiseSuppressorDestroy(suppressor);
        return fail_case(
            "output did not progress after the initial latency block",
            sample_rate_hz,
            level);
    }

    if (ALBWebRTCNoiseSuppressorProcess(
            suppressor,
            input + block_frames * 2,
            input + block_frames * 2,
            19) != 0) {
        ALBWebRTCNoiseSuppressorDestroy(suppressor);
        return fail_case(
            "in-place processing returned an error",
            sample_rate_hz,
            level);
    }
    for (size_t index = block_frames * 2; index < total_frames; ++index) {
        if (!isfinite(input[index])) {
            ALBWebRTCNoiseSuppressorDestroy(suppressor);
            return fail_case(
                "in-place output was not finite",
                sample_rate_hz,
                level);
        }
    }
    ALBWebRTCNoiseSuppressorDestroy(suppressor);
    return 0;
}

int main(void) {
    const uint32_t sample_rates[] = {44100, 48000};
    for (size_t rate_index = 0;
         rate_index < sizeof(sample_rates) / sizeof(sample_rates[0]);
         ++rate_index) {
        for (int32_t level = ALB_WEBRTC_NOISE_SUPPRESSION_WEAK;
             level <= ALB_WEBRTC_NOISE_SUPPRESSION_STRONG;
             ++level) {
            if (run_case(sample_rates[rate_index], level) != 0) {
                return 1;
            }
        }
    }

    const char *error = NULL;
    ALBWebRTCNoiseSuppressor *suppressor =
        ALBWebRTCNoiseSuppressorCreate(48000, 3, &error);
    if (suppressor != NULL || error == NULL) {
        ALBWebRTCNoiseSuppressorDestroy(suppressor);
        return fail("invalid level was accepted");
    }

    puts("WebRTCNoiseSuppression smoke test passed");
    return 0;
}
