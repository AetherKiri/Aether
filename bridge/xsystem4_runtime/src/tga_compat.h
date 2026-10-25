/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <SDL_image.h>
#include "system4/cg.h"

static bool aether_tga_matches(const uint8_t *data, size_t size) {
    return size >= 18 && data[1] == 0 && (data[2] == 2 || data[2] == 10) &&
        (data[16] == 24 || data[16] == 32) && !(data[17] & 0xc0);
}

static bool aether_tga_metrics(const uint8_t *data, size_t size,
                               struct cg_metrics *metrics) {
    if(!aether_tga_matches(data, size))
        return false;
    const int width = data[12] | (data[13] << 8);
    const int height = data[14] | (data[15] << 8);
    if(width < 1 || height < 1 || (size_t)width * height > 64u * 1024u * 1024u)
        return false;
    *metrics = (struct cg_metrics){ .w = width,
                                    .h = height,
                                    .bpp = data[16],
                                    .has_pixel = true,
                                    .has_alpha =
                                        data[16] == 32 && (data[17] & 0xf) != 0,
                                    .pixel_pitch = width * (data[16] / 8),
                                    .alpha_pitch = 1 };
    return true;
}

static struct cg *aether_tga_load(const uint8_t *data, size_t size) {
    struct cg_metrics metrics;
    if(size > INT_MAX || !aether_tga_metrics(data, size, &metrics))
        return NULL;
    // SDL_image can return a partial surface for a truncated TGA. Validate the
    // complete pixel stream before handing it to the decoder.
    size_t position = 18u + data[0];
    size_t remaining = (size_t)metrics.w * metrics.h;
    const size_t pixel_size = data[16] / 8;
    if(position > size)
        return NULL;
    if(data[2] == 2) {
        if(remaining > (size - position) / pixel_size)
            return NULL;
    } else {
        while(remaining) {
            if(position >= size)
                return NULL;
            const uint8_t packet = data[position++];
            const size_t count = (packet & 0x7f) + 1;
            const size_t bytes =
                (packet & 0x80) ? pixel_size : count * pixel_size;
            if(count > remaining || bytes > size - position)
                return NULL;
            position += bytes;
            remaining -= count;
        }
    }
    // SDL_image handles vertical origin but rejects right-to-left storage.
    // Normalize that header in memory, then mirror the decoded row below.
    uint8_t *normalized = NULL;
    if(data[17] & 0x10) {
        normalized = malloc(size);
        if(!normalized)
            return NULL;
        memcpy(normalized, data, size);
        normalized[17] &= ~0x10;
    }
    SDL_RWops *stream =
        SDL_RWFromConstMem(normalized ? normalized : data, (int)size);
    if(!stream) {
        free(normalized);
        return NULL;
    }
    SDL_Surface *surface = IMG_LoadTyped_RW(stream, 1, "TGA");
    free(normalized);
    if(!surface)
        return NULL;
    SDL_Surface *rgba =
        SDL_ConvertSurfaceFormat(surface, SDL_PIXELFORMAT_RGBA32, 0);
    SDL_FreeSurface(surface);
    if(!rgba)
        return NULL;
    struct cg *image = calloc(1, sizeof(*image));
    if(image) {
        image->metrics = metrics;
        image->pixels = malloc((size_t)metrics.w * metrics.h * 4);
        if(!image->pixels || SDL_LockSurface(rgba)) {
            free(image->pixels);
            free(image);
            image = NULL;
        } else {
            for(int y = 0; y < metrics.h; ++y) {
                uint8_t *row =
                    (uint8_t *)image->pixels + (size_t)y * metrics.w * 4;
                const uint8_t *source =
                    (uint8_t *)rgba->pixels + (size_t)y * rgba->pitch;
                if(data[17] & 0x10) {
                    for(int x = 0; x < metrics.w; ++x)
                        memcpy(row + x * 4, source + (metrics.w - 1 - x) * 4,
                               4);
                } else {
                    memcpy(row, source, (size_t)metrics.w * 4);
                }
            }
            SDL_UnlockSurface(rgba);
        }
    }
    SDL_FreeSurface(rgba);
    return image;
}
