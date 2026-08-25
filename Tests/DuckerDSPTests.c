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

    DuckerDSPReset(state, 1.0f, 0.2f, 4);
    DuckerDSPProcess(state, &input, &output);
    assert(closeEnough(outputSamples[0], 0.8f));
    assert(closeEnough(outputSamples[2], 0.3f));
    assert(closeEnough(outputSamples[4], 0.4f));
    assert(closeEnough(outputSamples[6], 0.1f));
    assert(closeEnough(DuckerDSPCurrentGain(state), 0.2f));

    DuckerDSPSetTarget(state, 1.0f, 4);
    DuckerDSPProcess(state, &input, &output);
    assert(closeEnough(outputSamples[0], 0.4f));
    assert(closeEnough(outputSamples[2], 0.3f));
    assert(closeEnough(outputSamples[4], 0.8f));
    assert(closeEnough(outputSamples[6], 0.5f));
    assert(closeEnough(DuckerDSPCurrentGain(state), 1.0f));

    DuckerDSPDestroy(state);
    puts("DuckerDSP tests passed");
    return 0;
}
