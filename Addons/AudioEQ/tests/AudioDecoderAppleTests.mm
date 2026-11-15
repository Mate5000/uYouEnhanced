// Uses the production adapter with Apple's real AudioConverter/CoreMedia.
// Hook installation is excluded; no YouTube app or Substrate is needed.
#define YTAEQ_DECODER_TEST 1
#include "../AudioHooks.mm"
#include <cstdio>
#include <cstdlib>
#include <fstream>

#define CHECK(condition) do { if (!(condition)) { \
    std::fprintf(stderr, "FAIL line %d: %s (stage=%s status=%d)\n", __LINE__, #condition, \
        ytaeq::failureStageName(ytaeq::failureStage(statistics.lastFailure.load())), statistics.decoderError.load()); \
    std::exit(1); } } while (0)

ytaeq::Mailbox &YTAEQConfigurationMailbox() { static ytaeq::Mailbox mailbox; return mailbox; }
struct Fixture { unsigned channels; std::vector<std::vector<uint8_t>> packets; };
static Fixture readFixture(const char *directory, unsigned channels) {
    std::ifstream file(std::string(directory) + "/tones-48k-" + std::to_string(channels) + "ch.opus-packets", std::ios::binary);
    CHECK(file.good());
    char magic[8]; file.read(magic, 8); CHECK(std::memcmp(magic, "YTEQOPUS", 8) == 0);
    const auto read32 = [&file]() { uint8_t p[4]; file.read(reinterpret_cast<char *>(p), 4); CHECK(file.good());
        return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; };
    CHECK(read32() == 48000); CHECK(read32() == channels);
    const uint32_t count = read32(); CHECK(count == 100);
    Fixture fixture{channels, {}};
    for (unsigned i = 0; i < count; ++i) {
        const unsigned size = read32(); CHECK(size > 0 && size <= 4000);
        fixture.packets.emplace_back(size);
        file.read(reinterpret_cast<char *>(fixture.packets.back().data()), size); CHECK(file.good());
    }
    return fixture;
}
static CMSampleBufferRef sample(const Fixture &fixture, unsigned first, CMTime pts) {
    // Match the phone report: 10 variable-frame Opus packets, no cookie,
    // 48 kHz, mFramesPerPacket=0, 960 frames described by each packet.
    AudioStreamBasicDescription asbd{};
    asbd.mFormatID = kAudioFormatOpus; asbd.mSampleRate = 48000; asbd.mChannelsPerFrame = fixture.channels;
    CMAudioFormatDescriptionRef format = nullptr;
    CHECK(CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr, 0, nullptr, nullptr, &format) == noErr);
    std::vector<uint8_t> bytes;
    AudioStreamPacketDescription packets[10]{};
    for (unsigned i = 0; i < 10; ++i) {
        const auto &packet = fixture.packets[(first + i) % fixture.packets.size()];
        packets[i] = {static_cast<SInt64>(bytes.size()), 960, static_cast<UInt32>(packet.size())};
        bytes.insert(bytes.end(), packet.begin(), packet.end());
    }
    CMBlockBufferRef block = nullptr;
    CHECK(CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes.size(), kCFAllocatorDefault,
        nullptr, 0, bytes.size(), 0, &block) == noErr);
    CHECK(CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, bytes.size()) == noErr);
    CMSampleBufferRef result = nullptr;
    CHECK(CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, format, 10, pts, packets, &result) == noErr);
    CHECK(CMTimeCompare(CMSampleBufferGetDuration(result), CMTimeMake(9600, 48000)) == 0);
    CFRelease(block); CFRelease(format);
    return result;
}
static void collect(CMSampleBufferRef buffer, std::vector<float> &output, unsigned channels) {
    CHECK(CMSampleBufferGetNumSamples(buffer) == 9600);
    AudioBufferList list{}; CMBlockBufferRef storage = nullptr;
    CHECK(CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, nullptr, &list, sizeof(list),
        kCFAllocatorDefault, kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &storage) == noErr);
    CHECK(list.mNumberBuffers == 1 && list.mBuffers[0].mDataByteSize == 9600 * channels * sizeof(float));
    const auto *pcm = static_cast<const float *>(list.mBuffers[0].mData);
    for (unsigned i = 0; i < 9600; ++i) { CHECK(std::isfinite(pcm[i * channels])); output.push_back(pcm[i * channels]); }
    CFRelease(storage);
}
static CMSampleBufferRef captured;
static void capture(__unused AVSampleBufferAudioRenderer *renderer, __unused SEL selector, CMSampleBufferRef buffer) {
    if (captured) CFRelease(captured);
    captured = (CMSampleBufferRef)CFRetain(buffer);
}
static void flush(__unused AVSampleBufferAudioRenderer *renderer, __unused SEL selector) {}
static std::vector<float> run(const Fixture &fixture, bool wet) {
    ytaeq::Configuration configuration;
    configuration.enabled = wet; configuration.bassEnabled = wet; configuration.bassGain = 12;
    YTAEQConfigurationMailbox().publish(configuration);
    YTAEQSampleState *state = [YTAEQSampleState new];
    state->stream.update(48000);
    const uint64_t resets = statistics.decoderResets.load();
    std::vector<float> audio;
    for (unsigned i = 0; i < 10; ++i) {
        CMSampleBufferRef source = sample(fixture, i * 10, CMTimeMake(i * 9600, 48000));
        CMSampleBufferRef output = processSample(state, source);
        CHECK(output && state->decoder);
        CHECK(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(output), CMSampleBufferGetPresentationTimeStamp(source)) == 0);
        CHECK(CMTimeCompare(CMSampleBufferGetDuration(output), CMSampleBufferGetDuration(source)) == 0);
        collect(output, audio, fixture.channels);
        CHECK(statistics.decoderResets.load() == resets);
        CHECK(state->decoded.startupPadding() <= 960);
        CFRelease(output); CFRelease(source);
    }
    CHECK(audio.size() == 96000);
    std::printf("Apple Opus %uch %s: startup=%u frames, last decoded=%u, resets=0\n", fixture.channels,
        wet ? "bass" : "dry", state->decoded.startupPadding(), statistics.returnedFrames.load());

    // Run the actual enqueue decision during disable/re-enable. Once decoding,
    // keep dry PCM flowing so toggling does not repeatedly re-prime the codec.
    AVSampleBufferAudioRenderer *renderer = (AVSampleBufferAudioRenderer *)[NSObject new];
    objc_setAssociatedObject(renderer, &sampleStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    originalEnqueue = capture; originalFlush = flush;
    AudioConverterRef decoder = state->decoder;
    configuration.bassEnabled = true;
    for (unsigned i = 10; i < 14; ++i) {
        configuration.enabled = i >= 12;
        YTAEQConfigurationMailbox().publish(configuration);
        CMSampleBufferRef source = sample(fixture, i * 10, CMTimeMake(i * 9600, 48000));
        enqueueSample(renderer, @selector(enqueueSampleBuffer:), source);
        CHECK(captured != source && state->decoder == decoder);
        CHECK(CMSampleBufferGetNumSamples(captured) == 9600);
        CFRelease(source);
    }
    // Seek immediately to a different source timestamp, then explicitly flush.
    CMSampleBufferRef source = sample(fixture, 0, CMTimeMake(100, 1));
    enqueueSample(renderer, @selector(enqueueSampleBuffer:), source);
    CHECK(captured != source && statistics.decoderResets.load() == resets + 1);
    CHECK(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(captured), CMTimeMake(100, 1)) == 0);
    CFRelease(source);
    flushSample(renderer, @selector(flush));
    CHECK(!state->decoder && !state->decoded.started());
    source = sample(fixture, 0, CMTimeMake(101, 1));
    enqueueSample(renderer, @selector(enqueueSampleBuffer:), source);
    CHECK(captured != source && state->decoder);
    CFRelease(source);
    CFRelease(captured); captured = nullptr;
    return audio;
}
static double amplitude(const std::vector<float> &audio, double hz) {
    double real = 0, imag = 0;
    for (size_t i = 24000; i < audio.size(); ++i) {
        const double phase = 2 * M_PI * hz * double(i) / 48000;
        real += audio[i] * std::cos(phase); imag += audio[i] * std::sin(phase);
    }
    return std::hypot(real, imag);
}
int main(int argc, char **argv) { @autoreleasepool {
    CHECK(argc == 2);
    for (unsigned channels : {1, 2}) {
        const auto fixture = readFixture(argv[1], channels);
        const auto dry = run(fixture, false), wet = run(fixture, true);
        const double boost = 20 * std::log10(amplitude(wet, 63) / amplitude(wet, 1000) /
            (amplitude(dry, 63) / amplitude(dry, 1000)));
        ytaeq::Configuration c; c.enabled = c.bassEnabled = true; c.bassGain = 12;
        const double expected = ytaeq::Engine::responseDB(c, 48000, 63) - ytaeq::Engine::responseDB(c, 48000, 1000);
        std::printf("Measured bass change: %.3f dB; expected %.3f dB\n", boost, expected);
        CHECK(std::abs(boost - expected) < 0.3 && boost > 3);
        for (float value : wet) CHECK(std::abs(value) <= ytaeq::OutputCeiling + 1e-6);
    }
    CHECK(statistics.processedFrames.load() > 0 && statistics.unsupportedBlocks.load() == 0);
    std::puts("PASS: real Apple Opus decoding, measured bass effect, continuous PTS/duration, toggles, seek and flush");
} }
