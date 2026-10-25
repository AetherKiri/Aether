#include <SDL.h>
#include <SDL_mixer.h>
#include <stdio.h>
#include <string.h>

static SDL_atomic_t music_finished;

static void MusicFinished(void) { SDL_AtomicSet(&music_finished, 1); }

int main(void) {
    SDL_setenv("SDL_AUDIODRIVER", "dummy", 1);
    const int requested = MIX_INIT_MP3 | MIX_INIT_OGG;
    if((Mix_Init(requested) & requested) != requested) {
        fprintf(stderr, "System35 needs MP3 and Ogg decoders: %s\n",
                Mix_GetError());
        return 1;
    }
    if(Mix_OpenAudio(44100, AUDIO_S16SYS, 2, 512) != 0) {
        fprintf(stderr, "Cannot open dummy audio device: %s\n", Mix_GetError());
        return 2;
    }
    // Four synthetic silent MPEG1 layer III frames, 128 kbps / 44.1 kHz.
    // Exercise the real decoder and mixer without bundling a game audio file.
    Uint8 mp3[417 * 4] = { 0 };
    for(int frame = 0; frame < 4; frame++) {
        Uint8 *header = mp3 + 417 * frame;
        header[0] = 0xff;
        header[1] = 0xfb;
        header[2] = 0x90;
        header[3] = 0x00;
    }
    Mix_HookMusicFinished(MusicFinished);
    Mix_Music *music = Mix_LoadMUS_RW(SDL_RWFromConstMem(mp3, sizeof(mp3)), 1);
    if(!music || Mix_PlayMusic(music, 0) != 0) {
        fprintf(stderr, "Cannot decode synthetic MP3: %s\n", Mix_GetError());
        return 3;
    }
    // Observe after the short clip normally ends, as can happen after a
    // scheduler stall. Completion must survive a late observer.
    SDL_Delay(200);
    const Uint32 started = SDL_GetTicks();
    while(!SDL_AtomicGet(&music_finished) && SDL_GetTicks() - started < 2000)
        SDL_Delay(5);
    if(!SDL_AtomicGet(&music_finished)) {
        fprintf(stderr, "MP3 playback did not finish: %s\n", Mix_GetError());
        return 4;
    }
    Mix_HookMusicFinished(NULL);
    Mix_HaltMusic();
    Mix_FreeMusic(music);
    Mix_CloseAudio();
    Mix_Quit();
    SDL_QuitSubSystem(SDL_INIT_AUDIO);
    puts("XSYSTEM35_AUDIO_OK");
    return 0;
}
