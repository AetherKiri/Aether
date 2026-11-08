#include "mobile_playback.h"
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

namespace {
void Check(bool value, const char* why) {
    if (!value) { std::cerr << why << '\n'; std::exit(1); }
}
struct Runtime {
    bool supported = true, reject_enter = false, reject_tick = false;
    uint32_t delta = 0, reads = 0, ticks = 0;
    engine_frame_desc_t frame{};
    std::vector<std::string> calls;
    Runtime() {
        frame.struct_size = sizeof(frame);
        frame.width = 2; frame.height = 2; frame.stride_bytes = 12;
        frame.pixel_format = ENGINE_PIXEL_FORMAT_RGBA8888;
    }
    engine_handle_t handle() { return reinterpret_cast<engine_handle_t>(this); }
};
Runtime& Get(engine_handle_t handle) { return *reinterpret_cast<Runtime*>(handle); }
}
extern "C" engine_result_t engine_background_playback(engine_handle_t h, uint32_t mode) {
    auto& r = Get(h);
    r.calls.push_back(mode == 0 ? "query" : mode == 1 ? "enter" : "leave");
    return !r.supported ? ENGINE_RESULT_NOT_SUPPORTED :
        mode == 1 && r.reject_enter ? ENGINE_RESULT_INTERNAL_ERROR : ENGINE_RESULT_OK;
}
extern "C" engine_result_t engine_pause(engine_handle_t h) { Get(h).calls.push_back("pause"); return ENGINE_RESULT_OK; }
extern "C" engine_result_t engine_resume(engine_handle_t h) { Get(h).calls.push_back("resume"); return ENGINE_RESULT_OK; }
extern "C" engine_result_t engine_tick(engine_handle_t h, uint32_t delta) {
    auto& r = Get(h); ++r.ticks; r.delta = delta;
    return r.reject_tick ? ENGINE_RESULT_INTERNAL_ERROR : ENGINE_RESULT_OK;
}
extern "C" engine_result_t engine_get_frame_desc(engine_handle_t h, engine_frame_desc_t* out) {
    *out = Get(h).frame; return ENGINE_RESULT_OK;
}
extern "C" engine_result_t engine_read_frame_rgba(engine_handle_t h, void* out, size_t size) {
    ++Get(h).reads; std::memset(out, 0x7b, size); return ENGINE_RESULT_OK;
}
int main() {
    using aetherkiri::MobilePlayback;
    MobilePlayback playback;
    Runtime old; old.supported = false;
    Check(!playback.Bind(old.handle()), "old providers must not run in background");
    Check(old.calls == std::vector<std::string>{"query"}, "capability query must not pause or resume");
    Runtime r;
    Check(playback.Bind(r.handle()) && playback.Supported(), "CPU provider binds");
    bool fresh = true;
    Check(!playback.Advance(.05, fresh) && !fresh && !r.ticks, "no background tick before entry");
    Check(playback.Enter() && playback.Enter(), "idempotent entry");
    Check(r.calls == std::vector<std::string>{"query","pause","enter"}, "pause before changing renderer");
    Check(!playback.Advance(.05, fresh), "entry alone must not start story or audio");
    Check(playback.Play(true), "PiP play resumes runtime");
    Check(playback.Advance(.05, fresh) && fresh && r.delta == 50 && r.reads == 1, "live CPU frame");
    Check(playback.Frame().stride_bytes == 12 && playback.Pixels()[23] == 0x7b, "padded row storage preserved");
    Check(playback.Advance(.05, fresh) && !fresh && r.reads == 1, "unchanged frame still ticks without readback");
    r.frame.width = 1;
    Check(playback.Advance(.05, fresh) && fresh, "resize invalidates frame even when serial is reused");
    Check(playback.Play(false), "PiP pause stops engine");
    auto ticks = r.ticks;
    Check(!playback.Advance(.05, fresh) && r.ticks == ticks, "paused playback cannot advance");
    Check(playback.Play(true) && playback.Advance(99, fresh) && r.delta == 250, "timer stalls are bounded");
    ticks = r.ticks;
    Check(!playback.Advance(std::numeric_limits<double>::quiet_NaN(), fresh) && r.ticks == ticks, "invalid timer delta rejected");
    Check(playback.Advance(.0004, fresh) && playback.Advance(.0004, fresh) &&
          playback.Advance(.0004, fresh) && r.delta == 1, "fractional milliseconds are not lost across frames");
    r.frame.stride_bytes = 3;
    Check(!playback.Advance(.05, fresh), "short stride rejected");
    r.frame.stride_bytes = UINT32_MAX;
    Check(!playback.Advance(.05, fresh), "unbounded allocation rejected");
    r.frame.stride_bytes = 12; r.frame.width = 9000;
    Check(!playback.Advance(.05, fresh), "invalid width rejected");
    r.frame.width = 2; r.reject_tick = true;
    Check(!playback.Advance(.05, fresh), "engine termination is returned to host");
    Check(playback.Restore(), "foreground restore");
    Check(r.calls[r.calls.size()-3] == "pause" && r.calls[r.calls.size()-2] == "leave" && r.calls.back() == "resume", "restore order");
    playback.Unbind(); ticks = r.ticks;
    Check(!playback.Advance(.05, fresh) && r.ticks == ticks, "detached engine is never touched");
    Runtime failed; failed.reject_enter = true;
    Check(playback.Bind(failed.handle()) && !playback.Enter(), "failed migration remains paused");
    Check(!playback.Play(true), "failed migration cannot resume in background");
    Check(playback.Restore() && failed.calls.back() == "resume", "failed migration restores on foreground return");
    playback.Unbind();
    Runtime closing;
    Check(playback.Bind(closing.handle()) && playback.Enter() && playback.Play(true), "start teardown fixture");
    const auto before_close = closing.calls.size();
    playback.Unbind(false);
    Check(closing.calls.size() == before_close + 1 && closing.calls.back() == "pause",
          "background teardown cannot restore GPU mode or resume audio");
    std::cout << "MOBILE_PLAYBACK_OK\n";
}
