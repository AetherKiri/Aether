#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace aether::systemnnn {

// Stereo, interleaved signed 16-bit PCM. The callback receives a frame count:
// each frame occupies two int16_t samples. Unwritten samples remain silent.
class AudioOutput {
public:
    AudioOutput();
    ~AudioOutput();

    AudioOutput(const AudioOutput&) = delete;
    AudioOutput& operator=(const AudioOutput&) = delete;

    // Device/context allocation completes before returning; pull runs only on
    // the worker, without an AudioOutput mutex held. Do not call start() or
    // destroy this object from pull. Release any mutex used by pull before stop()
    // or restarting an existing worker with start(), since both join that worker.
    bool start(std::function<void(int16_t*, size_t)> pull, unsigned rate = 44100);
    void stop();
    void pause(bool paused);
    std::string error() const;

private:
    struct State;
    std::unique_ptr<State> state_;
};

} // namespace aether::systemnnn
