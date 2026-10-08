/* Actual SDL2 offscreen integration probe, not a replacement graphics API.
 * Builds against the pinned and patched upstream SDL2.0.20 static library. */
#define SDL_MAIN_HANDLED 1
#include <SDL.h>
#define aether_run_egl_probe aether_run_egl_baseline
#include "egl_probe.c"
#undef aether_run_egl_probe
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>
#include <stdlib.h>
#endif

int aether_run_egl_probe(aether_egl_probe_result *out) {
    if (aether_run_egl_baseline(out)) return -1;
    out->passed = out->pbuffer_created = out->readback_verified = 0;
    out->host_context_restored = out->resume_verified = 0;
    const EGLDisplay previous_display = eglGetCurrentDisplay();
    const EGLContext previous_context = eglGetCurrentContext();
    const EGLSurface previous_draw = eglGetCurrentSurface(EGL_DRAW);
    const EGLSurface previous_read = eglGetCurrentSurface(EGL_READ);
    const EGLenum previous_api = eglQueryAPI();
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface host_surface = EGL_NO_SURFACE;
    EGLContext host_context = EGL_NO_CONTEXT;
    SDL_Window *window = NULL;
    SDL_GLContext context = NULL;
    GLuint host_texture = 0, host_fbo = 0, host_program = 0;
    GLuint host_vertex = 0, host_fragment = 0;
#define SDL_CHECK(condition, message) do { if (!(condition)) { \
    snprintf(out->error, sizeof(out->error), "%s: %s", message, SDL_GetError()); \
    out->egl_error = eglGetError(); out->gl_error = glGetError(); goto cleanup; \
} } while (0)
#ifdef __APPLE__
    CFURLRef frameworks = CFBundleCopyPrivateFrameworksURL(CFBundleGetMainBundle());
    CFURLRef framework = frameworks ? CFURLCreateCopyAppendingPathComponent(
        kCFAllocatorDefault, frameworks, CFSTR("MetalANGLE.framework"), 1) : NULL;
    CFURLRef library = framework ? CFURLCreateCopyAppendingPathComponent(
        kCFAllocatorDefault, framework, CFSTR("MetalANGLE"), 0) : NULL;
    char framework_path[PATH_MAX];
    const int valid = library && CFURLGetFileSystemRepresentation(
        library, 1, (UInt8 *)framework_path, sizeof(framework_path));
    if (library) CFRelease(library);
    if (framework) CFRelease(framework);
    if (frameworks) CFRelease(frameworks);
    SDL_CHECK(valid, "resolve actually embedded MetalANGLE framework");
    SDL_CHECK(!setenv("SDL_VIDEO_GL_DRIVER", framework_path, 1) &&
              !setenv("SDL_VIDEO_EGL_DRIVER", framework_path, 1), "set actual MetalANGLE loader paths");
#endif
    SDL_CHECK(!SDL_setenv("SDL_VIDEODRIVER", "offscreen", 1) &&
              !SDL_setenv("AETHER_RENPY_EMBEDDED", "1", 1), "select embedded offscreen SDL backend");
    SDL_SetMainReady();
    SDL_CHECK(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) == 0, "SDL_Init offscreen");
    SDL_CHECK(SDL_GetCurrentVideoDriver() && !strcmp(SDL_GetCurrentVideoDriver(), "offscreen"),
              "SDL selected a driver other than offscreen");
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 0);
    window = SDL_CreateWindow("Aether RenPy offscreen", 0, 0, 16, 16, SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    SDL_CHECK(window, "SDL_CreateWindow actual offscreen pbuffer");
    context = SDL_GL_CreateContext(window);
    out->client_version = 3;
    if (!context) {
        SDL_ClearError();
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
        context = SDL_GL_CreateContext(window);
        out->client_version = 2;
    }
    SDL_CHECK(context, "SDL_GL_CreateContext");
    display = eglGetCurrentDisplay();
    const EGLSurface game_surface = eglGetCurrentSurface(EGL_DRAW);
    SDL_CHECK(display != EGL_NO_DISPLAY && game_surface != EGL_NO_SURFACE,
              "SDL did not bind an actual EGL pbuffer");
    copy_string(out->gl_vendor, sizeof(out->gl_vendor), (const char *)glGetString(GL_VENDOR));
    copy_string(out->gl_renderer, sizeof(out->gl_renderer), (const char *)glGetString(GL_RENDERER));
    copy_string(out->gl_version, sizeof(out->gl_version), (const char *)glGetString(GL_VERSION));
    /* This actual framework reports ANGLE 850c87ba5b74. Its SurfaceMtl
       getWidth/getHeight return zero until OffscreenSurfaceMtl creates the
       color texture on the first framebuffer attachment operation. Draw to
       the real default framebuffer before querying its allocated dimensions;
       still require the requested size and every RGBA pixel below. */
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, 16, 16);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    SDL_CHECK(glGetError() == GL_NO_ERROR, "initialize actual SDL pbuffer color attachment");
    EGLint width = 0, height = 0;
    const EGLBoolean queried_width = eglQuerySurface(display, game_surface, EGL_WIDTH, &width);
    const EGLint width_error = eglGetError();
    const EGLBoolean queried_height = eglQuerySurface(display, game_surface, EGL_HEIGHT, &height);
    const EGLint height_error = eglGetError();
    if (!queried_width || !queried_height || width != 16 || height != 16) {
        int window_width = 0, window_height = 0, drawable_width = 0, drawable_height = 0;
        SDL_GetWindowSize(window, &window_width, &window_height);
        SDL_GL_GetDrawableSize(window, &drawable_width, &drawable_height);
        snprintf(out->error, sizeof(out->error),
            "SDL pbuffer dimensions: EGL=%dx%d query=%u/%u errors=0x%x/0x%x; window=%dx%d drawable=%dx%d; requested=16x16",
            width, height, queried_width, queried_height, width_error, height_error,
            window_width, window_height, drawable_width, drawable_height);
        out->egl_error = width_error != EGL_SUCCESS ? width_error : height_error;
        out->gl_error = glGetError();
        goto cleanup;
    }
    out->pbuffer_created = 1;
    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE
    };
    EGLConfig config = NULL;
    EGLint count = 0;
    const EGLint surface_attributes[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
    const EGLint context_attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    SDL_CHECK(eglChooseConfig(display, config_attributes, &config, 1, &count) && count == 1,
              "host pbuffer config");
    host_surface = eglCreatePbufferSurface(display, config, surface_attributes);
    host_context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    SDL_CHECK(host_surface != EGL_NO_SURFACE && host_context != EGL_NO_CONTEXT, "host pbuffer/context");
    SDL_CHECK(eglMakeCurrent(display, host_surface, host_surface, host_context), "bind host context");
    glClearColor(0, 1, 1, 1); glClear(GL_COLOR_BUFFER_BIT);
    /* Keep independent host GPU resources alive through the SDL teardown.
       They belong to the same EGLDisplay but do not share a GL context. */
    glGenTextures(1, &host_texture);
    glBindTexture(GL_TEXTURE_2D, host_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &host_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, host_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, host_texture, 0);
    SDL_CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
              "independent host sentinel framebuffer");
    glClearColor(0, 1, 1, 1); glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    const char *vertex_source = "attribute vec4 position; void main() { gl_Position = position; }";
    const char *fragment_source = "precision mediump float; void main() { gl_FragColor = vec4(1.0); }";
    host_vertex = glCreateShader(GL_VERTEX_SHADER);
    host_fragment = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(host_vertex, 1, &vertex_source, NULL);
    glShaderSource(host_fragment, 1, &fragment_source, NULL);
    glCompileShader(host_vertex); glCompileShader(host_fragment);
    GLint compiled_vertex = 0, compiled_fragment = 0, linked = 0;
    glGetShaderiv(host_vertex, GL_COMPILE_STATUS, &compiled_vertex);
    glGetShaderiv(host_fragment, GL_COMPILE_STATUS, &compiled_fragment);
    SDL_CHECK(compiled_vertex && compiled_fragment, "independent host sentinel shaders");
    host_program = glCreateProgram();
    glAttachShader(host_program, host_vertex); glAttachShader(host_program, host_fragment);
    glLinkProgram(host_program);
    glGetProgramiv(host_program, GL_LINK_STATUS, &linked);
    SDL_CHECK(linked && glGetError() == GL_NO_ERROR, "independent host sentinel program");
    /* The host restores Ren'Py's raw EGL context, including after first bind.
       SDL's own current-context cache must not hide this actual switch. */
    SDL_CHECK(eglMakeCurrent(display, game_surface, game_surface, (EGLContext)context), "bind SDL game context");
    glViewport(0, 0, 16, 16); glDisable(GL_DITHER); glEnable(GL_SCISSOR_TEST);
    const float colors[4][4] = {{1,0,0,1}, {0,1,0,1}, {0,0,1,1}, {1,1,1,1}};
    for (int quadrant = 0; quadrant < 4; ++quadrant) {
        glScissor((quadrant % 2) * 8, (quadrant / 2) * 8, 8, 8);
        glClearColor(colors[quadrant][0], colors[quadrant][1], colors[quadrant][2], 1);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_SCISSOR_TEST); glPixelStorei(GL_PACK_ALIGNMENT, 1); glFinish();
    glReadPixels(0, 0, 16, 16, GL_RGBA, GL_UNSIGNED_BYTE, out->pixels);
    SDL_CHECK(glGetError() == GL_NO_ERROR, "SDL pbuffer readback GL error");
    for (int y = 0; y < 16; ++y) for (int x = 0; x < 16; ++x) {
        const int q = (y / 8) * 2 + x / 8;
        SDL_CHECK(expect_pixel(out->pixels, x, y, (int)colors[q][0] * 255,
                  (int)colors[q][1] * 255, (int)colors[q][2] * 255, 255), "SDL pbuffer pixels mismatch");
    }
    out->readback_verified = 1;
    SDL_GL_SwapWindow(window);
    SDL_CHECK(eglMakeCurrent(display, host_surface, host_surface, host_context), "restore host context");
    unsigned char pixel[4] = {0};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    SDL_CHECK(eglGetCurrentContext() == host_context && pixel[0] == 0 && pixel[1] == 255 &&
              pixel[2] == 255 && pixel[3] == 255, "SDL modified independent host rendering");
    out->host_context_restored = 1;
    SDL_CHECK(eglMakeCurrent(display, game_surface, game_surface, (EGLContext)context), "resume SDL game context");
    glClearColor(1, 1, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    SDL_CHECK(glGetError() == GL_NO_ERROR && pixel[0] == 255 && pixel[1] == 255 &&
              pixel[2] == 0 && pixel[3] == 255, "SDL resumed pixels mismatch");
    out->resume_verified = 1;
    SDL_Event event;
    SDL_zero(event); event.type = SDL_MOUSEBUTTONDOWN;
    event.button.button = SDL_BUTTON_LEFT; event.button.state = SDL_PRESSED;
    event.button.x = 7; event.button.y = 9;
    SDL_CHECK(SDL_PushEvent(&event) == 1, "SDL actual pointer press enqueue");
    event.type = SDL_MOUSEBUTTONUP; event.button.state = SDL_RELEASED;
    SDL_CHECK(SDL_PushEvent(&event) == 1, "SDL actual pointer release enqueue");
    SDL_zero(event); event.type = SDL_TEXTINPUT;
    SDL_strlcpy(event.text.text, "\xe8\xa7\xa6\xe6\x8e\xa7", sizeof(event.text.text));
    SDL_CHECK(SDL_PushEvent(&event) == 1, "SDL actual UTF-8 text enqueue");
    int down = 0, up = 0, text = 0;
    while (SDL_PollEvent(&event)) {
        if (event.type == SDL_MOUSEBUTTONDOWN && event.button.x == 7 && event.button.y == 9 &&
            event.button.state == SDL_PRESSED) down = 1;
        if (event.type == SDL_MOUSEBUTTONUP && event.button.state == SDL_RELEASED) up = 1;
        if (event.type == SDL_TEXTINPUT && !strcmp(event.text.text, "\xe8\xa7\xa6\xe6\x8e\xa7")) text = 1;
    }
    SDL_CHECK(down && up && text, "SDL actual pointer/text event delivery mismatch");
    /* Production terminal cleanup must override a conflicting environment
       hint in the private SDL instance without terminating the host display. */
    SDL_CHECK(!SDL_setenv("AETHER_RENPY_EMBEDDED", "0", 1), "set conflicting embedded hint");
    SDL_CHECK(SDL_SetHintWithPriority("AETHER_RENPY_EMBEDDED", "1", SDL_HINT_OVERRIDE) &&
              SDL_GetHintBoolean("AETHER_RENPY_EMBEDDED", SDL_FALSE), "override private SDL display ownership hint");
    SDL_GL_DeleteContext(context); context = NULL;
    SDL_DestroyWindow(window); window = NULL;
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    SDL_CHECK(!(SDL_WasInit(SDL_INIT_VIDEO) & SDL_INIT_VIDEO), "private SDL video remains initialized");
    SDL_CHECK(eglBindAPI(EGL_OPENGL_ES_API) &&
              eglMakeCurrent(display, host_surface, host_surface, host_context),
              "restore independent host after private SDL destruction");
    SDL_CHECK(glIsTexture(host_texture) && glIsFramebuffer(host_fbo) && glIsProgram(host_program),
              "private SDL teardown destroyed host GPU resources");
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    SDL_CHECK(glGetError() == GL_NO_ERROR && pixel[0] == 0 && pixel[1] == 255 &&
              pixel[2] == 255 && pixel[3] == 255, "host pbuffer changed during SDL destruction");
    glBindFramebuffer(GL_FRAMEBUFFER, host_fbo);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    SDL_CHECK(glGetError() == GL_NO_ERROR && pixel[0] == 0 && pixel[1] == 255 &&
              pixel[2] == 255 && pixel[3] == 255, "host framebuffer changed during SDL destruction");
    glClearColor(1, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT); glFinish();
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    SDL_CHECK(glGetError() == GL_NO_ERROR && pixel[0] == 255 && pixel[1] == 0 &&
              pixel[2] == 255 && pixel[3] == 255, "host did not render fresh pixels after SDL destruction");
    out->sdl_terminal_cleanup_verified = 1;
    out->passed = 1;
cleanup:
    if (display != EGL_NO_DISPLAY && host_context != EGL_NO_CONTEXT &&
        eglMakeCurrent(display, host_surface, host_surface, host_context)) {
        if (host_program) glDeleteProgram(host_program);
        if (host_vertex) glDeleteShader(host_vertex);
        if (host_fragment) glDeleteShader(host_fragment);
        if (host_fbo) glDeleteFramebuffers(1, &host_fbo);
        if (host_texture) glDeleteTextures(1, &host_texture);
    }
    if (display != EGL_NO_DISPLAY) eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (context) SDL_GL_DeleteContext(context);
    if (window) SDL_DestroyWindow(window);
    if (display != EGL_NO_DISPLAY) {
        if (host_context != EGL_NO_CONTEXT) eglDestroyContext(display, host_context);
        if (host_surface != EGL_NO_SURFACE) eglDestroySurface(display, host_surface);
    }
    SDL_Quit();
    eglBindAPI(previous_api);
    if (previous_display != EGL_NO_DISPLAY &&
        !eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context)) {
        out->passed = 0;
        copy_string(out->error, sizeof(out->error), "failed to restore pre-SDL EGL context");
    }
    return out->passed ? 0 : -1;
#undef SDL_CHECK
}
