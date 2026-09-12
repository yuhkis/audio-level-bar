// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Yuhki Shiraishi
//
// This file belongs to Audio Level Bar, not to the upstream projects it is
// built against. It sits beside them, but it is covered by the MIT License
// in the repository root, not by the upstream licenses listed in
// THIRD_PARTY_NOTICES.md.

#include "WebRTCNoiseSuppression.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>

#include "api/audio/audio_processing.h"

namespace {

constexpr int32_t kInvalidArgument = -1000;

constexpr const char *kInvalidSampleRateError =
    "sample rate must be between 8000 and 384000 Hz";
constexpr const char *kInvalidLevelError =
    "noise suppression level must be 0 (weak), 1 (medium), or 2 (strong)";
constexpr const char *kAllocationError =
    "could not allocate the WebRTC noise suppressor";
constexpr const char *kCreationError =
    "could not create WebRTC Audio Processing";
constexpr const char *kInitializationError =
    "could not initialize WebRTC Audio Processing for this sample rate";
constexpr const char *kUnexpectedError =
    "unexpected error while creating the WebRTC noise suppressor";

webrtc::AudioProcessing::Config::NoiseSuppression::Level suppressionLevel(
    int32_t level) {
    switch (level) {
        case ALB_WEBRTC_NOISE_SUPPRESSION_WEAK:
            return webrtc::AudioProcessing::Config::NoiseSuppression::kLow;
        case ALB_WEBRTC_NOISE_SUPPRESSION_MEDIUM:
            return webrtc::AudioProcessing::Config::NoiseSuppression::kModerate;
        case ALB_WEBRTC_NOISE_SUPPRESSION_STRONG:
            return webrtc::AudioProcessing::Config::NoiseSuppression::kHigh;
        default:
            return webrtc::AudioProcessing::Config::NoiseSuppression::kModerate;
    }
}

void setError(const char **outError, const char *message) {
    if (outError != nullptr) {
        *outError = message;
    }
}

}  // namespace

struct ALBWebRTCNoiseSuppressor {
    explicit ALBWebRTCNoiseSuppressor(uint32_t sampleRateHz)
        : streamConfig(static_cast<int>(sampleRateHz), 1),
          blockFrames(static_cast<uint32_t>(streamConfig.num_frames())),
          inputBlock(std::make_unique<float[]>(blockFrames)),
          outputBlock(std::make_unique<float[]>(blockFrames)) {
        std::fill_n(inputBlock.get(), blockFrames, 0.0f);
        std::fill_n(outputBlock.get(), blockFrames, 0.0f);
    }

    rtc::scoped_refptr<webrtc::AudioProcessing> processing;
    const webrtc::StreamConfig streamConfig;
    const uint32_t blockFrames;
    std::unique_ptr<float[]> inputBlock;
    std::unique_ptr<float[]> outputBlock;
    uint32_t cursor = 0;
};

extern "C" ALBWebRTCNoiseSuppressor *ALBWebRTCNoiseSuppressorCreate(
    uint32_t sampleRateHz,
    int32_t level,
    const char **outError) {
    setError(outError, nullptr);

    if (sampleRateHz < 8000 || sampleRateHz > 384000) {
        setError(outError, kInvalidSampleRateError);
        return nullptr;
    }
    if (level < ALB_WEBRTC_NOISE_SUPPRESSION_WEAK ||
        level > ALB_WEBRTC_NOISE_SUPPRESSION_STRONG) {
        setError(outError, kInvalidLevelError);
        return nullptr;
    }

    try {
        std::unique_ptr<ALBWebRTCNoiseSuppressor> suppressor(
            new (std::nothrow) ALBWebRTCNoiseSuppressor(sampleRateHz));
        if (suppressor == nullptr || suppressor->inputBlock == nullptr ||
            suppressor->outputBlock == nullptr) {
            setError(outError, kAllocationError);
            return nullptr;
        }

        webrtc::AudioProcessing::Config config;
        config.noise_suppression.enabled = true;
        config.noise_suppression.level = suppressionLevel(level);
        config.echo_canceller.enabled = false;
        config.gain_controller1.enabled = false;
        config.gain_controller2.enabled = false;
        config.high_pass_filter.enabled = false;

        webrtc::AudioProcessingBuilder builder;
        builder.SetConfig(config);
        suppressor->processing = builder.Create();
        if (suppressor->processing == nullptr) {
            setError(outError, kCreationError);
            return nullptr;
        }

        webrtc::ProcessingConfig processingConfig;
        processingConfig.input_stream() = suppressor->streamConfig;
        processingConfig.output_stream() = suppressor->streamConfig;
        processingConfig.reverse_input_stream() = suppressor->streamConfig;
        processingConfig.reverse_output_stream() = suppressor->streamConfig;
        if (suppressor->processing->Initialize(processingConfig) !=
            webrtc::AudioProcessing::kNoError) {
            setError(outError, kInitializationError);
            return nullptr;
        }

        return suppressor.release();
    } catch (const std::bad_alloc &) {
        setError(outError, kAllocationError);
        return nullptr;
    } catch (...) {
        setError(outError, kUnexpectedError);
        return nullptr;
    }
}

extern "C" int32_t ALBWebRTCNoiseSuppressorProcess(
    ALBWebRTCNoiseSuppressor *suppressor,
    const float *input,
    float *output,
    int32_t frameCount) {
    if (frameCount == 0) {
        return 0;
    }
    if (frameCount < 0 || suppressor == nullptr ||
        suppressor->processing == nullptr ||
        input == nullptr || output == nullptr) {
        return kInvalidArgument;
    }

    int32_t firstError = webrtc::AudioProcessing::kNoError;
    for (int32_t index = 0; index < frameCount; ++index) {
        const float inputSample = input[index];
        output[index] = suppressor->outputBlock[suppressor->cursor];
        suppressor->inputBlock[suppressor->cursor] = inputSample;
        ++suppressor->cursor;

        if (suppressor->cursor == suppressor->blockFrames) {
            const float *sourceChannels[] = {suppressor->inputBlock.get()};
            float *destinationChannels[] = {suppressor->outputBlock.get()};
            const int result = suppressor->processing->ProcessStream(
                sourceChannels,
                suppressor->streamConfig,
                suppressor->streamConfig,
                destinationChannels);
            if (result != webrtc::AudioProcessing::kNoError) {
                if (firstError == webrtc::AudioProcessing::kNoError) {
                    firstError = result;
                }
                std::memcpy(
                    suppressor->outputBlock.get(),
                    suppressor->inputBlock.get(),
                    suppressor->blockFrames * sizeof(float));
            }
            suppressor->cursor = 0;
        }
    }

    return firstError;
}

extern "C" void ALBWebRTCNoiseSuppressorDestroy(
    ALBWebRTCNoiseSuppressor *suppressor) {
    delete suppressor;
}

extern "C" uint32_t ALBWebRTCNoiseSuppressorLatencyFrames(
    const ALBWebRTCNoiseSuppressor *suppressor) {
    return suppressor == nullptr ? 0 : suppressor->blockFrames;
}
