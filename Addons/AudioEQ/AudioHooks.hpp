#pragma once
#include "AudioDSP.hpp"
#include "AudioDiagnostics.hpp"
#import <Foundation/Foundation.h>

struct YTAEQStatistics {
    std::atomic<uint64_t> processedBlocks{0};
    std::atomic<uint64_t> processedFrames{0};
    std::atomic<uint64_t> unsupportedBlocks{0};
    std::atomic<uint64_t> concurrentBlocks{0};
    std::atomic<uint32_t> sampleRate{0};
    std::atomic<int32_t> decoderError{0};
    std::atomic<unsigned> backend{0}; // 0 waiting, 1 sample buffers, 2 RemoteIO
    // Only fixed-size lock-free atomics are written by audio callbacks. UI
    // formatting, route inspection and clipboard access stay on the main thread.
    std::atomic<uint64_t> lastFailure{0}; // stage + OSStatus, one coherent value
    std::atomic<uint64_t> receivedBuffers{0}, compressedBuffers{0}, pcmBuffers{0};
    std::atomic<uint64_t> bypassedBuffers{0}, inputExhaustions{0}, decoderResets{0};
    std::atomic<uint64_t> remoteStarts{0}, remoteCallbacks{0}, rebindingAttempts{0};
    std::atomic<uint64_t> chainedImages{0}, flushes{0};
    std::atomic<uint32_t> formatID{0}, formatFlags{0}, channels{0}, sourceRate{0};
    std::atomic<uint32_t> bitsPerChannel{0}, bytesPerFrame{0}, framesPerPacket{0};
    std::atomic<uint32_t> expectedFrames{0}, returnedFrames{0};
    std::atomic<uint32_t> packetCount{0}, consumedPackets{0}, requestedPackets{0};
    std::atomic<uint32_t> inputBytes{0}, cookieBytes{0};
    std::atomic<uint32_t> sourceSamples{0}, packetFrames{0};
    std::atomic<uint64_t> decoderContinuations{0};
    std::atomic<uint32_t> startupPadding{0}, queuedFrames{0};
    std::atomic<int32_t> primeStatus{0};
    std::atomic<bool> enqueueHookInstalled{false}, remoteHooksInstalled{false};
};
ytaeq::Mailbox &YTAEQConfigurationMailbox();
YTAEQStatistics &YTAEQAudioStatistics();
void YTAEQInstallAudioHooks();
