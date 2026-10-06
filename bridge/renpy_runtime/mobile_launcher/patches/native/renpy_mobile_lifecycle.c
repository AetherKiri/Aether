/*
 * Host-owned Ren'Py lifecycle implementation.
 *
 * This translation unit is linked into a fork of renpy-build's
 * librenpython_android.c/librenpython.c after those launchers have performed
 * Python initialization. It deliberately never calls SDL_main, launcher_main,
 * Py_RunMain, SDL_RunApp, SDL_UIKitRunApp, UIApplicationMain, or exits the
 * process. The fork must call renpy_mobile_bind_window() after Ren'Py has
 * created the already-owned SDL window.
 */
#include <SDL3/SDL.h>
#include <Python.h>
#include <string.h>
#include "renpy_mobile_launcher.h"

static const renpy_mobile_host_t *aether_host;
static PyObject *aether_main_module;
static SDL_Window *aether_window;
static int aether_started;
static int aether_paused;
static unsigned long long aether_frame_serial;

static int launcher_error(void) {
    return RENPY_MOBILE_ERROR;
}

static int call_main_noargs(const char *name, PyObject **result) {
    if (!aether_main_module) return RENPY_MOBILE_INVALID_STATE;
    PyObject *value = PyObject_CallMethod(aether_main_module, name, NULL);
    if (!value) {
        PyErr_Clear();
        return launcher_error();
    }
    if (result) *result = value;
    else Py_DECREF(value);
    return RENPY_MOBILE_OK;
}

/* Called by the patched SDL/desktop initialization after it creates the host
 * window. The pointer is borrowed for the lifetime of the SDL window. */
int renpy_mobile_bind_window(SDL_Window *window) {
    if (!window) return RENPY_MOBILE_INVALID_ARGUMENT;
    aether_window = window;
    return RENPY_MOBILE_OK;
}

int renpy_mobile_init(const renpy_mobile_config_t *config,
                      const renpy_mobile_host_t *host) {
    if (!config || !host || config->struct_size < sizeof(*config) ||
        host->struct_size < sizeof(*host) ||
        config->abi_version != RENPY_MOBILE_LAUNCHER_ABI_VERSION ||
        host->abi_version != RENPY_MOBILE_LAUNCHER_ABI_VERSION) {
        return RENPY_MOBILE_INVALID_ARGUMENT;
    }
    if (aether_started) return RENPY_MOBILE_INVALID_STATE;
    if (!Py_IsInitialized()) return RENPY_MOBILE_INVALID_STATE;

    aether_host = host;
    aether_main_module = PyImport_ImportModule("renpy.main");
    if (!aether_main_module) {
        PyErr_Clear();
        aether_host = NULL;
        return launcher_error();
    }

    PyObject *started = NULL;
    int status = call_main_noargs("cooperative_start", &started);
    if (status != RENPY_MOBILE_OK) {
        Py_DECREF(aether_main_module);
        aether_main_module = NULL;
        aether_host = NULL;
        return status;
    }
    Py_XDECREF(started);
    aether_started = 1;
    aether_paused = 0;
    aether_frame_serial = 0;
    return RENPY_MOBILE_OK;
}

int renpy_mobile_tick(uint32_t budget_ms) {
    if (!aether_started || aether_paused) return RENPY_MOBILE_INVALID_STATE;
    PyObject *result = PyObject_CallMethod(aether_main_module,
                                           "cooperative_tick", "I",
                                           budget_ms);
    if (!result) {
        PyErr_Clear();
        return launcher_error();
    }
    int status = RENPY_MOBILE_OK;
    if (PyUnicode_Check(result)) {
        const char *value = PyUnicode_AsUTF8(result);
        if (value && strcmp(value, "finished") == 0) status = RENPY_MOBILE_OK;
        else if (value && strcmp(value, "yield") == 0) status = RENPY_MOBILE_OK;
        else if (value && strcmp(value, "not_started") == 0) {
            status = RENPY_MOBILE_INVALID_STATE;
        }
    }
    Py_DECREF(result);
    return status;
}

int renpy_mobile_frame(renpy_mobile_frame_t *out_frame) {
    if (!out_frame || out_frame->struct_size < sizeof(*out_frame)) {
        return RENPY_MOBILE_INVALID_ARGUMENT;
    }
    if (!aether_started || !aether_window) return RENPY_MOBILE_INVALID_STATE;

    SDL_Surface *surface = SDL_GetWindowSurface(aether_window);
    if (!surface || !surface->pixels || surface->w <= 0 || surface->h <= 0) {
        return RENPY_MOBILE_INVALID_STATE;
    }
    out_frame->rgba = (const uint8_t *)surface->pixels;
    out_frame->width = (uint32_t)surface->w;
    out_frame->height = (uint32_t)surface->h;
    out_frame->stride = (uint32_t)surface->pitch;
    out_frame->serial = ++aether_frame_serial;
    if (aether_host && aether_host->present_rgba) {
        aether_host->present_rgba(aether_host->user_data, out_frame->rgba,
                                  out_frame->width, out_frame->height,
                                  out_frame->stride);
    }
    return RENPY_MOBILE_OK;
}

int renpy_mobile_input(const renpy_mobile_input_t *event) {
    if (!event || event->struct_size < sizeof(*event)) {
        return RENPY_MOBILE_INVALID_ARGUMENT;
    }
    if (!aether_started || aether_paused) return RENPY_MOBILE_INVALID_STATE;

    SDL_Event sdl_event;
    SDL_zero(sdl_event);
    if (event->type == RENPY_MOBILE_INPUT_POINTER) {
        sdl_event.type = SDL_EVENT_FINGER_MOTION;
        sdl_event.tfinger.x = event->x;
        sdl_event.tfinger.y = event->y;
        sdl_event.tfinger.pressure = event->pressure;
    } else if (event->type == RENPY_MOBILE_INPUT_KEY) {
        sdl_event.type = event->value ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
        sdl_event.key.key = (SDL_Keycode)event->code;
    } else {
        return RENPY_MOBILE_INVALID_ARGUMENT;
    }
    return SDL_PushEvent(&sdl_event) ? RENPY_MOBILE_OK : launcher_error();
}

int renpy_mobile_pause(void) {
    if (!aether_started) return RENPY_MOBILE_INVALID_STATE;
    aether_paused = 1;
    return RENPY_MOBILE_OK;
}

int renpy_mobile_resume(void) {
    if (!aether_started) return RENPY_MOBILE_INVALID_STATE;
    aether_paused = 0;
    return RENPY_MOBILE_OK;
}

void renpy_mobile_shutdown(void) {
    if (aether_main_module && Py_IsInitialized()) {
        (void)call_main_noargs("cooperative_stop", NULL);
        Py_DECREF(aether_main_module);
    }
    aether_main_module = NULL;
    aether_host = NULL;
    aether_window = NULL;
    aether_started = 0;
    aether_paused = 0;
}
