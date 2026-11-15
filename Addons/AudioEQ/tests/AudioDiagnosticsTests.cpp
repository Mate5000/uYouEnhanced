#include "../AudioDiagnostics.hpp"
#include <cassert>
#include <cstring>
#include <iostream>
#include <thread>

int main() {
    using namespace ytaeq;
    static_assert(std::atomic<uint64_t>::is_always_lock_free, "Audio diagnostics must not lock");
    for (int32_t status : {0, -50, 2037671281, INT32_MIN, INT32_MAX}) {
        for (uint32_t stage = 0; stage <= uint32_t(FailureStage::ImportRebinding); ++stage) {
            const auto value = failureValue(FailureStage(stage), status);
            assert(failureStage(value) == FailureStage(stage));
            assert(failureStatus(value) == status);
            assert(std::strlen(failureStageName(FailureStage(stage))) > 0);
        }
    }
    assert(std::strstr(failureStageName(FailureStage::DecoderNeedsInput), "more input required"));
    // A UI snapshot must never pair the stage from one failure with another
    // callback's OSStatus, including signed OSStatus values.
    std::atomic<uint64_t> latest{failureValue(FailureStage::DecoderNeedsInput, 2037671281)};
    std::atomic<bool> done{false};
    std::thread writer([&] {
        for (unsigned i = 0; i < 100000; ++i)
            latest.store(i % 2 ? failureValue(FailureStage::DecoderNeedsInput, 2037671281) : failureValue(FailureStage::OutputBufferCreate, -50));
        done.store(true);
    });
    do {
        const auto value = latest.load();
        assert(failureStage(value) == FailureStage::DecoderNeedsInput ? failureStatus(value) == 2037671281 : failureStage(value) == FailureStage::OutputBufferCreate && failureStatus(value) == -50);
    } while (!done.load());
    writer.join();
    std::cout << "PASS: audio failure stages, signed statuses and concurrent UI snapshots\n";
}
