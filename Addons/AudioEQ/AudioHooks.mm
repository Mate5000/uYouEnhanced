#import "AudioHooks.hpp"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "Vendor/fishhook.h"
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

static YTAEQStatistics statistics;
static_assert(std::atomic<uint64_t>::is_always_lock_free, "Audio statistics must be lock free");
static std::atomic<unsigned> sampleRenderers{0};
YTAEQStatistics &YTAEQAudioStatistics() { return statistics; }

namespace {
using namespace ytaeq;
struct Stream {
    Engine engine;
    Configuration configuration;
    uint32_t revision = 0;
    double rate = 0;
    std::atomic_flag busy = ATOMIC_FLAG_INIT;
    bool effect = false;
    void update(double sampleRate) {
        const bool changed = YTAEQConfigurationMailbox().read(configuration, revision);
        if (rate != sampleRate) {
            rate = sampleRate; engine.reset(rate); engine.setConfiguration(configuration, true);
        } else if (changed) engine.setConfiguration(configuration);
        effect = !engine.isBypassed();
    }
};
struct Guard {
    Stream &stream;
    bool acquired;
    explicit Guard(Stream &s) : stream(s), acquired(!s.busy.test_and_set(std::memory_order_acquire)) {
        if (!acquired) statistics.concurrentBlocks.fetch_add(1, std::memory_order_relaxed);
    }
    ~Guard() { if (acquired) stream.busy.clear(std::memory_order_release); }
};
static void unsupported(OSStatus error = kAudioFormatUnsupportedDataFormatError) {
    statistics.decoderError.store(error, std::memory_order_relaxed);
    statistics.unsupportedBlocks.fetch_add(1, std::memory_order_relaxed);
}
static void processed(Stream &stream, std::size_t frames, unsigned backend) {
    if (!stream.effect) return;
    statistics.decoderError.store(0, std::memory_order_relaxed);
    statistics.backend.store(backend, std::memory_order_relaxed);
    statistics.sampleRate.store(static_cast<uint32_t>(stream.rate), std::memory_order_relaxed);
    statistics.processedFrames.fetch_add(frames, std::memory_order_relaxed);
    statistics.processedBlocks.fetch_add(1, std::memory_order_relaxed);
}
static bool pcmFormat(const AudioStreamBasicDescription &asbd, PCMFormat &format) {
    if (asbd.mFormatID != kAudioFormatLinearPCM || asbd.mChannelsPerFrame < 1 || asbd.mChannelsPerFrame > 2 ||
        !std::isfinite(asbd.mSampleRate) || asbd.mSampleRate < 8000 || asbd.mSampleRate > 192000 ||
        (asbd.mFormatFlags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsAlignedHigh))) return false;
    format = {asbd.mSampleRate, asbd.mChannelsPerFrame, SampleType::Float32, !(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved)};
    if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) {
        if (asbd.mBitsPerChannel != 32) return false;
    } else if (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        UInt32 fraction = (asbd.mFormatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;
        if (asbd.mBitsPerChannel == 16 && fraction == 0) format.type = SampleType::Signed16;
        else if (asbd.mBitsPerChannel == 32 && fraction == 0) format.type = SampleType::Signed32;
        else if (asbd.mBitsPerChannel == 32 && fraction == 24) format.type = SampleType::Fixed824;
        else return false;
    } else return false;
    const unsigned bytes = asbd.mBitsPerChannel / 8;
    return asbd.mBytesPerFrame == bytes * (format.interleaved ? format.channels : 1);
}
static bool processList(Stream &stream, const PCMFormat &format, AudioBufferList *list, UInt32 frames) {
    if (!list || list->mNumberBuffers > 2) return false;
    PCMBuffer buffers[2] = {};
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i)
        buffers[i] = {list->mBuffers[i].mData, list->mBuffers[i].mDataByteSize, list->mBuffers[i].mNumberChannels};
    return processPCM(stream.engine, format, buffers, list->mNumberBuffers, frames);
}

// RemoteIO fallback. The notify receives its own context, never a map lookup or
// lock on the real-time thread. One atomic word publishes a complete PCM format.
struct Output {
    Stream stream;
    std::atomic<uint64_t> format{0};
    std::atomic<uint32_t> formatEpoch{1};
    std::atomic<uint32_t> publishedEpoch{0};
    uint64_t lastFormat = 0;
    Float64 expectedTime = 0;
    bool hasTime = false;
};
struct OutputRegistry {
    std::mutex mutex;
    std::unordered_map<AudioUnit, std::unique_ptr<Output>> units;
};
static OutputRegistry &outputRegistry() {
    static OutputRegistry registry;
    return registry;
}
static OSStatus (*originalStart)(AudioUnit);
static OSStatus (*originalUninitialize)(AudioUnit);
static OSStatus (*originalDispose)(AudioComponentInstance);
static char applicationPath[PATH_MAX];

static void readOutputFormat(AudioUnit unit, Output &output) {
    const uint32_t epoch = output.formatEpoch.load(std::memory_order_acquire);
    AudioStreamBasicDescription asbd{};
    UInt32 size = sizeof(asbd);
    PCMFormat format;
    uint64_t word = 0;
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, &size) == noErr && pcmFormat(asbd, format)) {
        word = static_cast<uint64_t>(std::llround(format.rate)) | (uint64_t(format.channels) << 20) |
               (uint64_t(format.type) << 24) | (uint64_t(format.interleaved) << 28);
    }
    output.format.store(word, std::memory_order_release);
    output.publishedEpoch.store(epoch, std::memory_order_release);
}
static void formatChanged(void *context, __unused AudioUnit unit, __unused AudioUnitPropertyID property,
                          __unused AudioUnitScope scope, __unused AudioUnitElement element) {
    static_cast<Output *>(context)->formatEpoch.fetch_add(1, std::memory_order_release);
}
static OSStatus renderOutput(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                             UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if (!flags || !(*flags & kAudioUnitRenderAction_PostRender) || (*flags & kAudioUnitRenderAction_PostRenderError) ||
        bus != 0 || !data || frames == 0 || sampleRenderers.load(std::memory_order_relaxed)) return noErr;
    Output &output = *static_cast<Output *>(context);
    if (output.formatEpoch.load(std::memory_order_acquire) != output.publishedEpoch.load(std::memory_order_acquire)) return noErr;
    Guard guard(output.stream);
    if (!guard.acquired) return noErr;
    const uint64_t word = output.format.load(std::memory_order_acquire);
    if (!word) { unsupported(); return noErr; }
    PCMFormat format{double(word & 0xfffff), unsigned((word >> 20) & 3), SampleType((word >> 24) & 7), bool((word >> 28) & 1)};
    output.stream.update(format.rate);
    if (word != output.lastFormat) { output.stream.engine.clearHistory(); output.hasTime = false; output.lastFormat = word; }
    if (timestamp && (timestamp->mFlags & kAudioTimeStampSampleTimeValid)) {
        if (output.hasTime && std::abs(timestamp->mSampleTime - output.expectedTime) > 1) output.stream.engine.clearHistory();
        output.expectedTime = timestamp->mSampleTime + frames; output.hasTime = true;
    }
    if (output.stream.engine.isBypassed()) return noErr;
    if (*flags & kAudioUnitRenderAction_OutputIsSilence) {
        // A silent buffer need not contain initialized samples. Clear it only
        // after validating all pointers and sizes.
        PCMBuffer buffers[2]{};
        if (data->mNumberBuffers > 2) { unsupported(); return noErr; }
        for (UInt32 i = 0; i < data->mNumberBuffers; ++i)
            buffers[i] = {data->mBuffers[i].mData, data->mBuffers[i].mDataByteSize, data->mBuffers[i].mNumberChannels};
        if (!validPCM(format, buffers, data->mNumberBuffers, frames)) { unsupported(); return noErr; }
        for (UInt32 i = 0; i < data->mNumberBuffers; ++i) std::memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
    }
    if (!processList(output.stream, format, data, frames)) { unsupported(); return noErr; }
    // Filters can have a short tail even when the source is silent.
    *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    processed(output.stream, frames, 2);
    return noErr;
}
static bool isRemoteIO(AudioUnit unit) {
    AudioComponentDescription description{};
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    return component && AudioComponentGetDescription(component, &description) == noErr &&
           description.componentType == kAudioUnitType_Output && description.componentSubType == kAudioUnitSubType_RemoteIO;
}
static OSStatus startOutput(AudioUnit unit) {
    try { if (isRemoteIO(unit)) {
        auto &registry = outputRegistry();
        std::lock_guard<std::mutex> lock(registry.mutex);
        auto &outputs = registry.units;
        if (outputs.find(unit) == outputs.end()) {
            auto output = std::make_unique<Output>();
            readOutputFormat(unit, *output);
            // Allocate the map node before exposing the context to Core Audio.
            // An allocation failure must never leave a dangling render notify.
            auto inserted = outputs.emplace(unit, std::move(output));
            Output *context = inserted.first->second.get();
            if (AudioUnitAddRenderNotify(unit, renderOutput, context) == noErr) {
                AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat, formatChanged, context);
            } else {
                outputs.erase(inserted.first);
            }
        } else readOutputFormat(unit, *outputs[unit]);
    } } catch (const std::bad_alloc &) { unsupported(kAudio_MemFullError); }
    return originalStart(unit);
}
static std::unique_ptr<Output> detachOutput(AudioUnit unit) {
    auto &registry = outputRegistry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    auto &outputs = registry.units;
    auto found = outputs.find(unit);
    if (found == outputs.end()) return nullptr;
    auto output = std::move(found->second);
    outputs.erase(found);
    AudioUnitRemoveRenderNotify(unit, renderOutput, output.get());
    AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_StreamFormat, formatChanged, output.get());
    return output;
}
static OSStatus uninitializeOutput(AudioUnit unit) {
    // Keep the registered context alive until Core Audio finishes rendering.
    // A failed uninitialize must leave the live unit's context intact.
    const OSStatus result = originalUninitialize(unit);
    if (result == noErr) { auto context = detachOutput(unit); }
    return result;
}
static OSStatus disposeOutput(AudioComponentInstance unit) {
    if (isRemoteIO(unit)) AudioOutputUnitStop(unit);
    auto context = detachOutput(unit);
    return originalDispose(unit);
}
static void bindApplicationImage(const struct mach_header *header, intptr_t slide) {
    Dl_info info{};
    if (!dladdr(header, &info) || !info.dli_fname) return;
    const size_t prefix = std::strlen(applicationPath);
    const bool insideApplication = prefix && std::strncmp(info.dli_fname, applicationPath, prefix) == 0 && info.dli_fname[prefix] == '/';
    if (header->filetype != MH_EXECUTE && !insideApplication) return;
    if (std::strstr(info.dli_fname, "YTAudioEQ.dylib")) return;
    // Rebind imported data pointers in the app and its embedded frameworks.
    // Do not patch signed executable code or images in the system shared cache.
    struct rebinding bindings[] = {
        {"AudioOutputUnitStart", reinterpret_cast<void *>(&startOutput), nullptr},
        {"AudioUnitUninitialize", reinterpret_cast<void *>(&uninitializeOutput), nullptr},
        {"AudioComponentInstanceDispose", reinterpret_cast<void *>(&disposeOutput), nullptr}
    };
    rebind_symbols_image(const_cast<struct mach_header *>(header), slide, bindings, sizeof(bindings) / sizeof(bindings[0]));
}
} // namespace

// AVSampleBufferAudioRenderer feeds are serialized non-real-time producer
// queues. Copies and codec setup happen here, never in the RemoteIO callback.
@interface YTAEQSampleState : NSObject {
@public
    Stream stream;
    AudioConverterRef decoder;
    CMFormatDescriptionRef sourceFormat;
    CMTime expectedTime;
    std::vector<float> decoded;
    std::vector<uint8_t> copied;
    std::vector<AudioStreamPacketDescription> packetDescriptions;
    std::atomic<bool> resetRequested;
}
@end
@implementation YTAEQSampleState
- (instancetype)init {
    self = [super init];
    if (self) { resetRequested.store(false); sampleRenderers.fetch_add(1); expectedTime = kCMTimeInvalid; }
    return self;
}
- (void)dealloc {
    if (decoder) AudioConverterDispose(decoder);
    if (sourceFormat) CFRelease(sourceFormat);
    sampleRenderers.fetch_sub(1);
}
@end

namespace {
static char sampleStateKey;
static void (*originalEnqueue)(AVSampleBufferAudioRenderer *, SEL, CMSampleBufferRef);
static void (*originalFlush)(AVSampleBufferAudioRenderer *, SEL);
static void (*originalTimedFlush)(AVSampleBufferAudioRenderer *, SEL, CMTime, void (^)(BOOL));

static void resetDecoder(YTAEQSampleState *state) {
    if (state->decoder) { AudioConverterDispose(state->decoder); state->decoder = nullptr; }
    if (state->sourceFormat) { CFRelease(state->sourceFormat); state->sourceFormat = nullptr; }
    state->expectedTime = kCMTimeInvalid;
}
static void copyAttachments(CMSampleBufferRef source, CMSampleBufferRef destination) {
    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, source, kCMAttachmentMode_ShouldPropagate);
    if (attachments) { CMSetAttachments(destination, attachments, kCMAttachmentMode_ShouldPropagate); CFRelease(attachments); }
    CFArrayRef from = CMSampleBufferGetSampleAttachmentsArray(source, false);
    CFArrayRef to = CMSampleBufferGetSampleAttachmentsArray(destination, true);
    // Per-sample attachments have a different cardinality for compressed data;
    // only transfer them when the sample layouts agree.
    if (from && to && CFArrayGetCount(from) == CFArrayGetCount(to))
        for (CFIndex i = 0; i < CFArrayGetCount(from); ++i)
            CFDictionaryApplyFunction((CFDictionaryRef)CFArrayGetValueAtIndex(from, i), [](const void *key, const void *value, void *context) {
                CFDictionarySetValue((CFMutableDictionaryRef)context, key, value);
            }, (void *)CFArrayGetValueAtIndex(to, i));
}
static CMSampleBufferRef makePCM(CMSampleBufferRef source, CMAudioFormatDescriptionRef description, AudioBufferList *list, UInt32 frames) {
    const auto *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if (!asbd || !CMTIME_IS_NUMERIC(CMSampleBufferGetPresentationTimeStamp(source))) return nullptr;
    CMSampleTimingInfo timing{CMTimeMake(1, static_cast<int32_t>(std::llround(asbd->mSampleRate))),
                              CMSampleBufferGetPresentationTimeStamp(source), CMSampleBufferGetDecodeTimeStamp(source)};
    CMSampleBufferRef result = nullptr;
    OSStatus status = CMSampleBufferCreate(kCFAllocatorDefault, nullptr, false, nullptr, nullptr, description, frames, 1, &timing, 0, nullptr, &result);
    if (status == noErr) status = CMSampleBufferSetDataBufferFromAudioBufferList(result, kCFAllocatorDefault, kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, list);
    if (status == noErr) status = CMSampleBufferSetDataReady(result);
    if (status != noErr) { if (result) CFRelease(result); return nullptr; }
    copyAttachments(source, result);
    return result;
}
struct PacketInput {
    const char *data;
    UInt32 bytes, packets, channels, bytesPerPacket;
    AudioStreamPacketDescription *descriptions;
    UInt32 cursor = 0;
};
static constexpr OSStatus NeedInput = 'yteq';
static OSStatus supplyPackets(__unused AudioConverterRef converter, UInt32 *count, AudioBufferList *data,
                              AudioStreamPacketDescription **descriptions, void *context) {
    auto &input = *static_cast<PacketInput *>(context);
    if (input.cursor == input.packets) { *count = 0; return NeedInput; }
    *count = std::min(*count, input.packets - input.cursor);
    if (*count == 0) return NeedInput;
    const UInt32 first = input.cursor, last = first + *count - 1;
    const UInt32 offset = input.descriptions ? static_cast<UInt32>(input.descriptions[first].mStartOffset) : first * input.bytesPerPacket;
    const UInt32 bytes = input.descriptions ? static_cast<UInt32>(input.descriptions[last].mStartOffset) + input.descriptions[last].mDataByteSize - offset : *count * input.bytesPerPacket;
    data->mNumberBuffers = 1;
    data->mBuffers[0] = {input.channels, bytes, const_cast<char *>(input.data + offset)};
    if (input.descriptions) for (UInt32 i = first; i <= last; ++i) input.descriptions[i].mStartOffset -= offset;
    if (descriptions) *descriptions = input.descriptions ? input.descriptions + first : nullptr;
    input.cursor += *count;
    return noErr;
}
static CMSampleBufferRef decodeAndProcess(YTAEQSampleState *state, CMSampleBufferRef source,
                                         CMAudioFormatDescriptionRef description, const AudioStreamBasicDescription &asbd) {
    // System codec support is checked at runtime. Never reinterpret compressed
    // bytes as PCM, and never replace audio with a partially decoded packet.
    if (asbd.mChannelsPerFrame < 1 || asbd.mChannelsPerFrame > 2 || asbd.mSampleRate < 8000 || asbd.mSampleRate > 192000) return nullptr;
    const CMTime duration = CMSampleBufferGetDuration(source);
    if (!CMTIME_IS_NUMERIC(duration)) return nullptr;
    const double estimate = CMTimeGetSeconds(duration) * asbd.mSampleRate;
    if (!std::isfinite(estimate) || estimate < 1 || estimate > 262144) return nullptr;
    const UInt32 expectedFrames = static_cast<UInt32>(std::llround(estimate));
    AudioStreamBasicDescription output{};
    output.mSampleRate = asbd.mSampleRate; output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    output.mBitsPerChannel = 32; output.mChannelsPerFrame = asbd.mChannelsPerFrame;
    output.mFramesPerPacket = 1; output.mBytesPerFrame = output.mBytesPerPacket = output.mChannelsPerFrame * sizeof(float);
    if (!state->sourceFormat || !CMFormatDescriptionEqual(state->sourceFormat, description)) {
        resetDecoder(state);
        OSStatus status = AudioConverterNew(&asbd, &output, &state->decoder);
        if (status != noErr) { statistics.decoderError.store(status); return nullptr; }
        size_t cookieSize = 0;
        const void *cookie = CMAudioFormatDescriptionGetMagicCookie(description, &cookieSize);
        if (cookie && cookieSize) {
            status = AudioConverterSetProperty(state->decoder, kAudioConverterDecompressionMagicCookie, static_cast<UInt32>(cookieSize), cookie);
            if (status != noErr) { statistics.decoderError.store(status); resetDecoder(state); return nullptr; }
        }
        UInt32 primeMethod = kConverterPrimeMethod_None;
        AudioConverterSetProperty(state->decoder, kAudioConverterPrimeMethod, sizeof(primeMethod), &primeMethod);
        state->sourceFormat = (CMFormatDescriptionRef)CFRetain(description);
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(source);
    if (!block) return nullptr;
    CMBlockBufferRef contiguous = nullptr;
    OSStatus status = CMBlockBufferCreateContiguous(kCFAllocatorDefault, block, kCFAllocatorDefault, nullptr, 0, 0, 0, &contiguous);
    if (status != noErr) return nullptr;
    char *bytes = nullptr;
    size_t length = 0;
    status = CMBlockBufferGetDataPointer(contiguous, 0, nullptr, &length, &bytes);
    const AudioStreamPacketDescription *descriptions = nullptr;
    size_t descriptionBytes = 0;
    OSStatus packetStatus = CMSampleBufferGetAudioStreamPacketDescriptionsPtr(source, &descriptions, &descriptionBytes);
    UInt32 packets = 0;
    if (packetStatus == noErr && descriptionBytes && descriptionBytes % sizeof(AudioStreamPacketDescription) == 0)
        packets = static_cast<UInt32>(descriptionBytes / sizeof(AudioStreamPacketDescription));
    else if (asbd.mBytesPerPacket && length % asbd.mBytesPerPacket == 0) packets = static_cast<UInt32>(length / asbd.mBytesPerPacket);
    if (status != noErr || !packets || packets > 8192 || length > 4194304) { CFRelease(contiguous); return nullptr; }
    uint64_t previousEnd = 0;
    for (UInt32 i = 0; descriptions && i < packets; ++i) {
        if (descriptions[i].mStartOffset < 0 || uint64_t(descriptions[i].mStartOffset) < previousEnd ||
            uint64_t(descriptions[i].mStartOffset) + descriptions[i].mDataByteSize > length) { CFRelease(contiguous); return nullptr; }
        previousEnd = uint64_t(descriptions[i].mStartOffset) + descriptions[i].mDataByteSize;
    }
    state->decoded.resize((expectedFrames + 4096) * output.mChannelsPerFrame);
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0] = {output.mChannelsPerFrame, static_cast<UInt32>(state->decoded.size() * sizeof(float)), state->decoded.data()};
    state->packetDescriptions.clear();
    if (descriptions) state->packetDescriptions.assign(descriptions, descriptions + packets);
    PacketInput input{bytes, static_cast<UInt32>(length), packets, asbd.mChannelsPerFrame, asbd.mBytesPerPacket,
        descriptions ? state->packetDescriptions.data() : nullptr, 0};
    // Ask for precisely this buffer's duration. Requesting spare capacity would
    // make the converter ask for the next packet before it has been enqueued.
    UInt32 frames = expectedFrames;
    status = AudioConverterFillComplexBuffer(state->decoder, supplyPackets, &input, &frames, &list, nullptr);
    CFRelease(contiguous);
    if ((status != noErr && status != NeedInput) || input.cursor != packets || frames != expectedFrames) {
        statistics.decoderError.store(status != noErr ? status : kAudioConverterErr_InvalidOutputSize);
        // The original packet goes to Apple's renderer; discard our decoder's
        // consumed state so it cannot emit that packet a second time later.
        resetDecoder(state); return nullptr;
    }
    list.mBuffers[0].mDataByteSize = frames * output.mBytesPerFrame;
    PCMFormat format;
    if (!pcmFormat(output, format)) return nullptr;
    state->stream.update(format.rate);
    if (!processList(state->stream, format, &list, frames)) return nullptr;
    CMAudioFormatDescriptionRef decodedDescription = nullptr;
    status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &output, 0, nullptr, 0, nullptr, nullptr, &decodedDescription);
    CMSampleBufferRef result = status == noErr ? makePCM(source, decodedDescription, &list, frames) : nullptr;
    if (decodedDescription) CFRelease(decodedDescription);
    if (result) processed(state->stream, frames, 1);
    return result;
}
static CMSampleBufferRef processSample(YTAEQSampleState *state, CMSampleBufferRef source) {
    if (!CMSampleBufferDataIsReady(source)) return nullptr;
    CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(source);
    if (!description || CMFormatDescriptionGetMediaType(description) != kCMMediaType_Audio) return nullptr;
    const auto *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if (!asbd) return nullptr;
    const CMTime pts = CMSampleBufferGetPresentationTimeStamp(source);
    const bool discontinuity = CMTIME_IS_NUMERIC(state->expectedTime) && CMTIME_IS_NUMERIC(pts) &&
        std::abs(CMTimeGetSeconds(CMTimeSubtract(pts, state->expectedTime))) > 0.002;
    if (discontinuity) { resetDecoder(state); state->stream.engine.clearHistory(); }
    state->expectedTime = CMTimeAdd(pts, CMSampleBufferGetDuration(source));
    if (asbd->mFormatID != kAudioFormatLinearPCM) return decodeAndProcess(state, source, description, *asbd);
    PCMFormat format;
    if (!pcmFormat(*asbd, format)) return nullptr;
    CMItemCount count = CMSampleBufferGetNumSamples(source);
    if (count <= 0 || count > 262144) return nullptr;
    const UInt32 frames = static_cast<UInt32>(count);
    struct { UInt32 count; AudioBuffer buffers[2]; } storage{};
    auto *list = reinterpret_cast<AudioBufferList *>(&storage);
    CMBlockBufferRef retained = nullptr;
    size_t needed = 0;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(source, &needed, list, sizeof(storage), kCFAllocatorDefault, kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &retained);
    if (status != noErr || list->mNumberBuffers > 2) { if (retained) CFRelease(retained); return nullptr; }
    PCMBuffer views[2]{};
    size_t total = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        views[i] = {list->mBuffers[i].mData, list->mBuffers[i].mDataByteSize, list->mBuffers[i].mNumberChannels};
        total += list->mBuffers[i].mDataByteSize;
    }
    if (!validPCM(format, views, list->mNumberBuffers, frames) || total > 4194304) { if (retained) CFRelease(retained); return nullptr; }
    state->copied.resize(total);
    size_t offset = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        std::memcpy(state->copied.data() + offset, list->mBuffers[i].mData, list->mBuffers[i].mDataByteSize);
        list->mBuffers[i].mData = state->copied.data() + offset;
        offset += list->mBuffers[i].mDataByteSize;
    }
    if (retained) CFRelease(retained);
    state->stream.update(format.rate);
    if (!processList(state->stream, format, list, frames)) return nullptr;
    CMSampleBufferRef result = makePCM(source, description, list, frames);
    if (result) processed(state->stream, frames, 1);
    return result;
}
static YTAEQSampleState *sampleState(AVSampleBufferAudioRenderer *renderer) {
    YTAEQSampleState *state = objc_getAssociatedObject(renderer, &sampleStateKey);
    if (!state) {
        @synchronized(renderer) {
            state = objc_getAssociatedObject(renderer, &sampleStateKey);
            if (!state) { state = [YTAEQSampleState new]; objc_setAssociatedObject(renderer, &sampleStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        }
    }
    return state;
}
static void enqueueSample(AVSampleBufferAudioRenderer *renderer, SEL selector, CMSampleBufferRef source) {
    if (!source) { originalEnqueue(renderer, selector, source); return; }
    YTAEQSampleState *state = sampleState(renderer);
    Guard guard(state->stream);
    if (!guard.acquired) { state->resetRequested.store(true); originalEnqueue(renderer, selector, source); return; }
    if (state->resetRequested.exchange(false)) { resetDecoder(state); state->stream.engine.clearHistory(); }
    // Read configuration even while disabled so an existing wet stream fades out.
    state->stream.update(state->stream.rate > 0 ? state->stream.rate : 48000);
    if (state->stream.engine.isBypassed()) {
        if (state->decoder) resetDecoder(state);
        state->expectedTime = kCMTimeInvalid;
        originalEnqueue(renderer, selector, source); return;
    }
    CMSampleBufferRef result = nullptr;
    try { result = processSample(state, source); }
    catch (const std::bad_alloc &) { resetDecoder(state); statistics.decoderError.store(kAudio_MemFullError); }
    if (!result) unsupported(statistics.decoderError.load() ?: kAudioFormatUnsupportedDataFormatError);
    originalEnqueue(renderer, selector, result ?: source);
    if (result) CFRelease(result);
}
static void flushSample(AVSampleBufferAudioRenderer *renderer, SEL selector) {
    YTAEQSampleState *state = objc_getAssociatedObject(renderer, &sampleStateKey);
    originalFlush(renderer, selector);
    if (state) {
        state->resetRequested.store(true);
        Guard guard(state->stream);
        if (guard.acquired) { resetDecoder(state); state->stream.engine.clearHistory(); state->resetRequested.store(false); }
    }
}
static void flushSampleAtTime(AVSampleBufferAudioRenderer *renderer, SEL selector, CMTime time, void (^completion)(BOOL)) {
    originalTimedFlush(renderer, selector, time, ^(BOOL flushed) {
        YTAEQSampleState *state = objc_getAssociatedObject(renderer, &sampleStateKey);
        if (flushed && state) {
            state->resetRequested.store(true);
            Guard guard(state->stream);
            if (guard.acquired) { resetDecoder(state); state->stream.engine.clearHistory(); state->resetRequested.store(false); }
        }
        if (completion) completion(flushed);
    });
}
} // namespace

void YTAEQInstallAudioHooks() {
    (void)outputRegistry();
    originalStart = reinterpret_cast<decltype(originalStart)>(dlsym(RTLD_DEFAULT, "AudioOutputUnitStart"));
    originalUninitialize = reinterpret_cast<decltype(originalUninitialize)>(dlsym(RTLD_DEFAULT, "AudioUnitUninitialize"));
    originalDispose = reinterpret_cast<decltype(originalDispose)>(dlsym(RTLD_DEFAULT, "AudioComponentInstanceDispose"));
    strlcpy(applicationPath, NSBundle.mainBundle.bundlePath.fileSystemRepresentation, sizeof(applicationPath));
    if (originalStart && originalUninitialize && originalDispose) _dyld_register_func_for_add_image(bindApplicationImage);
    Class renderer = NSClassFromString(@"AVSampleBufferAudioRenderer");
    if (class_getInstanceMethod(renderer, @selector(enqueueSampleBuffer:)))
        MSHookMessageEx(renderer, @selector(enqueueSampleBuffer:), reinterpret_cast<IMP>(&enqueueSample), reinterpret_cast<IMP *>(&originalEnqueue));
    if (class_getInstanceMethod(renderer, @selector(flush)))
        MSHookMessageEx(renderer, @selector(flush), reinterpret_cast<IMP>(&flushSample), reinterpret_cast<IMP *>(&originalFlush));
    SEL timedFlush = @selector(flushFromSourceTime:completionHandler:);
    if (class_getInstanceMethod(renderer, timedFlush))
        MSHookMessageEx(renderer, timedFlush, reinterpret_cast<IMP>(&flushSampleAtTime), reinterpret_cast<IMP *>(&originalTimedFlush));
    dispatch_queue_t queue = dispatch_queue_create("com.ytaudioeq.formats", DISPATCH_QUEUE_SERIAL);
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        auto &registry = outputRegistry();
        std::lock_guard<std::mutex> lock(registry.mutex);
        for (auto &entry : registry.units)
            if (entry.second->formatEpoch.load() != entry.second->publishedEpoch.load()) readOutputFormat(entry.first, *entry.second);
    });
    dispatch_resume(timer);
}
