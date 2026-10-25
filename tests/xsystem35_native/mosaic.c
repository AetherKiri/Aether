#include "render_mosaic.h"
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    SDL_Surface *surface = sdl_CreateSurface(640, 480, SDL_PIXELFORMAT_RGBA32);
    SDL_Renderer *renderer = SDL_CreateSoftwareRenderer(surface);
    SDL_Texture *source = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_XRGB8888,
                                            SDL_TEXTUREACCESS_TARGET, 640, 480);
    SDL_Texture *temporary = SDL_CreateTexture(
        renderer, SDL_PIXELFORMAT_XRGB8888, SDL_TEXTUREACCESS_TARGET, 640, 480);
    SDL_Texture *destination = SDL_CreateTexture(
        renderer, SDL_PIXELFORMAT_XRGB8888, SDL_TEXTUREACCESS_TARGET, 640, 480);
    if(!renderer || !source || !temporary || !destination)
        return 1;
    SDL_SetRenderTarget(renderer, source);
    SDL_SetRenderDrawColor(renderer, 240, 20, 10, 255);
    SDL_RenderClear(renderer);
    SDL_SetRenderDrawColor(renderer, 10, 40, 230, 255);
    SDL_Rect right = { 320, 0, 320, 480 };
    sdl_RenderFillRect(renderer, &right);
    SDL_SetRenderTarget(renderer, NULL);
    SDL_Rect full = { 0, 0, 640, 480 };
    const float scales[] = { 1.f, 2.f, 47.5f, 80.f, 96.f, 1.f };
    for(size_t i = 0; i < sizeof(scales) / sizeof(scales[0]); i++) {
        if(!render_mosaic(renderer, source, &full, temporary, destination, 640,
                          480, scales[i]))
            return 2;
        sdl_RenderTexture(renderer, destination, NULL, &full);
        SDL_RenderPresent(renderer);
        Uint8 r, g, b, a;
        Uint32 *row =
            (Uint32 *)((Uint8 *)surface->pixels + 240 * surface->pitch);
        SDL_GetRGBA(row[40], surface->format, &r, &g, &b, &a);
        if(r < 200 || b > 50) {
            fprintf(stderr, "Left color lost at scale %f\n", scales[i]);
            return 3;
        }
        SDL_GetRGBA(row[600], surface->format, &r, &g, &b, &a);
        if(b < 200 || r > 50) {
            fprintf(stderr, "Right color lost at scale %f\n", scales[i]);
            return 4;
        }
    }
    SDL_DestroyTexture(source);
    SDL_DestroyTexture(temporary);
    SDL_DestroyTexture(destination);
    SDL_DestroyRenderer(renderer);
    SDL_FreeSurface(surface);
    puts("XSYSTEM35_MOSAIC_OK");
    return 0;
}
