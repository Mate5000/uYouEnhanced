#pragma once
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace ytaeq {
// Producer-queue storage, never used on a real-time render callback. A system
// decoder can retain a small number of frames during startup. Compensate that
// delay ONCE, keeping each replacement buffer's original PTS and duration.
// Later output is carried forward, never dropped, replayed or padded per block.
class DecoderPCM {
    std::vector<float> pending_, output_;
    uint32_t queued_ = 0, target_ = 0, channels_ = 0, limit_ = 0;
    uint32_t padding_ = 0;
    bool started_ = false;
public:
    void reset() { queued_ = padding_ = 0; started_ = false; }
    void prepare(uint32_t frames, uint32_t channels, uint32_t maximumDelay) {
        target_ = frames; channels_ = channels; limit_ = maximumDelay;
        // One extra frame forces an input callback after the last packet. The
        // callback's temporary-starvation status also releases its input memory.
        pending_.resize(size_t(frames + maximumDelay + 1) * channels);
        output_.resize(size_t(frames) * channels);
    }
    float *writePointer() { return pending_.data() + size_t(queued_) * channels_; }
    uint32_t capacity() const { return target_ + limit_ + 1 - queued_; }
    bool finish(uint32_t frames) {
        if (frames > capacity()) return false;
        const uint32_t available = queued_ + frames;
        const uint32_t missing = available < target_ ? target_ - available : 0;
        // Only accept a bounded, nonempty startup shortfall. Recurring starvation
        // is a real failure and must not become gaps in otherwise audible music.
        if (missing && (started_ || !available || missing > limit_)) return false;
        const uint32_t take = target_ - missing;
        const uint32_t carry = available - take;
        if (carry > limit_) return false;
        std::fill_n(output_.data(), size_t(missing) * channels_, 0.0f);
        std::memcpy(output_.data() + size_t(missing) * channels_, pending_.data(), size_t(take) * channels_ * sizeof(float));
        if (carry) std::memmove(pending_.data(), pending_.data() + size_t(take) * channels_, size_t(carry) * channels_ * sizeof(float));
        queued_ = carry;
        if (!started_) padding_ = missing;
        started_ = true;
        return true;
    }
    float *data() { return output_.data(); }
    uint32_t queuedFrames() const { return queued_; }
    uint32_t startupPadding() const { return padding_; }
    bool started() const { return started_; }
};
} // namespace ytaeq
