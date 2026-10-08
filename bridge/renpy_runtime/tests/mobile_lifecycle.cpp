#include "renpy_mobile_launcher.h"
#include <Python.h>

#include <cassert>
#include <cstring>
#include <initializer_list>
#include <thread>

extern "C" PyObject* PyInit__aether_host();
namespace {
int diagnostics;
void Log(void*, int, const char*) { ++diagnostics; }
long PythonLong(const char* expression) {
    PyObject* globals = PyModule_GetDict(PyImport_AddModule("__main__"));
    PyObject* result = PyRun_String(expression, Py_eval_input, globals, globals);
    assert(result);
    const long value = PyLong_AsLong(result);
    Py_DECREF(result);
    return value;
}
}  // namespace

// This exercises the native boundary with a real CPython interpreter and a
// controlled Python module. It is not a Ren'Py game or device acceptance test.
int main() {
    assert(PyImport_AppendInittab("_aether_host", PyInit__aether_host) == 0);
    Py_Initialize();
    assert(PyRun_SimpleString(R"PY(
import sys, types
renpy = types.ModuleType('renpy')
renpy.__path__ = []
sys.modules['renpy'] = renpy
mobile = types.ModuleType('renpy.aether_mobile')
sys.modules['renpy.aether_mobile'] = mobile
mobile._ticks = 0
mobile._stops = 0
mobile._paused = False
mobile._inputs = []
mobile._frame = (bytes([1, 2, 3, 255, 4, 5, 6, 255]), 2, 1, 9)
def start(root, argv0):
    mobile._root, mobile._argv0 = root, argv0
def tick(budget):
    mobile._ticks += 1
    return 'finished' if mobile._ticks >= 3 else 'yield'
def stop():
    mobile._stops += 1
def pause():
    mobile._paused = True
def resume():
    mobile._paused = False
mobile.cooperative_start = start
mobile.cooperative_tick = tick
mobile.cooperative_stop = stop
mobile.cooperative_pause = pause
mobile.cooperative_resume = resume
mobile.cooperative_frame = lambda: mobile._frame
mobile.cooperative_input = lambda event: mobile._inputs.append(dict(event))
mobile.cooperative_text_input_state = lambda: True
mobile.cooperative_set_surface_size = lambda w, h: None
)PY") == 0);
    renpy_mobile_config_t config{};
    config.struct_size = sizeof(config);
    config.abi_version = RENPY_MOBILE_LAUNCHER_ABI_VERSION;
    config.game_root_utf8 = "/project";
    config.private_root_utf8 = "/runtime";
    config.argv0_utf8 = "/runtime/main.py";
    renpy_mobile_host_t host{};
    host.struct_size = sizeof(host);
    host.abi_version = RENPY_MOBILE_LAUNCHER_ABI_VERSION;
    host.log_utf8 = Log;
    assert(renpy_mobile_init(&config, &host) == RENPY_MOBILE_OK);
    std::memset(&host, 0, sizeof(host)); // native must own the callback table.
    assert(PythonLong("mobile._root == '/project'") == 1);
    assert(PythonLong("mobile._ticks") == 0); // init must not execute gameplay.
    assert(renpy_mobile_tick(16) == RENPY_MOBILE_OK);

    renpy_mobile_frame_t frame{};
    frame.struct_size = sizeof(frame);
    assert(renpy_mobile_frame(&frame) == RENPY_MOBILE_OK);
    assert(frame.width == 2 && frame.height == 1 && frame.stride == 8 && frame.serial == 9);
    assert(frame.rgba[0] == 1 && frame.rgba[7] == 255);
    assert(PyRun_SimpleString("mobile._frame = (b'bad', 2, 1, 10)") == 0);
    assert(renpy_mobile_frame(&frame) == RENPY_MOBILE_ERROR);

    char text[] = "\xe4\xbd\xa0\xf0\x9f\x99\x82";
    renpy_mobile_input_t event{};
    event.struct_size = sizeof(event);
    event.type = RENPY_MOBILE_INPUT_TEXT;
    event.text_utf8 = text;
    assert(renpy_mobile_input(&event) == RENPY_MOBILE_OK);
    std::memset(text, 'x', sizeof(text) - 1);
    assert(PythonLong("mobile._inputs[-1]['text'] == '\u4f60\U0001f642'") == 1);
    for (int action : {RENPY_MOBILE_POINTER_DOWN, RENPY_MOBILE_POINTER_MOVE,
                       RENPY_MOBILE_POINTER_UP, RENPY_MOBILE_POINTER_SCROLL}) {
        event.type = RENPY_MOBILE_INPUT_POINTER;
        event.value = action;
        event.text_utf8 = nullptr;
        event.device_id = 7;
        event.code = 3;
        event.delta_y = -2;
        assert(renpy_mobile_input(&event) == RENPY_MOBILE_OK);
    }
    assert(PythonLong("[e['value'] for e in mobile._inputs[-4:]] == [1,2,3,4]") == 1);
    assert(PythonLong("mobile._inputs[-1]['device_id'] == 7 and mobile._inputs[-1]['delta_y'] == -2") == 1);
    uint32_t active = 0;
    assert(renpy_mobile_text_input_state(&active) == RENPY_MOBILE_OK && active == 1);
    assert(renpy_mobile_pause() == RENPY_MOBILE_OK);
    assert(renpy_mobile_tick(16) == RENPY_MOBILE_OK && PythonLong("mobile._ticks") == 1);
    assert(renpy_mobile_resume() == RENPY_MOBILE_OK);
    assert(renpy_mobile_tick(16) == RENPY_MOBILE_OK);
    assert(renpy_mobile_tick(16) == RENPY_MOBILE_FINISHED);
    assert(renpy_mobile_set_surface_size(1280, 720) == RENPY_MOBILE_OK);
    std::thread wrong_thread([&] {
        assert(renpy_mobile_frame(&frame) == RENPY_MOBILE_INVALID_STATE);
    });
    wrong_thread.join();
    assert(diagnostics > 0); // callback remains valid after caller table dies.
    renpy_mobile_shutdown();
    assert(Py_IsInitialized()); // the host owns interpreter/process lifetime.
    assert(PythonLong("mobile._stops") == 1);
    assert(renpy_mobile_tick(16) == RENPY_MOBILE_INVALID_STATE);
    Py_Finalize();
}
