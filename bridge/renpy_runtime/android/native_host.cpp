#include <Python.h>
#include <jni.h>
#include <android/log.h>
#include <condition_variable>
#include <chrono>
#include <deque>
#include <mutex>
#include <string>
#include <vector>
#include <cstdlib>

extern "C" void init_librenpy();
extern "C" PyObject *PyInit_androidembed();
extern "C" PyObject *PyInit__greenlet();
extern "C" int SDL_SetHint(const char *, const char *);
extern "C" void SDL_PumpEvents();

namespace {
struct Request { std::string sdk, manifest, bootstrap; };
std::mutex mutex;
std::condition_variable changed;
std::deque<Request> requests;
std::vector<std::string> input;
std::string error, sdk_root;
bool stopping = false, running = false, closing = false;

std::string utf8(JNIEnv *env, jstring value) {
    if (!value) return {};
    const char *chars = env->GetStringUTFChars(value, nullptr);
    std::string result = chars ? chars : "";
    if (chars) env->ReleaseStringUTFChars(value, chars);
    return result;
}
std::string literal(const std::string &value) {
    std::string result = "'";
    const char *hex = "0123456789abcdef";
    for (unsigned char c : value) {
        if (c == '\\' || c == '\'') { result += '\\'; result += c; }
        else if (c < 32) { result += "\\x"; result += hex[c >> 4]; result += hex[c & 15]; }
        else result += c;
    }
    return result + "'";
}
bool evaluate(const std::string &script) {
    if (!PyRun_SimpleString(script.c_str())) return true;
    std::lock_guard<std::mutex> lock(mutex);
    error = "The native Ren'Py interpreter reported an error; see the session log";
    __android_log_write(ANDROID_LOG_ERROR, "AetherRenpy", error.c_str());
    return false;
}
bool alive(PyObject *module) {
    PyObject *runner = PyObject_GetAttrString(module, "_runner");
    PyObject *dead = runner ? PyObject_GetAttrString(runner, "dead") : nullptr;
    const bool result = dead && PyObject_IsTrue(dead) == 0;
    Py_XDECREF(dead); Py_XDECREF(runner);
    return result;
}
}

// SDL's nativeRunMain sets up JNI for this thread before entering here. Keep
// it alive across games: returning would make the stock SDL Java host finish
// Aether's Activity. Python and every greenlet stay on this same native thread.
extern "C" __attribute__((visibility("default"))) int aether_renpy_android_main(int, char **) {
    bool initialized = false;
    PyObject *module = nullptr;
    while (true) {
        Request request;
        PyThreadState *idle = initialized ? PyEval_SaveThread() : nullptr;
        bool stop;
        {
            std::unique_lock<std::mutex> lock(mutex);
            changed.wait(lock, [] { return stopping || !requests.empty(); });
            stop = stopping;
            if (!stop) {
                request = std::move(requests.front()); requests.pop_front();
                running = true; closing = false; input.clear();
            }
        }
        if (idle) PyEval_RestoreThread(idle);
        if (stop) break;
        if (!initialized) {
            sdk_root = request.sdk;
            setenv("ANDROID_PRIVATE", sdk_root.c_str(), 1);
            setenv("ANDROID_PUBLIC", sdk_root.c_str(), 1);
            setenv("ANDROID_OLD_PUBLIC", sdk_root.c_str(), 1);
            setenv("AETHER_RENPY_EMBEDDED", "1", 1);
            setenv("PYTHONUTF8", "1", 1);
            setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
#if defined(__aarch64__)
            setenv("RENPY_PLATFORM", "android-arm64", 1);
#else
            setenv("RENPY_PLATFORM", "android-x86_64", 1);
#endif
            SDL_SetHint("SDL_ANDROID_BLOCK_ON_PAUSE", "0");
            init_librenpy();
            PyImport_AppendInittab("androidembed", PyInit_androidembed);
            PyImport_AppendInittab("greenlet._greenlet", PyInit__greenlet);
            wchar_t *path = Py_DecodeLocale((sdk_root + "/lib/python3.12").c_str(), nullptr);
            Py_SetPath(path); PyMem_RawFree(path); Py_InitializeEx(0);
            initialized = true;
        }
        const std::string bridge = request.bootstrap.substr(0, request.bootstrap.find_last_of('/'));
        const std::string script = "import sys;sys.path[:0]=[" + literal(request.sdk) + "," + literal(request.sdk + "/lib/python3.12/site-packages") + "," + literal(bridge) + "];__import__('embedded').open_session(" + literal(request.manifest) + ")";
        bool success = evaluate(script);
        if (!module) module = PyImport_ImportModule("embedded");
        while (success && module && alive(module)) {
            bool cancel;
            std::string events = "[";
            {
                std::lock_guard<std::mutex> lock(mutex);
                cancel = stopping || closing;
                for (const auto &value : input) { if (events.size() > 1) events += ","; events += value; }
                input.clear();
            }
            events += "]";
            if (cancel) { evaluate("__import__('embedded').close_session()"); break; }
            success = evaluate("__import__('embedded').input_events(__import__('json').loads(" + literal(events) + "));__import__('embedded').step()");
            Py_BEGIN_ALLOW_THREADS
            {
                std::unique_lock<std::mutex> lock(mutex);
                changed.wait_for(lock, std::chrono::milliseconds(1));
            }
            Py_END_ALLOW_THREADS
        }
        evaluate("__import__('embedded').close_session()");
        { std::lock_guard<std::mutex> lock(mutex); running = false; closing = false; }
    }
    Py_XDECREF(module);
    return 0;
}

extern "C" JNIEXPORT jstring JNICALL Java_org_aether_renpy_RenpyHost_nativeOpen(JNIEnv *env, jclass, jstring sdk, jstring manifest, jstring bootstrap) {
    std::lock_guard<std::mutex> lock(mutex);
    if (stopping || !requests.empty() || (running && !closing))
        return env->NewStringUTF("A Ren'Py session is already running");
    if (!sdk_root.empty() && sdk_root != utf8(env, sdk))
        return env->NewStringUTF("Restart Aether before selecting another Ren'Py runtime");
    error.clear(); requests.push_back({utf8(env, sdk), utf8(env, manifest), utf8(env, bootstrap)});
    changed.notify_all();
    return env->NewStringUTF("");
}
extern "C" JNIEXPORT void JNICALL Java_org_aether_renpy_RenpyHost_nativeClose(JNIEnv *, jclass) {
    std::lock_guard<std::mutex> lock(mutex); closing = true; requests.clear(); input.clear(); changed.notify_all();
}
extern "C" JNIEXPORT void JNICALL Java_org_aether_renpy_RenpyHost_nativeShutdown(JNIEnv *, jclass) {
    std::lock_guard<std::mutex> lock(mutex); stopping = true; changed.notify_all();
}
extern "C" JNIEXPORT void JNICALL Java_org_aether_renpy_RenpyHost_nativeInput(JNIEnv *env, jclass, jstring value) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!closing && input.size() < 256) { input.emplace_back(utf8(env, value)); changed.notify_all(); }
}
extern "C" JNIEXPORT jstring JNICALL Java_org_aether_renpy_RenpyHost_nativeError(JNIEnv *env, jclass) {
    std::lock_guard<std::mutex> lock(mutex); return env->NewStringUTF(error.c_str());
}
