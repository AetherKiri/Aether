#ifndef AETHERKIRI_LUCA_AUDIO_OUTPUT_H_
#define AETHERKIRI_LUCA_AUDIO_OUTPUT_H_

#include <string>

namespace aetherkiri::luca::audio {

    // Opens an OpenAL streaming output draining the Rust mixer FIFO through
    // the luca_ak_read_audio_f32 FFI (see luca_ffi.h). Idempotent: an
    // already running output is restarted. Returns false with details on
    // failure.
    bool StartOutput(std::string &error);

    // Closes the stream and logs cumulative drained/underrun statistics.
    // Safe to call when not started.
    void StopOutput();

    void SetPaused(bool paused);

}  // namespace aetherkiri::luca::audio

#endif  // AETHERKIRI_LUCA_AUDIO_OUTPUT_H_
