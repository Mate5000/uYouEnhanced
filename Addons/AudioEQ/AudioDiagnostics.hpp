#pragma once
#include <atomic>
#include <cstdint>

namespace ytaeq {
enum class FailureStage : uint32_t {
    None, NotReady, MissingFormat, UnsupportedFormat, InvalidTimestamp,
    InvalidDuration, DecoderCreate, DecoderCookie, MissingPackets, PacketLayout,
    DecoderFill, DecoderNeedsInput, DecoderFrameCount, PCMBufferLayout,
    OutputFormat, OutputBufferCreate, OutOfMemory, RemoteIOFormat,
    ConcurrentAccess, ImportRebinding
};
constexpr uint64_t failureValue(FailureStage stage, int32_t status) {
    return (uint64_t(stage) << 32) | uint32_t(status);
}
constexpr FailureStage failureStage(uint64_t value) { return FailureStage(value >> 32); }
constexpr int32_t failureStatus(uint64_t value) { return int32_t(uint32_t(value)); }
inline const char *failureStageName(FailureStage stage) {
    switch (stage) {
        case FailureStage::None: return "No failure recorded";
        case FailureStage::NotReady: return "CMSampleBufferDataIsReady";
        case FailureStage::MissingFormat: return "CMSampleBufferGetFormatDescription";
        case FailureStage::UnsupportedFormat: return "Validate source PCM/codec format";
        case FailureStage::InvalidTimestamp: return "Validate presentation timestamp";
        case FailureStage::InvalidDuration: return "Convert buffer duration to PCM frames";
        case FailureStage::DecoderCreate: return "AudioConverterNew";
        case FailureStage::DecoderCookie: return "AudioConverterSetProperty(magic cookie)";
        case FailureStage::MissingPackets: return "Read compressed packets / block buffer";
        case FailureStage::PacketLayout: return "Validate packet descriptions";
        case FailureStage::DecoderFill: return "AudioConverterFillComplexBuffer";
        case FailureStage::DecoderNeedsInput: return "AudioConverterFillComplexBuffer: more input required";
        case FailureStage::DecoderFrameCount: return "Validate decoded frame / packet count";
        case FailureStage::PCMBufferLayout: return "Validate PCM buffer layout";
        case FailureStage::OutputFormat: return "CMAudioFormatDescriptionCreate";
        case FailureStage::OutputBufferCreate: return "Create replacement PCM sample buffer";
        case FailureStage::OutOfMemory: return "Allocate producer-queue scratch storage";
        case FailureStage::RemoteIOFormat: return "Read RemoteIO PCM stream format";
        case FailureStage::ConcurrentAccess: return "Concurrent access: original buffer preserved";
        case FailureStage::ImportRebinding: return "Rebind app's Core Audio imports";
    }
    return "Unknown stage";
}
} // namespace ytaeq
