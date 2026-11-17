#include "systemnnn_audio.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>

using aether::systemnnn::AudioOutput;
using namespace std::chrono_literals;
static void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
int main() {
    try {
        std::mutex mutex;
        std::condition_variable changed;
        unsigned calls = 0;
        bool bad_buffer = false;
        std::atomic<bool> callback_threw{false};
        AudioOutput output;
        require(!output.start({}, 44100), "Empty callback must fail");
        require(!output.error().empty(), "Invalid callback must report an error");
        require(!output.start([](auto*, auto) {}, 0), "Zero sample rate must fail");
        output.stop();
        output.stop();

        auto pull = [&](int16_t* samples, size_t frames) {
            std::lock_guard<std::mutex> lock(mutex);
            bad_buffer |= !samples || frames == 0;
            if (samples) {
                bad_buffer |= !std::all_of(samples, samples + frames * 2, [](auto sample) { return sample == 0; });
                std::fill(samples, samples + frames * 2, int16_t{100});
            }
            ++calls;
            output.pause(true);
            changed.notify_all();
        };
        // start must publish readiness before invoking a callback that waits on
        // the caller's session mutex. A regression here hits the CTest timeout.
        std::unique_lock<std::mutex> lock(mutex);
        require(output.start(pull), "Null audio backend must start");
        require(changed.wait_for(lock, 2s, [&] { return calls == 1; }), "First PCM callback missing");
        require(!bad_buffer, "Callback receives zeroed stereo frame storage");
        require(!changed.wait_for(lock, 100ms, [&] { return calls != 1; }), "Pause must stop PCM pulls");
        lock.unlock();
        output.pause(false);
        lock.lock();
        require(changed.wait_for(lock, 2s, [&] { return calls == 2; }), "Resume must restore PCM pulls");
        lock.unlock();
        output.stop();
        require(output.error().empty(), "Healthy playback reports no error");

        require(output.start([&](auto*, auto) {
            callback_threw = true;
            throw std::runtime_error("fixture callback failure");
        }), "Restart after stop must succeed");
        const auto deadline = std::chrono::steady_clock::now() + 2s;
        while (output.error().empty() && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(1ms);
        require(callback_threw && output.error().find("fixture callback failure") != std::string::npos,
                "Worker exception must be reported without terminating the process");
        output.stop();
        require(output.start([](int16_t*, size_t) {}), "Restart after callback failure must succeed");
        require(output.error().empty(), "Successful restart clears prior error");
        output.stop();
        std::cout << "SystemNNN audio lifecycle contract passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
