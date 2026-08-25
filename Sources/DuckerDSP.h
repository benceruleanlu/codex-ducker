#ifndef CODEX_DUCKER_DSP_H
#define CODEX_DUCKER_DSP_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

typedef struct DuckerDSPState DuckerDSPState;

typedef struct DuckerDSPSnapshot {
    uint64_t callbackCount;
    uint64_t inputSampleCount;
    uint64_t nonZeroInputSampleCount;
    uint32_t inputBufferCount;
    uint32_t outputBufferCount;
    uint32_t inputByteCount;
    uint32_t outputByteCount;
    uint32_t copyEnabled;
    float currentGain;
} DuckerDSPSnapshot;

DuckerDSPState * _Nullable DuckerDSPCreate(void);
void DuckerDSPDestroy(DuckerDSPState *state);

// Call only while the audio device is stopped.
void DuckerDSPReset(DuckerDSPState *state, float currentGain, float targetGain,
                    uint32_t rampFrames);

// Safe to call while the realtime callback is running.
void DuckerDSPSetTarget(DuckerDSPState *state, float targetGain,
                        uint32_t rampFrames);

void DuckerDSPSetCopyEnabled(DuckerDSPState *state, uint32_t enabled);
void DuckerDSPResetTelemetry(DuckerDSPState *state);
DuckerDSPSnapshot DuckerDSPGetSnapshot(const DuckerDSPState *state);

float DuckerDSPCurrentGain(const DuckerDSPState *state);

void DuckerDSPProcess(DuckerDSPState *state,
                      const AudioBufferList *inputData,
                      AudioBufferList *outputData);

OSStatus DuckerAudioIOProc(AudioObjectID device,
                           const AudioTimeStamp * _Nonnull now,
                           const AudioBufferList * _Nonnull inputData,
                           const AudioTimeStamp * _Nonnull inputTime,
                           AudioBufferList * _Nonnull outputData,
                           const AudioTimeStamp * _Nonnull outputTime,
                           void * _Nullable clientData);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
