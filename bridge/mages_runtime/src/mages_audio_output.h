#ifndef AETHERKIRI_MAGES_AUDIO_OUTPUT_H_
#define AETHERKIRI_MAGES_AUDIO_OUTPUT_H_

#include <string>

namespace aetherkiri::mages::audio {

/* Wires the impacto host FIFO to an OpenAL streaming output. Failure only
 * downgrades to silence; the game itself stays usable. Mirrors the siglus
 * runtime's audio consumer. */
bool StartOutput(void* host, std::string& error);
void StopOutput();
void SetPaused(bool paused);

}  // namespace aetherkiri::mages::audio

#endif  // AETHERKIRI_MAGES_AUDIO_OUTPUT_H_
