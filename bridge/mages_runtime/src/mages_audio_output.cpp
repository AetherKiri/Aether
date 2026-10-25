#include "mages_audio_output.h"

#include <AL/al.h>
#include <AL/alc.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>

#include "impacto_host.h"

namespace aetherkiri::mages::audio {
    namespace {
        // ~21 ms of stereo audio per OpenAL buffer; four buffers keep roughly
        // 85 ms queued so scheduling jitter never reaches the listener.
        constexpr ALsizei kBufferFrames = 1024;
        constexpr size_t kBufferCount = 4;

        std::mutex g_mutex;

        // Lifecycle objects owned between StartOutput and StopOutput. The
        // pump thread keeps the context current for its lifetime because an
        // AL context may be current on only one thread at a time.
        void* g_host = nullptr;
        ALCdevice* g_device = nullptr;
        ALCcontext* g_context = nullptr;
        ALCcontext* g_previous_context = nullptr;
        ALuint g_source = 0;
        ALuint g_buffers[kBufferCount] = {};
        std::thread g_pump;
        std::atomic<bool> g_stop{false};
        std::atomic<bool> g_paused{false};
        uint32_t g_rate = 0;

        // The impacto host bridge produces interleaved stereo f32; OpenAL
        // Soft accepts that directly through AL_EXT_FLOAT32, but the plain
        // AL 1.1 stereo16 format keeps the drain on the guaranteed core path
        // for every OpenAL build this app ships.
        void ConvertS16(const float* in, size_t sample_count, int16_t* out) {
            for(size_t i = 0; i < sample_count; ++i) {
                float clamped = in[i];
                if(clamped > 1.0f) {
                    clamped = 1.0f;
                } else if(clamped < -1.0f) {
                    clamped = -1.0f;
                }
                out[i] = static_cast<int16_t>(clamped * 32767.0f);
            }
        }

        // Refills one buffer from the impacto FIFO, padding with silence when
        // the engine has not produced data yet. Always leaves the buffer
        // queued so the processed-buffer bookkeeping stays uniform.
        void RefillBuffer(ALuint buffer) {
            float staging[kBufferFrames * 2];
            const int64_t got = impacto_host_read_audio_f32(
                g_host, staging, kBufferFrames * 2);
            size_t samples = got > 0 ? static_cast<size_t>(got) : 0u;
            if(samples > kBufferFrames * 2) {
                samples = kBufferFrames * 2;
            }
            int16_t pcm[kBufferFrames * 2] = {};
            ConvertS16(staging, samples, pcm);
            alBufferData(buffer, AL_FORMAT_STEREO16, pcm,
                         static_cast<ALsizei>(sizeof(pcm)),
                         static_cast<ALsizei>(g_rate));
            alSourceQueueBuffers(g_source, 1, &buffer);
        }

        void PumpLoop() {
            // An AL context is current on at most one thread; this pump owns
            // it for the lifetime of the output.
            alcMakeContextCurrent(g_context);
            alSourcePlay(g_source);

            while(!g_stop.load(std::memory_order_relaxed)) {
                if(g_paused.load(std::memory_order_acquire)) {
                    alSourcePause(g_source);
                    std::this_thread::sleep_for(std::chrono::milliseconds(8));
                    continue;
                }
                ALint processed = 0;
                alGetSourcei(g_source, AL_BUFFERS_PROCESSED, &processed);
                while(processed-- > 0) {
                    ALuint buffer = 0;
                    alSourceUnqueueBuffers(g_source, 1, &buffer);
                    if(buffer != 0) {
                        RefillBuffer(buffer);
                    }
                }
                // A fully drained queue flips the source to STOPPED; kick it
                // again so playback resumes as soon as the engine produces.
                ALint state = 0;
                alGetSourcei(g_source, AL_SOURCE_STATE, &state);
                if(state != AL_PLAYING) {
                    alSourcePlay(g_source);
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(8));
            }

            alcMakeContextCurrent(nullptr);
        }

        // Precondition: g_mutex held.
        void StopLocked() {
            if(g_device == nullptr) {
                g_host = nullptr;
                return;
            }
            g_stop.store(true, std::memory_order_relaxed);
            if(g_pump.joinable()) {
                g_pump.join();
            }
            if(g_context != nullptr) {
                alcMakeContextCurrent(g_context);
                if(g_source != 0) {
                    alSourceStop(g_source);
                    alDeleteSources(1, &g_source);
                    g_source = 0;
                }
                alDeleteBuffers(static_cast<ALsizei>(kBufferCount), g_buffers);
                for(ALuint& buffer : g_buffers) {
                    buffer = 0;
                }
                alcMakeContextCurrent(g_previous_context);
                alcDestroyContext(g_context);
                g_context = nullptr;
            }
            if(g_device != nullptr) {
                alcCloseDevice(g_device);
                g_device = nullptr;
            }
            g_host = nullptr;
        }
    }  // namespace

    bool StartOutput(void* host, std::string& error) {
        std::lock_guard<std::mutex> lock(g_mutex);
        StopLocked();

        if(host == nullptr) {
            error = "impacto host handle is null";
            return false;
        }

        uint32_t rate = 0;
        uint32_t channels = 0;
        if(impacto_host_get_audio_format(host, &rate, &channels) !=
               IMPACTO_HOST_OK ||
           rate == 0 || channels != 2) {
            error = "impacto audio bridge format unavailable";
            return false;
        }

        g_host = host;
        g_previous_context = alcGetCurrentContext();
        g_device = alcOpenDevice(nullptr);
        if(g_device == nullptr) {
            error = "alcOpenDevice failed";
            g_host = nullptr;
            return false;
        }
        g_context = alcCreateContext(g_device, nullptr);
        if(g_context == nullptr) {
            error = "alcCreateContext failed";
            alcCloseDevice(g_device);
            g_device = nullptr;
            g_host = nullptr;
            return false;
        }
        alcMakeContextCurrent(g_context);
        alDistanceModel(AL_NONE);
        alGenBuffers(static_cast<ALsizei>(kBufferCount), g_buffers);
        alGenSources(1, &g_source);
        if(alGetError() != AL_NO_ERROR) {
            error = "OpenAL object creation failed";
            if(g_source != 0) {
                alDeleteSources(1, &g_source);
                g_source = 0;
            }
            alDeleteBuffers(static_cast<ALsizei>(kBufferCount), g_buffers);
            for(ALuint& buffer : g_buffers) {
                buffer = 0;
            }
            alcMakeContextCurrent(g_previous_context);
            alcDestroyContext(g_context);
            g_context = nullptr;
            alcCloseDevice(g_device);
            g_device = nullptr;
            g_host = nullptr;
            return false;
        }
        g_rate = rate;

        // Preload the full ring so playback starts with the deepest possible
        // buffer, then hand the context to the pump thread.
        for(const ALuint buffer : g_buffers) {
            RefillBuffer(buffer);
        }
        // Hand the context back: the pump thread takes ownership of it, and
        // the caller's thread must not keep it current.
        alcMakeContextCurrent(g_previous_context);
        g_stop.store(false, std::memory_order_relaxed);
        g_paused.store(false, std::memory_order_relaxed);
        g_pump = std::thread(PumpLoop);
        return true;
    }

    void StopOutput() {
        std::lock_guard<std::mutex> lock(g_mutex);
        StopLocked();
    }

    void SetPaused(bool paused) {
        g_paused.store(paused, std::memory_order_release);
    }

}  // namespace aetherkiri::mages::audio
