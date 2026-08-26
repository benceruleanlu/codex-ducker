#include "DuckerDSP.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static int closeEnough(float lhs, float rhs) {
    return fabsf(lhs - rhs) < 0.0001f;
}

int main(void) {
    DuckerDSPState *state = DuckerDSPCreate();
    assert(state != NULL);

    float inputSamples[] = {1.0f, -1.0f, 0.5f, -0.5f,
                            1.0f, -1.0f, 0.5f, -0.5f};
    float outputSamples[8] = {0};
    AudioBufferList input = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 2,
            .mDataByteSize = sizeof(inputSamples),
            .mData = inputSamples,
        }},
    };
    AudioBufferList output = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 2,
            .mDataByteSize = sizeof(outputSamples),
            .mData = outputSamples,
        }},
    };

    DuckerDSPReset(state, 0.2f, 0.2f, 0);
    DuckerDSPSetCopyEnabled(state, 1);
    DuckerDSPResetTelemetry(state);
    DuckerDSPProcess(state, &input, &output);
    assert(closeEnough(outputSamples[0], 0.2f));
    assert(closeEnough(outputSamples[1], -0.2f));
    assert(closeEnough(outputSamples[2], 0.1f));
    DuckerDSPSnapshot snapshot = DuckerDSPGetSnapshot(state);
    assert(snapshot.callbackCount == 1);
    assert(snapshot.inputSampleCount == 8);
    assert(snapshot.nonZeroInputSampleCount == 8);
    assert(snapshot.inputBufferCount == 1);
    assert(snapshot.outputBufferCount == 1);
    assert(snapshot.copyEnabled == 1);

    DuckerDSPSetCopyEnabled(state, 0);
    DuckerDSPProcess(state, &input, &output);
    for (int index = 0; index < 8; ++index) {
        assert(closeEnough(outputSamples[index], 0.0f));
    }
    DuckerDSPSetCopyEnabled(state, 1);

    // The ramp is geometric (dB-linear): each frame multiplies the gain by a
    // constant ratio, here 0.2^(1/4) per frame for 1.0 -> 0.2 over 4 frames.
    DuckerDSPReset(state, 1.0f, 0.2f, 4);
    DuckerDSPProcess(state, &input, &output);
    const float down = powf(0.2f, 0.25f);
    assert(closeEnough(outputSamples[0], 1.0f * down));
    assert(closeEnough(outputSamples[2], 0.5f * down * down));
    assert(closeEnough(outputSamples[4], 1.0f * down * down * down));
    assert(closeEnough(outputSamples[6], 0.5f * 0.2f));
    assert(closeEnough(DuckerDSPCurrentGain(state), 0.2f));

    DuckerDSPSetTarget(state, 1.0f, 4);
    DuckerDSPProcess(state, &input, &output);
    const float up = powf(5.0f, 0.25f);
    assert(closeEnough(outputSamples[0], 1.0f * 0.2f * up));
    assert(closeEnough(outputSamples[2], 0.5f * 0.2f * up * up));
    assert(closeEnough(outputSamples[4], 1.0f * 0.2f * up * up * up));
    assert(closeEnough(outputSamples[6], 0.5f * 1.0f));
    assert(closeEnough(DuckerDSPCurrentGain(state), 1.0f));

    // Retargeting mid-ramp restarts from the current gain: the next frame may
    // move at most one ramp step away from it, never jump.
    DuckerDSPReset(state, 1.0f, 0.2f, 8);
    DuckerDSPProcess(state, &input, &output);
    const float midway = DuckerDSPCurrentGain(state);
    assert(midway < 1.0f && midway > 0.2f);
    DuckerDSPSetTarget(state, 1.0f, 8);
    DuckerDSPProcess(state, &input, &output);
    assert(outputSamples[0] >= midway);
    assert(outputSamples[0] <= midway * 1.3f);

    // A long ramp stays monotonic and lands exactly on the target despite
    // thousands of float multiplies (release is 12,000 frames at 48 kHz).
    DuckerDSPReset(state, 1.0f, 0.2f, 12000);
    float previous = 1.0f;
    for (int block = 0; block < 3000; ++block) {
        DuckerDSPProcess(state, &input, &output);
        const float gain = DuckerDSPCurrentGain(state);
        assert(gain <= previous + 0.0001f);
        previous = gain;
    }
    assert(closeEnough(DuckerDSPCurrentGain(state), 0.2f));

    // A zero start gain must not wedge the multiplicative ramp at zero, and a
    // zero target must not produce a non-finite ratio.
    DuckerDSPReset(state, 0.0f, 1.0f, 4);
    DuckerDSPProcess(state, &input, &output);
    assert(isfinite(outputSamples[0]));
    assert(closeEnough(DuckerDSPCurrentGain(state), 1.0f));
    DuckerDSPReset(state, 1.0f, 0.0f, 4);
    DuckerDSPProcess(state, &input, &output);
    assert(isfinite(outputSamples[0]));
    assert(closeEnough(DuckerDSPCurrentGain(state), 0.0f));

    DuckerDSPDestroy(state);
    puts("DuckerDSP tests passed");
    return 0;
}
