#include "midi.h"
#include <stdio.h>

static int init_calls;
static int reset_calls;
static bool available = true;

static bool Init(int device) {
    ++init_calls;
    return available && device == 0;
}

static void Reset(void) { ++reset_calls; }

// Deliberately provide no midi_android. The embedded dispatcher must select
// SDL_mixer without depending on the standalone application's JNI activity.
mididevice_t midi_sdlmixer = { .init = Init, .reset = Reset };

int main(void) {
    mididevice_t device = { 0 };
    if(!midi_init(&device) || init_calls != 1 || device.reset != Reset) {
        fprintf(stderr, "Embedded Android did not select SDL_mixer MIDI\n");
        return 1;
    }
    device.reset();
    if(reset_calls != 1)
        return 2;

    available = false;
    if(midi_init(&device) || init_calls != 2) {
        fprintf(stderr, "MIDI initialization failure was not propagated\n");
        return 3;
    }

    midi_set_output_device('0', 0);
    if(midi_init(&device) || init_calls != 2) {
        fprintf(stderr, "Disabled MIDI initialized a backend\n");
        return 4;
    }
    return 0;
}
