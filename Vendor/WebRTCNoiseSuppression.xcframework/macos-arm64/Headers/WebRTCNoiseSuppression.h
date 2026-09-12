// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Yuhki Shiraishi
//
// This file belongs to Audio Level Bar, not to the upstream projects it is
// built against. It sits beside them, but it is covered by the MIT License
// in the repository root, not by the upstream licenses listed in
// THIRD_PARTY_NOTICES.md.

#ifndef AUDIO_LEVEL_BAR_WEBRTC_NOISE_SUPPRESSION_H
#define AUDIO_LEVEL_BAR_WEBRTC_NOISE_SUPPRESSION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ALBWebRTCNoiseSuppressor ALBWebRTCNoiseSuppressor;

enum {
    ALB_WEBRTC_NOISE_SUPPRESSION_WEAK = 0,
    ALB_WEBRTC_NOISE_SUPPRESSION_MEDIUM = 1,
    ALB_WEBRTC_NOISE_SUPPRESSION_STRONG = 2,
};

// Creates a mono Float32 WebRTC noise suppressor. `outError`, when supplied,
// receives a pointer to a process-lifetime string if creation fails.
ALBWebRTCNoiseSuppressor *ALBWebRTCNoiseSuppressorCreate(
    uint32_t sampleRateHz,
    int32_t level,
    const char **outError);

// Processes any number of mono frames. Input and output may point to the same
// memory. The first LatencyFrames() samples are silence; subsequent output is
// delayed by that fixed amount. Returns zero on success.
int32_t ALBWebRTCNoiseSuppressorProcess(
    ALBWebRTCNoiseSuppressor *suppressor,
    const float *input,
    float *output,
    int32_t frameCount);

void ALBWebRTCNoiseSuppressorDestroy(
    ALBWebRTCNoiseSuppressor *suppressor);

uint32_t ALBWebRTCNoiseSuppressorLatencyFrames(
    const ALBWebRTCNoiseSuppressor *suppressor);

#ifdef __cplusplus
}
#endif

#endif
