#include "DuckerDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct DuckerDSPState {
    _Atomic float requestedTarget;
    _Atomic uint32_t requestedRampFrames;
    _Atomic uint64_t requestVersion;
    _Atomic uint32_t copyEnabled;

    _Atomic uint64_t callbackCount;
    _Atomic uint64_t inputSampleCount;
    _Atomic uint64_t nonZeroInputSampleCount;
    _Atomic uint32_t inputBufferCount;
    _Atomic uint32_t outputBufferCount;
    _Atomic uint32_t inputByteCount;
    _Atomic uint32_t outputByteCount;
    _Atomic float reportedCurrentGain;

    // The IO callback is the only writer for these fields while running.
    float currentGain;
    float activeTarget;
    uint32_t remainingRampFrames;
    uint64_t appliedVersion;
};

// Gains at or below this floor cannot anchor a multiplicative ramp (a zero
// start would stay zero forever; a zero target would need an infinite ratio),
// so ramp endpoints are floored here. -60 dB, well below audibility, and the
// end-of-ramp snap still lands on the exact requested target.
static const float kMinRampGain = 0.001f;

static float clampGain(float gain) {
    if (!isfinite(gain)) {
        return 1.0f;
    }
    if (gain < 0.0f) {
        return 0.0f;
    }
    if (gain > 1.0f) {
        return 1.0f;
    }
    return gain;
}

DuckerDSPState *DuckerDSPCreate(void) {
    DuckerDSPState *state = calloc(1, sizeof(DuckerDSPState));
    if (state == NULL) {
        return NULL;
    }
    atomic_init(&state->requestedTarget, 1.0f);
    atomic_init(&state->requestedRampFrames, 0);
    atomic_init(&state->requestVersion, 1);
    atomic_init(&state->copyEnabled, 0);
    atomic_init(&state->callbackCount, 0);
    atomic_init(&state->inputSampleCount, 0);
    atomic_init(&state->nonZeroInputSampleCount, 0);
    atomic_init(&state->inputBufferCount, 0);
    atomic_init(&state->outputBufferCount, 0);
    atomic_init(&state->inputByteCount, 0);
    atomic_init(&state->outputByteCount, 0);
    atomic_init(&state->reportedCurrentGain, 1.0f);
    state->currentGain = 1.0f;
    state->activeTarget = 1.0f;
    state->remainingRampFrames = 0;
    state->appliedVersion = 1;
    return state;
}

void DuckerDSPDestroy(DuckerDSPState *state) {
    free(state);
}

void DuckerDSPReset(DuckerDSPState *state, float currentGain, float targetGain,
                    uint32_t rampFrames) {
    if (state == NULL) {
        return;
    }
    currentGain = clampGain(currentGain);
    targetGain = clampGain(targetGain);

    state->currentGain = currentGain;
    atomic_store_explicit(&state->reportedCurrentGain, currentGain,
                          memory_order_relaxed);
    state->activeTarget = targetGain;
    state->remainingRampFrames = rampFrames;
    atomic_store_explicit(&state->requestedTarget, targetGain, memory_order_relaxed);
    atomic_store_explicit(&state->requestedRampFrames, rampFrames, memory_order_relaxed);
    const uint64_t version = atomic_fetch_add_explicit(
        &state->requestVersion, 1, memory_order_release) + 1;
    state->appliedVersion = version;
}

void DuckerDSPSetTarget(DuckerDSPState *state, float targetGain,
                        uint32_t rampFrames) {
    if (state == NULL) {
        return;
    }
    atomic_store_explicit(&state->requestedTarget, clampGain(targetGain),
                          memory_order_relaxed);
    atomic_store_explicit(&state->requestedRampFrames, rampFrames,
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&state->requestVersion, 1, memory_order_release);
}

void DuckerDSPSetCopyEnabled(DuckerDSPState *state, uint32_t enabled) {
    if (state == NULL) {
        return;
    }
    atomic_store_explicit(&state->copyEnabled, enabled != 0, memory_order_release);
}

void DuckerDSPResetTelemetry(DuckerDSPState *state) {
    if (state == NULL) {
        return;
    }
    atomic_store_explicit(&state->callbackCount, 0, memory_order_relaxed);
    atomic_store_explicit(&state->inputSampleCount, 0, memory_order_relaxed);
    atomic_store_explicit(&state->nonZeroInputSampleCount, 0, memory_order_relaxed);
    atomic_store_explicit(&state->inputBufferCount, 0, memory_order_relaxed);
    atomic_store_explicit(&state->outputBufferCount, 0, memory_order_relaxed);
    atomic_store_explicit(&state->inputByteCount, 0, memory_order_relaxed);
    atomic_store_explicit(&state->outputByteCount, 0, memory_order_relaxed);
}

DuckerDSPSnapshot DuckerDSPGetSnapshot(const DuckerDSPState *state) {
    DuckerDSPSnapshot snapshot = {0};
    if (state == NULL) {
        return snapshot;
    }
    snapshot.callbackCount = atomic_load_explicit(
        &state->callbackCount, memory_order_relaxed);
    snapshot.inputSampleCount = atomic_load_explicit(
        &state->inputSampleCount, memory_order_relaxed);
    snapshot.nonZeroInputSampleCount = atomic_load_explicit(
        &state->nonZeroInputSampleCount, memory_order_relaxed);
    snapshot.inputBufferCount = atomic_load_explicit(
        &state->inputBufferCount, memory_order_relaxed);
    snapshot.outputBufferCount = atomic_load_explicit(
        &state->outputBufferCount, memory_order_relaxed);
    snapshot.inputByteCount = atomic_load_explicit(
        &state->inputByteCount, memory_order_relaxed);
    snapshot.outputByteCount = atomic_load_explicit(
        &state->outputByteCount, memory_order_relaxed);
    snapshot.copyEnabled = atomic_load_explicit(
        &state->copyEnabled, memory_order_acquire);
    snapshot.currentGain = atomic_load_explicit(
        &state->reportedCurrentGain, memory_order_relaxed);
    return snapshot;
}

float DuckerDSPCurrentGain(const DuckerDSPState *state) {
    return state == NULL ? 1.0f : atomic_load_explicit(
        &state->reportedCurrentGain, memory_order_relaxed);
}

static uint32_t frameCountForBuffer(const AudioBuffer *buffer) {
    if (buffer == NULL || buffer->mData == NULL ||
        buffer->mNumberChannels == 0) {
        return 0;
    }
    const uint32_t bytesPerFrame =
        buffer->mNumberChannels * (uint32_t)sizeof(Float32);
    return bytesPerFrame == 0 ? 0 : buffer->mDataByteSize / bytesPerFrame;
}

static void clearOutputs(AudioBufferList *outputData) {
    if (outputData == NULL) {
        return;
    }
    for (UInt32 index = 0; index < outputData->mNumberBuffers; ++index) {
        AudioBuffer *output = &outputData->mBuffers[index];
        if (output->mData != NULL && output->mDataByteSize > 0) {
            memset(output->mData, 0, output->mDataByteSize);
        }
    }
}

void DuckerDSPProcess(DuckerDSPState *state,
                      const AudioBufferList *inputData,
                      AudioBufferList *outputData) {
    if (state == NULL || inputData == NULL || outputData == NULL ||
        inputData->mNumberBuffers == 0 || outputData->mNumberBuffers == 0) {
        clearOutputs(outputData);
        return;
    }

    atomic_fetch_add_explicit(&state->callbackCount, 1, memory_order_relaxed);
    atomic_store_explicit(&state->inputBufferCount, inputData->mNumberBuffers,
                          memory_order_relaxed);
    atomic_store_explicit(&state->outputBufferCount, outputData->mNumberBuffers,
                          memory_order_relaxed);
    uint32_t inputBytes = 0;
    uint32_t outputBytes = 0;
    for (UInt32 index = 0; index < inputData->mNumberBuffers; ++index) {
        inputBytes += inputData->mBuffers[index].mDataByteSize;
    }
    for (UInt32 index = 0; index < outputData->mNumberBuffers; ++index) {
        outputBytes += outputData->mBuffers[index].mDataByteSize;
    }
    atomic_store_explicit(&state->inputByteCount, inputBytes, memory_order_relaxed);
    atomic_store_explicit(&state->outputByteCount, outputBytes, memory_order_relaxed);

    uint64_t inputSamples = 0;
    uint64_t nonZeroSamples = 0;
    const int needsSignalProbe = atomic_load_explicit(
        &state->nonZeroInputSampleCount, memory_order_relaxed) == 0;
    for (UInt32 index = 0; index < inputData->mNumberBuffers; ++index) {
        const AudioBuffer *input = &inputData->mBuffers[index];
        if (input->mData == NULL) {
            continue;
        }
        const Float32 *samples = (const Float32 *)input->mData;
        const uint32_t sampleCount =
            input->mDataByteSize / (uint32_t)sizeof(Float32);
        inputSamples += sampleCount;
        if (needsSignalProbe) {
            for (uint32_t sample = 0; sample < sampleCount; ++sample) {
                if (fabsf(samples[sample]) > 0.000001f) {
                    ++nonZeroSamples;
                }
            }
        }
    }
    atomic_fetch_add_explicit(&state->inputSampleCount, inputSamples,
                              memory_order_relaxed);
    atomic_fetch_add_explicit(&state->nonZeroInputSampleCount, nonZeroSamples,
                              memory_order_relaxed);

    if (atomic_load_explicit(&state->copyEnabled, memory_order_acquire) == 0) {
        clearOutputs(outputData);
        return;
    }

    const uint64_t requestedVersion = atomic_load_explicit(
        &state->requestVersion, memory_order_acquire);
    if (requestedVersion != state->appliedVersion) {
        state->activeTarget = atomic_load_explicit(
            &state->requestedTarget, memory_order_relaxed);
        state->remainingRampFrames = atomic_load_explicit(
            &state->requestedRampFrames, memory_order_relaxed);
        state->appliedVersion = requestedVersion;
    }

    uint32_t frames = frameCountForBuffer(&outputData->mBuffers[0]);
    const uint32_t inputFrames = frameCountForBuffer(&inputData->mBuffers[0]);
    if (inputFrames < frames) {
        frames = inputFrames;
    }

    // The ramp is geometric — a constant per-frame ratio — so the gain moves
    // at a constant rate in dB. A linear-amplitude ramp is perceptually
    // front-loaded: releasing 0.2 -> 1.0 covers +6 of its +14 dB in the first
    // quarter, then crawls. The ratio is recomputed from the remaining
    // distance each callback, so float drift self-corrects instead of
    // accumulating across a long release.
    const float startingGain = state->currentGain;
    float rampBaseGain = startingGain;
    float frameRatio = 1.0f;
    float bufferEndGain = startingGain;
    uint32_t rampedFrames = 0;
    if (state->remainingRampFrames == 0) {
        state->currentGain = state->activeTarget;
    } else if (frames > 0) {
        rampedFrames = frames < state->remainingRampFrames
            ? frames
            : state->remainingRampFrames;
        rampBaseGain = startingGain < kMinRampGain ? kMinRampGain : startingGain;
        const float rampTarget = state->activeTarget < kMinRampGain
            ? kMinRampGain
            : state->activeTarget;
        frameRatio = powf(rampTarget / rampBaseGain,
                          1.0f / (float)state->remainingRampFrames);
        bufferEndGain = rampBaseGain * powf(frameRatio, (float)rampedFrames);
    }

    for (UInt32 index = 0; index < outputData->mNumberBuffers; ++index) {
        AudioBuffer *output = &outputData->mBuffers[index];
        if (output->mData == NULL || output->mDataByteSize == 0) {
            continue;
        }
        if (index >= inputData->mNumberBuffers) {
            memset(output->mData, 0, output->mDataByteSize);
            continue;
        }

        const AudioBuffer *input = &inputData->mBuffers[index];
        if (input->mData == NULL ||
            input->mNumberChannels != output->mNumberChannels) {
            memset(output->mData, 0, output->mDataByteSize);
            continue;
        }

        const uint32_t copiedBytes = input->mDataByteSize < output->mDataByteSize
            ? input->mDataByteSize
            : output->mDataByteSize;
        memcpy(output->mData, input->mData, copiedBytes);
        if (copiedBytes < output->mDataByteSize) {
            memset((uint8_t *)output->mData + copiedBytes, 0,
                   output->mDataByteSize - copiedBytes);
        }

        Float32 *samples = (Float32 *)output->mData;
        const uint32_t sampleCount = copiedBytes / (uint32_t)sizeof(Float32);
        const uint32_t channels = output->mNumberChannels;
        float rampGain = rampBaseGain;
        uint32_t rampFrame = UINT32_MAX;
        for (uint32_t sample = 0; sample < sampleCount; ++sample) {
            const uint32_t frame = sample / channels;
            float gain = state->activeTarget;
            if (state->remainingRampFrames > 0 && frame < rampedFrames) {
                if (frame != rampFrame) {
                    rampGain *= frameRatio;
                    rampFrame = frame;
                }
                gain = rampGain;
            } else if (state->remainingRampFrames > rampedFrames) {
                gain = bufferEndGain;
            }
            samples[sample] *= gain;
        }
    }

    if (state->remainingRampFrames > 0) {
        state->currentGain = bufferEndGain;
        state->remainingRampFrames -= rampedFrames;
        if (state->remainingRampFrames == 0) {
            state->currentGain = state->activeTarget;
        }
    }
    atomic_store_explicit(&state->reportedCurrentGain, state->currentGain,
                          memory_order_relaxed);
}

OSStatus DuckerAudioIOProc(AudioObjectID device,
                           const AudioTimeStamp *now,
                           const AudioBufferList *inputData,
                           const AudioTimeStamp *inputTime,
                           AudioBufferList *outputData,
                           const AudioTimeStamp *outputTime,
                           void *clientData) {
    (void)device;
    (void)now;
    (void)inputTime;
    (void)outputTime;
    DuckerDSPProcess((DuckerDSPState *)clientData, inputData, outputData);
    return noErr;
}
