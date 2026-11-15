#include "../DecoderPCM.hpp"
#include <cassert>
#include <cmath>
#include <iostream>

static void stream(unsigned channels, unsigned rate) {
    ytaeq::DecoderPCM pcm;
    const unsigned block = rate / 5, delay = rate / 400; // 120 @ 48 kHz
    uint64_t generated = 0, rendered = 0;
    for (unsigned b = 0; b < 300; ++b) {
        pcm.prepare(block, channels, rate / 50);
        const unsigned count = b == 0 ? block - delay : block;
        for (unsigned i = 0; i < count; ++i, ++generated)
            for (unsigned c = 0; c < channels; ++c)
                pcm.writePointer()[i * channels + c] = float(generated * channels + c + 1);
        assert(pcm.finish(count));
        for (unsigned i = 0; i < block; ++i, ++rendered)
            for (unsigned c = 0; c < channels; ++c)
                assert(pcm.data()[i * channels + c] == (rendered < delay ? 0.0f : float((rendered - delay) * channels + c + 1)));
        assert(pcm.startupPadding() == delay);
        assert(pcm.queuedFrames() == 0);
    }
    assert(generated + delay == rendered); // no loss, replay or cumulative drift
    pcm.reset(); // seek, format change, flush and new video all clear the carry
    assert(!pcm.started() && !pcm.queuedFrames() && !pcm.startupPadding());
    pcm.prepare(block, channels, rate / 50);
    std::fill_n(pcm.writePointer(), block * channels, 0.25f);
    assert(pcm.finish(block));
    assert(pcm.startupPadding() == 0 && pcm.data()[0] == 0.25f);
}
int main() {
    for (unsigned channels : {1, 2}) for (unsigned rate : {44100, 48000}) stream(channels, rate);
    ytaeq::DecoderPCM pcm;
    pcm.prepare(9600, 2, 960);
    assert(!pcm.finish(0));
    assert(!pcm.finish(8639)); // excessive startup delay
    assert(!pcm.finish(pcm.capacity() + 1));
    for (unsigned i = 0; i < 9600 * 2; ++i) pcm.writePointer()[i] = float(i + 1);
    assert(pcm.finish(9480)); // exact device regression
    assert(pcm.startupPadding() == 120 && pcm.data()[240] == 1);
    pcm.prepare(9600, 2, 960);
    assert(!pcm.finish(9480)); // MUST NOT insert silence again in every block
    pcm.reset();
    pcm.prepare(9600, 1, 960);
    for (unsigned i = 0; i < 9720; ++i) pcm.writePointer()[i] = float(i + 1);
    assert(pcm.finish(9720) && pcm.queuedFrames() == 120);
    pcm.prepare(9600, 1, 960);
    for (unsigned i = 0; i < 9480; ++i) pcm.writePointer()[i] = float(9721 + i);
    assert(pcm.finish(9480) && pcm.queuedFrames() == 0);
    for (unsigned i = 0; i < 9600; ++i) assert(pcm.data()[i] == float(9601 + i));
    std::cout << "PASS: 9600/9480 Opus startup, continuous PCM order, bounded carry, resets, mono/stereo 44.1/48 kHz\n";
}
