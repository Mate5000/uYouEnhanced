#pragma once
#include "AudioDSP.hpp"
#import <Foundation/Foundation.h>

struct YTAEQStatistics {
    std::atomic<uint64_t> processedBlocks{0};
    std::atomic<uint64_t> processedFrames{0};
    std::atomic<uint64_t> unsupportedBlocks{0};
    std::atomic<uint64_t> concurrentBlocks{0};
    std::atomic<uint32_t> sampleRate{0};
    std::atomic<int32_t> decoderError{0};
    std::atomic<unsigned> backend{0}; // 0 waiting, 1 sample buffers, 2 RemoteIO
};
ytaeq::Mailbox &YTAEQConfigurationMailbox();
YTAEQStatistics &YTAEQAudioStatistics();
void YTAEQInstallAudioHooks();
