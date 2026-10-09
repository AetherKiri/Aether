// Real JNI headers with a controlled function table; this is a protocol test,
// not an Android VM, SDL initialization, or device gameplay test.
#include "renpy_android_host.h"
#include "renpy_mobile_adapter.h"
#include "renpy_mobile_loader.h"
#include "renpy_runtime.h"
#include "engine_runtime_provider.h"

#include <cassert>
#include <chrono>
#include <cstdarg>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <type_traits>
#include <vector>

namespace {
int activity_token, media_token, activity_class_token, bridge_token, throwable_token;
int throwable_class_token, root_token, apk_token, detail_token, generic_method_token;
int bind_token, extract_token, prepare_token, apk_method_token, stop_token, describe_token;
jobject activity = reinterpret_cast<jobject>(&activity_token);
jobject bound_activity;
bool no_activity, no_bridge, no_bind, bind_throws, extraction_throws, prepare_throws;
bool pending_exception, payload_available = true;
bool java_load_fails, java_vm_ready;
int local_refs, python_initializations, bind_count;
std::vector<std::string> calls;
const engine_runtime_provider_v1_t* provider;

jobject Local(jobject value) { if (value) ++local_refs; return value; }
template<typename T> T Object(int* token) { return reinterpret_cast<T>(token); }
jclass FindClass(JNIEnv*, const char* name) {
    assert(std::strcmp(name, "android/app/Activity") == 0 ||
           std::strcmp(name, "org/github/krkr2/aetherkiri/RenPyMobileBridge") == 0);
    return static_cast<jclass>(Local(std::strcmp(name, "android/app/Activity") == 0
        ? Object<jclass>(&activity_class_token) : Object<jclass>(&bridge_token)));
}
jobject NewLocalRef(JNIEnv*, jobject value) { return Local(value); }
void DeleteLocalRef(JNIEnv*, jobject value) { assert(value && local_refs > 0); --local_refs; }
jboolean IsInstanceOf(JNIEnv*, jobject value, jclass klass) {
    assert(klass == Object<jclass>(&activity_class_token));
    return value == activity;
}
jboolean ExceptionCheck(JNIEnv*) { return pending_exception; }
jthrowable ExceptionOccurred(JNIEnv*) {
    return pending_exception ? static_cast<jthrowable>(Local(Object<jthrowable>(&throwable_token))) : nullptr;
}
void ExceptionClear(JNIEnv*) { pending_exception = false; }
jclass GetObjectClass(JNIEnv*, jobject value) {
    assert(value == Object<jthrowable>(&throwable_token));
    return static_cast<jclass>(Local(Object<jclass>(&throwable_class_token)));
}
jmethodID GetMethodID(JNIEnv*, jclass, const char* name, const char* signature) {
    if (std::strcmp(name, "toString") == 0) {
        assert(std::strcmp(signature, "()Ljava/lang/String;") == 0);
        return Object<jmethodID>(&describe_token);
    }
    return Object<jmethodID>(&generic_method_token);
}
jmethodID GetStaticMethodID(JNIEnv*, jclass, const char* name, const char* signature) {
    if (std::strcmp(name, "bindHostActivity") == 0) {
        assert(std::strcmp(signature, "(Landroid/app/Activity;)V") == 0);
        if (no_bind) { pending_exception = true; return nullptr; }
        return Object<jmethodID>(&bind_token);
    }
    if (std::strcmp(name, "preparePrivateRoot") == 0) return Object<jmethodID>(&extract_token);
    if (std::strcmp(name, "prepareRuntime") == 0) return Object<jmethodID>(&prepare_token);
    if (std::strcmp(name, "getApkPath") == 0) return Object<jmethodID>(&apk_method_token);
    if (std::strcmp(name, "stopRuntime") == 0) return Object<jmethodID>(&stop_token);
    return Object<jmethodID>(&generic_method_token);
}
void CallStaticVoidMethodV(JNIEnv*, jclass klass, jmethodID method, va_list args) {
    assert(klass == Object<jclass>(&bridge_token));
    if (method == Object<jmethodID>(&bind_token)) {
        assert(va_arg(args, jobject) == activity); // Never the poisoned media slot.
        calls.push_back("bind");
        if (bind_throws) { pending_exception = true; return; }
        bound_activity = activity; // Simulates Bridge.nativeSetHostActivity's global ref.
        ++bind_count;
    } else if (method == Object<jmethodID>(&prepare_token)) {
        assert(va_arg(args, jint) == 1280 && va_arg(args, jint) == 720);
        calls.push_back("prepare");
        if (prepare_throws) pending_exception = true;
    } else {
        assert(method == Object<jmethodID>(&stop_token));
        calls.push_back("stop");
    }
}
jobject CallStaticObjectMethodV(JNIEnv*, jclass, jmethodID method, va_list) {
    if (method == Object<jmethodID>(&extract_token)) {
        calls.push_back("extract");
        if (extraction_throws) { pending_exception = true; return nullptr; }
        return Local(Object<jstring>(&root_token));
    }
    assert(method == Object<jmethodID>(&apk_method_token));
    calls.push_back("apk");
    return Local(Object<jstring>(&apk_token));
}
jobject CallObjectMethodV(JNIEnv*, jobject, jmethodID method, va_list) {
    assert(method == Object<jmethodID>(&describe_token));
    return Local(Object<jstring>(&detail_token));
}
const char* GetStringUTFChars(JNIEnv*, jstring value, jboolean*) {
    if (value == Object<jstring>(&root_token)) return "/private";
    if (value == Object<jstring>(&apk_token)) return "/app.apk";
    assert(value == Object<jstring>(&detail_token));
    return "java.lang.IllegalStateException: actual fixture Java failure";
}
void ReleaseStringUTFChars(JNIEnv*, jstring, const char*) {}
using FunctionTable = std::remove_const_t<std::remove_pointer_t<decltype(JNIEnv{}.functions)>>;
FunctionTable table{};
JNIEnv env{&table};
jobject ResolveActivity(JNIEnv*) { calls.push_back("get_activity"); return no_activity ? nullptr : Local(activity); }
jclass ResolveClass(JNIEnv*, const char* name) {
    assert(std::strcmp(name, "org/github/krkr2/aetherkiri/RenPyMobileBridge") == 0);
    calls.push_back("app_class_loader");
    return no_bridge ? nullptr : static_cast<jclass>(Local(Object<jclass>(&bridge_token)));
}
bool LoadBridge(std::string* error) {
    calls.push_back("java_load");
    if (java_load_fails) { *error = "Java load failed"; return false; }
    java_vm_ready = true; // Actual JNI_OnLoad owns this step in the app.
    return true;
}
JNIEnv* ResolveEnv() {
    assert(java_vm_ready);
    calls.push_back("jni_env");
    return &env;
}
void CheckClean() { assert(local_refs == 0 && !pending_exception); }
} // namespace

JNIEnv* krkr_GetJNIEnv() { return &env; }
JavaVM* krkr_GetJavaVM() { return Object<JavaVM*>(&activity_token); }
jobject krkr_GetApplicationContext() { return activity; }
jobject krkr_GetHostActivity() { return bound_activity; }
struct ANativeWindow;
ANativeWindow* krkr_GetNativeWindow() { return nullptr; }
extern "C" int32_t ANativeWindow_getWidth(ANativeWindow*) { return 0; }
extern "C" int32_t ANativeWindow_getHeight(ANativeWindow*) { return 0; }
extern "C" void ANativeWindow_release(ANativeWindow*) {}
extern "C" engine_result_t engine_register_runtime_provider(const engine_runtime_provider_v1_t* value) {
    provider = value;
    return ENGINE_RESULT_OK;
}

// Controlled launcher only. Real PrepareRuntime and provider are linked below.
namespace aetherkiri::renpy::mobile {
Launcher::Launcher() = default;
Launcher::~Launcher() = default;
bool Launcher::available() { return payload_available; }
int Launcher::Init(const renpy_mobile_config_t& config, const renpy_mobile_host_t&) {
    assert(bound_activity == activity);
    assert(std::strcmp(config.private_root_utf8, "/private") == 0);
    assert(std::strcmp(config.apk_path_utf8, "/app.apk") == 0);
    assert(std::strcmp(config.argv0_utf8, "/private/main.py") == 0);
    calls.push_back("python_init");
    ++python_initializations;
    initialized_ = true;
    return RENPY_MOBILE_OK;
}
int Launcher::Tick(uint32_t) { calls.push_back("tick"); return RENPY_MOBILE_OK; }
int Launcher::Frame(renpy_mobile_frame_t*) { return RENPY_MOBILE_INVALID_STATE; }
int Launcher::Input(const renpy_mobile_input_t&) { return RENPY_MOBILE_OK; }
int Launcher::Pause() { return RENPY_MOBILE_OK; }
int Launcher::Resume() { return RENPY_MOBILE_OK; }
int Launcher::TextInputState(uint32_t* value) { *value = 0; return RENPY_MOBILE_OK; }
int Launcher::SetSurfaceSize(uint32_t, uint32_t) { return RENPY_MOBILE_OK; }
void Launcher::Shutdown() { initialized_ = false; }
} // namespace aetherkiri::renpy::mobile

int main() {
    table.FindClass = FindClass;
    table.NewLocalRef = NewLocalRef;
    table.DeleteLocalRef = DeleteLocalRef;
    table.IsInstanceOf = IsInstanceOf;
    table.ExceptionCheck = ExceptionCheck;
    table.ExceptionOccurred = ExceptionOccurred;
    table.ExceptionClear = ExceptionClear;
    table.GetObjectClass = GetObjectClass;
    table.GetMethodID = GetMethodID;
    table.GetStaticMethodID = GetStaticMethodID;
    table.CallStaticVoidMethodV = CallStaticVoidMethodV;
    table.CallStaticObjectMethodV = CallStaticObjectMethodV;
    table.CallObjectMethodV = CallObjectMethodV;
    table.GetStringUTFChars = GetStringUTFChars;
    table.ReleaseStringUTFChars = ReleaseStringUTFChars;
    using namespace aetherkiri::renpy::mobile;
    std::string error;
    auto bind = [&] { return BindRenPyAndroidHost(&env, ResolveActivity, ResolveClass, &error); };
    assert(!BindRenPyAndroidHost(nullptr, ResolveActivity, ResolveClass, &error));
    assert(error.find("Android VM") != std::string::npos);
    no_activity = true; assert(!bind()); no_activity = false; CheckClean();
    assert(!RequireAndroidHostActivity(&env, Object<jobject>(&media_token), &error)); CheckClean();
    no_bridge = true; assert(!bind()); no_bridge = false; CheckClean();
    no_bind = true; assert(!bind()); no_bind = false; CheckClean();
    assert(error.find("actual fixture Java failure") != std::string::npos);
    bind_throws = true; assert(!bind()); bind_throws = false; CheckClean();
    assert(bound_activity == nullptr && python_initializations == 0);
    calls.clear();
    java_load_fails = true;
    assert(!PrepareRenPyAndroidHost(LoadBridge, ResolveEnv, ResolveActivity, ResolveClass, &error));
    assert(!java_vm_ready && calls == std::vector<std::string>{"java_load"}); CheckClean();
    java_load_fails = false; calls.clear();
    assert(PrepareRenPyAndroidHost(LoadBridge, ResolveEnv, ResolveActivity, ResolveClass, &error));
    assert(error.empty()); CheckClean();
    assert((calls == std::vector<std::string>{"java_load", "jni_env", "get_activity", "app_class_loader", "bind"}));
    assert(bound_activity == activity && bind_count == 1); // Valid after locals are released.

    aetherkiri::renpy::RegisterRuntimeProvider();
    const auto root = std::filesystem::temp_directory_path() / ("aether-renpy-host-" +
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(root / "game");
    assert(provider->probe(nullptr, nullptr) == 0 && provider->probe(nullptr, "") == 0);
    assert(provider->probe(nullptr, root.string().c_str()) == 0);
    std::ofstream(root / "game" / "unrelated.txt") << "unrelated";
    assert(provider->probe(nullptr, root.string().c_str()) == 0);
    for (const char* name : {"script.rpy", "script.rpyc", "options.rpy"}) {
        std::ofstream(root / "game" / name) << "marker";
        assert(provider->probe(nullptr, root.string().c_str()) == 100);
        payload_available = false;
        assert(provider->probe(nullptr, root.string().c_str()) == 0);
        payload_available = true;
        std::filesystem::remove(root / "game" / name);
    }
    std::ofstream(root / "script.rpy") << "label start: pass";
    assert(provider->probe(nullptr, root.string().c_str()) == 100);
    assert(provider->probe(nullptr, (root / "script.rpy").string().c_str()) == 0);
    engine_runtime_host_v1_t host{};
    host.struct_size = sizeof(host);
    host.reserved_ptr[1] = &media_token; // Actual dispatcher slot belongs to media, never JNI.
    engine_create_desc_t desc{}; desc.struct_size = sizeof(desc);
    void* runtime = nullptr;
    assert(provider->create(nullptr, &host, &desc, &runtime) == ENGINE_RESULT_OK);
    calls.clear();
    assert(provider->open_game(runtime, root.string().c_str(), nullptr) == ENGINE_RESULT_OK);
    assert(python_initializations == 0 && calls.empty()); // Async Open preserves owner-thread initialization.
    bound_activity = nullptr;
    assert(provider->tick(runtime, 16) == ENGINE_RESULT_INVALID_STATE);
    assert(std::strstr(provider->get_last_error(runtime), "Godot Activity"));
    assert(python_initializations == 0 && calls.empty()); CheckClean();
    assert(bind()); calls.clear();
    extraction_throws = true;
    assert(provider->tick(runtime, 16) == ENGINE_RESULT_INTERNAL_ERROR);
    assert(std::strstr(provider->get_last_error(runtime), "actual fixture Java failure"));
    assert(python_initializations == 0 && calls.back() == "extract"); CheckClean();
    extraction_throws = false; prepare_throws = true; calls.clear();
    assert(provider->tick(runtime, 16) == ENGINE_RESULT_INTERNAL_ERROR);
    assert(python_initializations == 0 && calls.back() == "prepare"); CheckClean();
    prepare_throws = false; calls.clear();
    assert(provider->tick(runtime, 16) == ENGINE_RESULT_OK && python_initializations == 1);
    assert((calls == std::vector<std::string>{"bind", "extract", "apk", "prepare", "python_init", "tick"}));
    assert(host.reserved_ptr[1] == &media_token); CheckClean();
    provider->destroy(runtime); CheckClean();
    std::filesystem::remove_all(root);
}
