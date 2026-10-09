#include "egl_probe.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static void copy_string(char *target, size_t size, const char *source) {
    snprintf(target, size, "%s", source ? source : "");
}

static int expect_pixel(const unsigned char *pixels, int x, int y,
                        int r, int g, int b, int a) {
    const unsigned char *pixel = pixels + (y * AETHER_EGL_PROBE_SIZE + x) * 4;
    const int expected[4] = {r, g, b, a};
    for (int c = 0; c < 4; ++c) {
        const int delta = (int)pixel[c] - expected[c];
        if (delta < -1 || delta > 1) return 0;
    }
    return 1;
}

int aether_run_egl_probe(aether_egl_probe_result *out) {
    memset(out, 0, sizeof(*out));
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface host_surface = EGL_NO_SURFACE, game_surface = EGL_NO_SURFACE;
    EGLContext host_context = EGL_NO_CONTEXT, game_context = EGL_NO_CONTEXT;
    const EGLDisplay previous_display = eglGetCurrentDisplay();
    const EGLContext previous_context = eglGetCurrentContext();
    const EGLSurface previous_draw = eglGetCurrentSurface(EGL_DRAW);
    const EGLSurface previous_read = eglGetCurrentSurface(EGL_READ);
    const EGLenum previous_api = eglQueryAPI();
#define CHECK(condition, message) do { if (!(condition)) { \
    copy_string(out->error, sizeof(out->error), message); \
    out->egl_error = eglGetError(); out->gl_error = glGetError(); goto cleanup; \
} } while (0)
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    CHECK(get_platform_display, "MetalANGLE has no eglGetPlatformDisplayEXT");
    const EGLint metal_attributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE
    };
    display = get_platform_display(EGL_PLATFORM_ANGLE_ANGLE,
                                   (void *)(uintptr_t)EGL_DEFAULT_DISPLAY, metal_attributes);
    CHECK(display != EGL_NO_DISPLAY, "could not create ANGLE Metal EGL display");
    EGLint egl_major = 0, egl_minor = 0;
    CHECK(eglInitialize(display, &egl_major, &egl_minor), "eglInitialize failed (Metal GPU may be unavailable)");
    copy_string(out->egl_vendor, sizeof(out->egl_vendor), eglQueryString(display, EGL_VENDOR));
    copy_string(out->egl_version, sizeof(out->egl_version), eglQueryString(display, EGL_VERSION));
    CHECK(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI GLES failed");
    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 16, EGL_NONE
    };
    EGLConfig config = NULL;
    EGLint config_count = 0;
    CHECK(eglChooseConfig(display, config_attributes, &config, 1, &config_count) && config_count == 1,
          "no RGBA8 GLES pbuffer EGL configuration");
    const EGLint surface_attributes[] = {
        EGL_WIDTH, AETHER_EGL_PROBE_SIZE, EGL_HEIGHT, AETHER_EGL_PROBE_SIZE, EGL_NONE
    };
    host_surface = eglCreatePbufferSurface(display, config, surface_attributes);
    game_surface = eglCreatePbufferSurface(display, config, surface_attributes);
    CHECK(host_surface != EGL_NO_SURFACE && game_surface != EGL_NO_SURFACE, "eglCreatePbufferSurface failed");
    out->pbuffer_created = 1;
    const EGLint context3[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    const EGLint context2[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    game_context = eglCreateContext(display, config, EGL_NO_CONTEXT, context3);
    out->client_version = 3;
    if (game_context == EGL_NO_CONTEXT) {
        (void)eglGetError();
        game_context = eglCreateContext(display, config, EGL_NO_CONTEXT, context2);
        out->client_version = 2;
    }
    host_context = eglCreateContext(display, config, EGL_NO_CONTEXT,
                                   out->client_version == 3 ? context3 : context2);
    CHECK(game_context != EGL_NO_CONTEXT && host_context != EGL_NO_CONTEXT, "eglCreateContext failed");
    CHECK(eglMakeCurrent(display, host_surface, host_surface, host_context), "could not bind host pbuffer context");
    glClearColor(0, 1, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    CHECK(eglMakeCurrent(display, game_surface, game_surface, game_context), "could not bind game pbuffer context");
    copy_string(out->gl_vendor, sizeof(out->gl_vendor), (const char *)glGetString(GL_VENDOR));
    copy_string(out->gl_renderer, sizeof(out->gl_renderer), (const char *)glGetString(GL_RENDERER));
    copy_string(out->gl_version, sizeof(out->gl_version), (const char *)glGetString(GL_VERSION));
    glViewport(0, 0, AETHER_EGL_PROBE_SIZE, AETHER_EGL_PROBE_SIZE);
    glDisable(GL_DITHER);
    glEnable(GL_SCISSOR_TEST);
    const float colors[4][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {1, 1, 1, 1}};
    for (int quadrant = 0; quadrant < 4; ++quadrant) {
        glScissor((quadrant % 2) * 8, (quadrant / 2) * 8, 8, 8);
        glClearColor(colors[quadrant][0], colors[quadrant][1], colors[quadrant][2], colors[quadrant][3]);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_SCISSOR_TEST);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glFinish();
    glReadPixels(0, 0, AETHER_EGL_PROBE_SIZE, AETHER_EGL_PROBE_SIZE, GL_RGBA, GL_UNSIGNED_BYTE, out->pixels);
    CHECK(glGetError() == GL_NO_ERROR, "GLES clear/readback produced an error");
    for (int y = 0; y < 16; ++y) for (int x = 0; x < 16; ++x) {
        int quadrant = (y / 8) * 2 + x / 8;
        CHECK(expect_pixel(out->pixels, x, y, (int)colors[quadrant][0] * 255,
                           (int)colors[quadrant][1] * 255, (int)colors[quadrant][2] * 255, 255),
              "actual pbuffer pixels did not match the four GLES clear colors");
    }
    out->readback_verified = 1;
    CHECK(eglSwapBuffers(display, game_surface), "pbuffer eglSwapBuffers failed");
    CHECK(eglMakeCurrent(display, host_surface, host_surface, host_context), "could not restore host context");
    CHECK(eglGetCurrentContext() == host_context && eglGetCurrentSurface(EGL_DRAW) == host_surface &&
          eglGetCurrentSurface(EGL_READ) == host_surface, "host EGL context/surface restoration mismatch");
    unsigned char check[4] = {0};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, check);
    CHECK(check[0] == 0 && check[1] == 255 && check[2] == 255 && check[3] == 255,
          "game rendering modified the independent host pbuffer");
    out->host_context_restored = 1;
    CHECK(eglMakeCurrent(display, game_surface, game_surface, game_context), "could not resume game context");
    glClearColor(1, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, check);
    CHECK(glGetError() == GL_NO_ERROR && check[0] == 255 && check[1] == 255 && check[2] == 0 && check[3] == 255,
          "resumed game pbuffer did not produce fresh yellow pixels");
    out->resume_verified = 1;
    out->passed = 1;
cleanup:
    if (display != EGL_NO_DISPLAY) {
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (host_context != EGL_NO_CONTEXT) eglDestroyContext(display, host_context);
        if (game_context != EGL_NO_CONTEXT) eglDestroyContext(display, game_context);
        if (host_surface != EGL_NO_SURFACE) eglDestroySurface(display, host_surface);
        if (game_surface != EGL_NO_SURFACE) eglDestroySurface(display, game_surface);
        /* Never terminate a display that could also be owned by a host. */
    }
    eglBindAPI(previous_api);
    if (previous_display != EGL_NO_DISPLAY &&
        !eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context)) {
        out->passed = 0;
        copy_string(out->error, sizeof(out->error), "could not restore pre-probe EGL context");
        out->egl_error = eglGetError();
    }
    return out->passed ? 0 : -1;
#undef CHECK
}
