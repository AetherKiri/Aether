#include "systemnnn_audio.h"

#include <AL/al.h>
#include <AL/alc.h>
#include <AL/alext.h>

#include <array>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>

namespace aether::systemnnn {
namespace {
constexpr size_t kFrames = 1024;
constexpr size_t kBufferCount = 4;

void checkAL(const char* operation) {
    const ALenum code = alGetError();
    if (code != AL_NO_ERROR) {
        throw std::runtime_error(std::string(operation) + " (OpenAL error " +
                                 std::to_string(code) + ")");
    }
}

// Constructed and destroyed exclusively on the audio worker. Thread-local
// binding leaves the host's process-wide OpenAL context untouched.
struct Resources {
    ALCdevice* device = nullptr;
    ALCcontext* context = nullptr;
    PFNALCSETTHREADCONTEXTPROC setThreadContext = nullptr;
    bool bound = false;
    ALuint source = 0;
    std::array<ALuint, kBufferCount> buffers{};

    ~Resources() {
        if (bound) {
            if (source) {
                alSourceStop(source);
                alDeleteSources(1, &source);
            }
            for (ALuint buffer : buffers) {
                if (buffer) alDeleteBuffers(1, &buffer);
            }
            setThreadContext(nullptr);
        }
        if (context) alcDestroyContext(context);
        if (device) alcCloseDevice(device);
    }

    void open() {
        device = alcOpenDevice(nullptr);
        if (!device) throw std::runtime_error("Could not open the OpenAL audio device");
        if (alcIsExtensionPresent(device, "ALC_EXT_thread_local_context") != ALC_TRUE) {
            throw std::runtime_error("OpenAL requires ALC_EXT_thread_local_context (OpenAL Soft)");
        }
        setThreadContext = reinterpret_cast<PFNALCSETTHREADCONTEXTPROC>(
            alcGetProcAddress(device, "alcSetThreadContext"));
        if (!setThreadContext) throw std::runtime_error("OpenAL alcSetThreadContext is unavailable");
        context = alcCreateContext(device, nullptr);
        if (!context) throw std::runtime_error("Could not create the OpenAL audio context");
        if (setThreadContext(context) != ALC_TRUE) {
            throw std::runtime_error("Could not bind the OpenAL audio context to its worker");
        }
        bound = true;
        alGenSources(1, &source);
        checkAL("Creating the audio source");
        alGenBuffers(static_cast<ALsizei>(buffers.size()), buffers.data());
        checkAL("Creating the audio buffers");
        alSourcei(source, AL_SOURCE_RELATIVE, AL_TRUE);
        alSourcef(source, AL_ROLLOFF_FACTOR, 0.0f);
        checkAL("Configuring the audio source");
    }
};
} // namespace

struct AudioOutput::State {
    mutable std::mutex mutex;
    std::condition_variable wake;
    std::thread worker;
    std::thread::id workerId;
    bool lifecycleBusy = false;
    bool stopping = false;
    bool paused = false;
    bool ready = false;
    bool started = false;
    std::string lastError;

    void run(std::function<void(int16_t*, size_t)> pull, unsigned rate) noexcept {
        {
            std::lock_guard<std::mutex> lock(mutex);
            workerId = std::this_thread::get_id();
        }
        try {
            Resources audio;
            audio.open();
            {
                std::lock_guard<std::mutex> lock(mutex);
                // Publish before pull: the caller may still hold a session mutex.
                started = true;
                ready = true;
            }
            wake.notify_all();

            std::array<int16_t, kFrames * 2> samples{};
            auto refill = [&](ALuint buffer) {
                samples.fill(0);
                pull(samples.data(), kFrames);
                alBufferData(buffer, AL_FORMAT_STEREO16, samples.data(),
                             static_cast<ALsizei>(sizeof(samples)), static_cast<ALsizei>(rate));
                checkAL("Uploading PCM audio");
                alSourceQueueBuffers(audio.source, 1, &buffer);
                checkAL("Queueing PCM audio");
            };
            auto awaitActive = [&] {
                std::unique_lock<std::mutex> lock(mutex);
                wake.wait(lock, [&] { return stopping || !paused; });
                return !stopping;
            };
            for (ALuint buffer : audio.buffers) {
                if (!awaitActive()) break;
                refill(buffer);
            }

            for (;;) {
                bool shouldPause;
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (stopping) break;
                    shouldPause = paused;
                }
                if (shouldPause) {
                    alSourcePause(audio.source);
                    checkAL("Pausing PCM audio");
                    if (!awaitActive()) break;
                    continue;
                }
                ALint processed = 0;
                alGetSourcei(audio.source, AL_BUFFERS_PROCESSED, &processed);
                checkAL("Inspecting processed audio buffers");
                while (processed-- > 0) {
                    {
                        std::lock_guard<std::mutex> lock(mutex);
                        if (stopping || paused) break;
                    }
                    ALuint buffer = 0;
                    alSourceUnqueueBuffers(audio.source, 1, &buffer);
                    checkAL("Unqueueing PCM audio");
                    refill(buffer);
                }
                ALint sourceState = 0;
                ALint queued = 0;
                alGetSourcei(audio.source, AL_SOURCE_STATE, &sourceState);
                alGetSourcei(audio.source, AL_BUFFERS_QUEUED, &queued);
                checkAL("Inspecting the audio source");
                // Includes initial playback, resume, and starvation recovery.
                if (queued > 0 && sourceState != AL_PLAYING) {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (!stopping && !paused) {
                        alSourcePlay(audio.source);
                        checkAL("Starting PCM audio");
                    }
                }
                std::unique_lock<std::mutex> lock(mutex);
                wake.wait_for(lock, std::chrono::milliseconds(5),
                              [&] { return stopping || paused; });
            }
        } catch (const std::exception& exception) {
            std::lock_guard<std::mutex> lock(mutex);
            lastError = exception.what();
        } catch (...) {
            std::lock_guard<std::mutex> lock(mutex);
            lastError = "Unknown failure in the OpenAL audio worker";
        }
        {
            std::lock_guard<std::mutex> lock(mutex);
            ready = true;
            workerId = {};
        }
        wake.notify_all();
    }
};

AudioOutput::AudioOutput() : state_(std::make_unique<State>()) {}
AudioOutput::~AudioOutput() { stop(); }

bool AudioOutput::start(std::function<void(int16_t*, size_t)> pull, unsigned rate) {
    State& state = *state_;
    std::unique_lock<std::mutex> lock(state.mutex);
    if (state.workerId == std::this_thread::get_id()) {
        state.lastError = "AudioOutput::start cannot be called from its audio callback";
        return false;
    }
    state.wake.wait(lock, [&] { return !state.lifecycleBusy; });
    state.lifecycleBusy = true;
    state.stopping = true;
    state.wake.notify_all();
    std::thread previous = std::move(state.worker);
    lock.unlock();
    if (previous.joinable()) previous.join();
    lock.lock();
    state.lastError.clear();
    state.ready = false;
    state.started = false;
    state.stopping = false;
    state.paused = false;
    if (!pull || rate == 0 || rate > static_cast<unsigned>(std::numeric_limits<ALsizei>::max())) {
        state.lastError = "AudioOutput requires a callback and a valid positive sample rate";
    } else {
        try {
            state.worker = std::thread([&state, pull = std::move(pull), rate]() mutable {
                state.run(std::move(pull), rate);
            });
            state.wake.wait(lock, [&] { return state.ready; });
        } catch (const std::exception& exception) {
            state.lastError = std::string("Could not start the audio worker: ") + exception.what();
        }
    }
    const bool success = state.started;
    if (!success) {
        std::thread failed = std::move(state.worker);
        lock.unlock();
        if (failed.joinable()) failed.join();
        lock.lock();
    }
    state.lifecycleBusy = false;
    lock.unlock();
    state.wake.notify_all();
    return success;
}

void AudioOutput::stop() {
    State& state = *state_;
    std::unique_lock<std::mutex> lock(state.mutex);
    // A callback may request shutdown; its thread is joined by a later external
    // stop/start/destruction, never detached or joined to itself.
    if (state.workerId == std::this_thread::get_id()) {
        state.stopping = true;
        state.wake.notify_all();
        return;
    }
    state.wake.wait(lock, [&] { return !state.lifecycleBusy; });
    state.lifecycleBusy = true;
    state.stopping = true;
    state.wake.notify_all();
    std::thread worker = std::move(state.worker);
    lock.unlock();
    if (worker.joinable()) worker.join();
    lock.lock();
    state.started = false;
    state.lifecycleBusy = false;
    lock.unlock();
    state.wake.notify_all();
}

void AudioOutput::pause(bool paused) {
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->paused = paused;
    }
    state_->wake.notify_all();
}

std::string AudioOutput::error() const {
    std::lock_guard<std::mutex> lock(state_->mutex);
    return state_->lastError;
}

} // namespace aether::systemnnn
