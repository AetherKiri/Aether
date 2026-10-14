#include "renpy_native.h"
#include <dlfcn.h>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

// No SDK SDL symbols are linked into the Godot extension or shared with its
// own SDL runtime. Xlib uses the same process ABI, including SDL's Display.
namespace {
struct Session {
    unsigned long parent = 0, child = 0;
    void *display = nullptr;
    double rect[4] = {0, 0, 1, 1};
    std::vector<std::string> input;
};
static Session *active;
static void *runtime;
static std::string runtime_path, runtime_error;
static int (*python_run)(const char *);
static void (*set_bounds)(int, int);
static void (*activate_context)();
static std::mutex input_mutex;
struct ContextScope {
    void *display = nullptr, *context = nullptr;
    unsigned long drawable = 0;
    int (*make_current)(void *, unsigned long, void *) = nullptr;
    ContextScope() {
        static void *gl = dlopen("libGL.so.1", RTLD_NOW | RTLD_LOCAL);
        if (gl) {
            auto get_display = reinterpret_cast<void *(*)()>(dlsym(gl, "glXGetCurrentDisplay"));
            auto get_context = reinterpret_cast<void *(*)()>(dlsym(gl, "glXGetCurrentContext"));
            auto get_drawable = reinterpret_cast<unsigned long (*)()>(dlsym(gl, "glXGetCurrentDrawable"));
            make_current = reinterpret_cast<decltype(make_current)>(dlsym(gl, "glXMakeCurrent"));
            if (get_display && get_context && get_drawable) { display = get_display(); context = get_context(); drawable = get_drawable(); }
        }
        if (activate_context) activate_context();
    }
    ~ContextScope() {
        if (make_current && active && active->display)
            make_current(display ? display : active->display, drawable, context);
    }
};

static std::string literal(const std::string &value) {
    std::string result = "'";
    const char *hex = "0123456789abcdef";
    for (unsigned char c : value) {
        if (c == '\\' || c == '\'') { result += '\\'; result += c; }
        else if (c < 32) { result += "\\x"; result += hex[c >> 4]; result += hex[c & 15]; }
        else result += c;
    }
    return result + "'";
}
template<class F> F sdk_symbol(const char *name) { return reinterpret_cast<F>(dlsym(runtime, name)); }
template<class F> F x_symbol(const char *name) {
    static void *x11 = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL);
    return x11 ? reinterpret_cast<F>(dlsym(x11, name)) : nullptr;
}
static void adopt(void *window) {
    if (!active) return;
    struct WMInfo { unsigned char version[3]; unsigned char padding; int subsystem; void *data[32]; } info = {{2, 0, 20}};
    auto wm = sdk_symbol<int (*)(void *, void *)>("SDL_GetWindowWMInfo");
    if (!wm || !wm(window, &info) || info.subsystem != 2) return;
    active->display = info.data[0]; active->child = reinterpret_cast<unsigned long>(info.data[1]);
    auto reparent = x_symbol<int (*)(void *, unsigned long, unsigned long, int, int)>("XReparentWindow");
    auto map = x_symbol<int (*)(void *, unsigned long)>("XMapWindow");
    auto flush = x_symbol<int (*)(void *)>("XFlush");
    if (!reparent || !map || !flush) { active->child = 0; return; }
    reparent(active->display, active->child, active->parent, 0, 0);
    map(active->display, active->child); flush(active->display);
    aether_renpy_native_rect(active, active->rect[0], active->rect[1], active->rect[2], active->rect[3]);
}
}

extern "C" void *aether_renpy_native_open(uint64_t window, const char *sdk, const char *manifest,
    const char *bootstrap, const char *greenlet, char **out_error) {
    if (out_error) *out_error = nullptr;
    auto fail = [&](const std::string &message) -> void * {
        if (out_error) *out_error = strdup(message.c_str());
        if (runtime && runtime_path.empty()) runtime_error = message;
        delete active; active = nullptr; return nullptr;
    };
    if (active) { if (out_error) *out_error = strdup("A Ren'Py session is already open"); return nullptr; }
    active = new Session(); active->parent = window;
    if (!runtime_error.empty()) return fail(runtime_error + "; restart Aether before retrying");
    if (!runtime_path.empty() && runtime_path != sdk) return fail("Restart Aether before selecting another Ren'Py runtime");
    if (!runtime) {
#if defined(__aarch64__)
        const std::string platform = "linux-aarch64";
#else
        const std::string platform = "linux-x86_64";
#endif
        const std::string library = std::string(sdk) + "/lib/py3-" + platform + "/librenpython.so";
        Dl_info own{}; dladdr(reinterpret_cast<void *>(&aether_renpy_native_open), &own);
        const std::string owner = own.dli_fname ? own.dli_fname : "";
        const std::string hook = owner.substr(0, owner.find_last_of('/')) + "/libaether_renpy_sdl_hook.so";
        const std::string previous = getenv("SDL_DYNAMIC_API") ? getenv("SDL_DYNAMIC_API") : "";
        struct RestoreEnvironment {
            std::string value;
            ~RestoreEnvironment() { if (value.empty()) unsetenv("SDL_DYNAMIC_API"); else setenv("SDL_DYNAMIC_API", value.c_str(), 1); }
        } restore{previous};
        setenv("SDL_DYNAMIC_API", hook.c_str(), 1);
        setenv("SDL_VIDEODRIVER", "x11", 1);
        setenv("AETHER_RENPY_NATIVE_LIBRARY", library.c_str(), 1);
        setenv("AETHER_RENPY_NATIVE_ADOPT", std::to_string(reinterpret_cast<uintptr_t>(&adopt)).c_str(), 1);
        setenv("RENPY_PLATFORM", platform.c_str(), 1);
        setenv("PYTHONUTF8", "1", 1);
        int flags = RTLD_NOW | RTLD_GLOBAL;
#ifdef RTLD_DEEPBIND
        flags |= RTLD_DEEPBIND;
#endif
        runtime = dlopen(library.c_str(), flags);
        if (!runtime) {
            const std::string error = dlerror();
            if (previous.empty()) unsetenv("SDL_DYNAMIC_API"); else setenv("SDL_DYNAMIC_API", previous.c_str(), 1);
            return fail(error);
        }
        auto version = sdk_symbol<void (*)(unsigned char *)>("SDL_GetVersion");
        auto initialize = sdk_symbol<void (*)(int)>("Py_InitializeEx");
        auto init = sdk_symbol<void (*)()>("init_librenpy");
        auto set_path = sdk_symbol<void (*)(const wchar_t *)>("Py_SetPath");
        auto decode = sdk_symbol<wchar_t *(*)(const char *, size_t *)>("Py_DecodeLocale");
        auto release = sdk_symbol<void (*)(void *)>("PyMem_RawFree");
        python_run = sdk_symbol<int (*)(const char *)>("PyRun_SimpleString");
        if (!version || !initialize || !init || !set_path || !decode || !release || !python_run)
            return fail("The supplied runtime has an incompatible native API");
        unsigned char sdl[3]; version(sdl);
        if (previous.empty()) unsetenv("SDL_DYNAMIC_API"); else setenv("SDL_DYNAMIC_API", previous.c_str(), 1);
        void *adapter = dlopen(hook.c_str(), RTLD_NOW | RTLD_NOLOAD);
        auto installed = adapter ? reinterpret_cast<bool (*)()>(dlsym(adapter, "aether_renpy_sdl_hook_installed")) : nullptr;
        set_bounds = adapter ? reinterpret_cast<void (*)(int, int)>(dlsym(adapter, "aether_renpy_sdl_bounds")) : nullptr;
        activate_context = adapter ? reinterpret_cast<void (*)()>(dlsym(adapter, "aether_renpy_sdl_activate")) : nullptr;
        if (!installed || !installed() || sdl[0] != 2 || sdl[1] != 0 || sdl[2] != 20)
            return fail("The native adapter requires the Ren'Py 8.5.3 SDL 2.0.20 runtime");
        const std::string path = std::string(sdk) + "/lib/python3.12:" + sdk + "/lib/py3-" + platform;
        wchar_t *wide = decode(path.c_str(), nullptr);
        if (!wide) return fail("Could not decode the runtime path");
        init(); set_path(wide); release(wide); initialize(0); runtime_path = sdk;
    }
    const std::string bridge = bootstrap;
    const std::string script = "import sys;sys.path[:0]=[" + literal(sdk) + "," + literal(greenlet) + "," + literal(bridge.substr(0, bridge.find_last_of('/'))) + "];__import__('embedded').open_session(" + literal(manifest) + ")";
    if (python_run(script.c_str())) return fail("Could not initialize the native Ren'Py host");
    return active;
}
extern "C" bool aether_renpy_native_step(void *handle) {
    if (!handle || handle != active) return false;
    ContextScope context;
    std::string input = "[";
    {
        std::lock_guard<std::mutex> lock(input_mutex);
        for (const auto &event : active->input) { if (input.size() > 1) input += ","; input += event; }
        active->input.clear();
    }
    input += "]";
    return python_run(("__import__('embedded').input_events(__import__('json').loads(" + literal(input) + "));__import__('embedded').step()").c_str()) == 0;
}
extern "C" void aether_renpy_native_input(void *handle, const char *event) {
    std::lock_guard<std::mutex> lock(input_mutex);
    if (handle && handle == active && active->input.size() < 256) active->input.emplace_back(event);
}
extern "C" void aether_renpy_native_close(void *handle) {
    if (!handle || handle != active) return;
    { ContextScope context; python_run("__import__('embedded').close_session()"); }
    delete active; active = nullptr;
}
extern "C" void aether_renpy_native_pause(void *handle, bool paused) {
    if (handle && handle == active) python_run(paused ? "__import__('embedded').pause(True)" : "__import__('embedded').pause(False)");
}
extern "C" bool aether_renpy_native_is_embedded(void *handle) {
    if (!handle || handle != active || !active->child) return false;
    auto query = x_symbol<int (*)(void *, unsigned long, unsigned long *, unsigned long *, unsigned long **, unsigned int *)>("XQueryTree");
    auto release = x_symbol<int (*)(void *)>("XFree");
    unsigned long root = 0, parent = 0, *children = nullptr; unsigned int count = 0;
    const bool valid = query && query(active->display, active->child, &root, &parent, &children, &count);
    if (children && release) release(children);
    return valid && parent == active->parent;
}
extern "C" void aether_renpy_native_rect(void *handle, double x, double y, double width, double height) {
    if (!handle || handle != active) return;
    active->rect[0] = x; active->rect[1] = y; active->rect[2] = width; active->rect[3] = height;
    if (!active->child) return;
    auto geometry = x_symbol<int (*)(void *, unsigned long, unsigned long *, int *, int *, unsigned int *, unsigned int *, unsigned int *, unsigned int *)>("XGetGeometry");
    auto move = x_symbol<int (*)(void *, unsigned long, int, int, unsigned int, unsigned int)>("XMoveResizeWindow");
    unsigned long root = 0; int left = 0, top = 0; unsigned int w = 0, h = 0, border = 0, depth = 0;
    if (!geometry || !move || !geometry(active->display, active->parent, &root, &left, &top, &w, &h, &border, &depth)) return;
    const int game_w = int(width * w), game_h = int(height * h);
    if (game_w <= 0 || game_h <= 0) return;
    if (set_bounds) set_bounds(game_w, game_h);
    move(active->display, active->child, int(x * w), int(y * h), game_w, game_h);
}
