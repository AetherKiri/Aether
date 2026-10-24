#include <SDL.h>
#include <SDL_mixer.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    SDL_setenv("SDL_AUDIODRIVER", "dummy", 1);
    const int requested = MIX_INIT_MP3 | MIX_INIT_OGG;
    if((Mix_Init(requested) & requested) != requested) {
        fprintf(stderr, "System35 needs MP3 and Ogg decoders: %s\n",
                Mix_GetError());
        return 1;
    }
    if(Mix_OpenAudio(44100, AUDIO_S16SYS, 2, 512) != 0)
        return 2;
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
    Mix_Music *music = Mix_LoadMUS_RW(SDL_RWFromConstMem(mp3, sizeof(mp3)), 1);
    if(!music || Mix_PlayMusic(music, 0) != 0) {
        fprintf(stderr, "Cannot decode synthetic MP3: %s\n", Mix_GetError());
        return 3;
    }
    SDL_Delay(20);
    if(!Mix_PlayingMusic())
        return 4;
    Mix_HaltMusic();
    Mix_FreeMusic(music);
    Mix_CloseAudio();
    Mix_Quit();
    SDL_QuitSubSystem(SDL_INIT_AUDIO);
    puts("XSYSTEM35_AUDIO_OK");
    return 0;
}
