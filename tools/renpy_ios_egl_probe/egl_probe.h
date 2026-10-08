#pragma once
#include <stdint.h>

#define AETHER_EGL_PROBE_SIZE 16
typedef struct aether_egl_probe_result {
    int passed;
    int pbuffer_created;
    int readback_verified;
    int host_context_restored;
    int resume_verified;
    int client_version;
    unsigned int egl_error;
    unsigned int gl_error;
    char error[256];
    char egl_vendor[256];
    char egl_version[256];
    char gl_vendor[256];
    char gl_renderer[512];
    char gl_version[256];
    uint8_t pixels[AETHER_EGL_PROBE_SIZE * AETHER_EGL_PROBE_SIZE * 4];
} aether_egl_probe_result;

/* Executes real MetalANGLE EGL/GLES calls, without any UIKit/SDL window. */
int aether_run_egl_probe(aether_egl_probe_result *result);
