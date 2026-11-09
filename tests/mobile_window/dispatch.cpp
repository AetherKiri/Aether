#include "engine_api.h"
#include "engine_runtime_provider.h"
#include "engine_legacy_services.h"
#include <cstdlib>
#include <iostream>
#include <stdexcept>

extern "C" const engine_legacy_services_v1_t* engine_stub_legacy_services(void);
namespace {
int recycled = 0, resumed = 0, entered = 0, legacy_created = 0;
bool reject = false, throw_callback = false;
static_assert(sizeof(engine_runtime_provider_v1_t) ==
    offsetof(engine_runtime_provider_v1_t, background_playback) + 3 * sizeof(void*),
    "background capability preserves the provider descriptor ABI size");
void Check(bool yes, const char* why) {
    if (!yes) { std::cerr << why << '\n'; std::exit(1); }
}
engine_runtime_provider_v1_t Provider(const char* id) {
    engine_runtime_provider_v1_t p{};
    p.struct_size = sizeof(p); p.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
    p.runtime_id_utf8 = id; p.display_name_utf8 = id;
    p.probe = [](void*, const char*) { return int32_t(1); };
    p.create = [](void*,const engine_runtime_host_v1_t*,const engine_create_desc_t*,void** out) {
        *out = new int(1); return ENGINE_RESULT_OK;
    };
    p.destroy = [](void* p) { delete static_cast<int*>(p); };
    p.open_game = [](void*,const char*,const char*) { return ENGINE_RESULT_OK; };
    p.tick = [](void*,uint32_t) { return ENGINE_RESULT_OK; };
    p.pause = [](void*) { return ENGINE_RESULT_OK; };
    p.resume = [](void*) { ++resumed; return ENGINE_RESULT_OK; };
    p.background_playback = [](void*,uint32_t mode) {
        if (throw_callback) throw std::runtime_error("fixture callback failure");
        if (mode == ENGINE_BACKGROUND_PLAYBACK_ENTER) ++entered;
        return reject ? ENGINE_RESULT_NOT_SUPPORTED : ENGINE_RESULT_OK;
    };
    return p;
}
engine_handle_t Open(const char* id) {
    engine_create_desc_t desc{};
    desc.struct_size=sizeof(desc); desc.api_version=ENGINE_API_VERSION;
    desc.writable_path_utf8="."; desc.cache_path_utf8=".";
    engine_handle_t h=nullptr;
    Check(engine_create(&desc,&h)==ENGINE_RESULT_OK,"create");
    engine_option_t option{}; option.key_utf8="runtime"; option.value_utf8=id;
    Check(engine_set_option(h,&option)==ENGINE_RESULT_OK,"select provider");
    Check(engine_open_game(h,".",nullptr)==ENGINE_RESULT_OK,"open provider");
    return h;
}
}
int main() {
    auto services = *engine_stub_legacy_services();
    services.create = [](const engine_create_desc_t* desc, engine_handle_t* out) {
        ++legacy_created;
        return engine_stub_legacy_services()->create(desc,out);
    };
    services.activate_audio_session_for_host = [] { return false; };
    services.drain_texture_recycle = [] { ++recycled; };
    Check(engine_install_legacy_services(&services)==ENGINE_RESULT_OK,"install stub services");
    engine_create_desc_t desc{};
    desc.struct_size=sizeof(desc); desc.api_version=ENGINE_API_VERSION;
    desc.writable_path_utf8="."; desc.cache_path_utf8=".";
    engine_handle_t unopened=nullptr;
    Check(engine_create(&desc,&unopened)==ENGINE_RESULT_OK,"create unopened handle");
    Check(engine_background_playback(unopened,0)==ENGINE_RESULT_NOT_SUPPORTED && !legacy_created,
          "capability query must not initialize a renderer");
    engine_destroy(unopened);
    static const auto cpu=Provider("pip-cpu-test");
    static const auto absent=[] { auto p=Provider("pip-absent-test"); p.background_playback=nullptr; return p; }();
    static const auto old=[] { auto p=Provider("pip-old-test"); p.struct_size=offsetof(engine_runtime_provider_v1_t,background_playback); return p; }();
    for (const auto* p:{&cpu,&absent,&old}) Check(engine_register_runtime_provider(p)==ENGINE_RESULT_OK,"register");
    for (const char* id:{"pip-absent-test","pip-old-test","kirikiri"}) {
        auto h=Open(id);
        Check(engine_background_playback(h,ENGINE_BACKGROUND_PLAYBACK_QUERY)==ENGINE_RESULT_NOT_SUPPORTED,"old runtimes stay unsupported");
        engine_destroy(h);
    }
    auto h=Open("pip-cpu-test");
    Check(engine_background_playback(h,99)==ENGINE_RESULT_INVALID_ARGUMENT,"invalid mode");
    Check(engine_background_playback(h,ENGINE_BACKGROUND_PLAYBACK_QUERY)==ENGINE_RESULT_OK && !entered,"query is read only");
    Check(engine_tick(h,16)==ENGINE_RESULT_OK && recycled==1,"foreground recycle");
    throw_callback=true;
    Check(engine_background_playback(h,ENGINE_BACKGROUND_PLAYBACK_ENTER)==ENGINE_RESULT_INTERNAL_ERROR,
          "provider exception contained at C ABI");
    throw_callback=false;
    reject=true;
    Check(engine_background_playback(h,ENGINE_BACKGROUND_PLAYBACK_ENTER)==ENGINE_RESULT_NOT_SUPPORTED,"provider rejection");
    Check(engine_tick(h,16)==ENGINE_RESULT_OK && recycled==2,"failed entry leaves foreground dispatch unchanged");
    reject=false;
    Check(engine_background_playback(h,ENGINE_BACKGROUND_PLAYBACK_ENTER)==ENGINE_RESULT_OK,"enter CPU mode");
    Check(engine_resume(h)==ENGINE_RESULT_OK && resumed==1,"background resume bypasses foreground-only audio activation");
    Check(engine_tick(h,50)==ENGINE_RESULT_OK && recycled==2,"background tick cannot drain GPU resources");
    Check(engine_background_playback(h,ENGINE_BACKGROUND_PLAYBACK_LEAVE)==ENGINE_RESULT_OK,"leave");
    Check(engine_tick(h,16)==ENGINE_RESULT_OK && recycled==3,"foreground recycling restored");
    Check(engine_resume(h)==ENGINE_RESULT_OK && resumed==1,"normal resume still waits for foreground audio activation");
    engine_destroy(h);
    Check(engine_background_playback(h,0)==ENGINE_RESULT_INVALID_ARGUMENT,"destroyed handles rejected");
    std::cout << "MOBILE_DISPATCH_OK\n";
}
