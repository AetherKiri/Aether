/* In-process lifecycle for the patched Ren'Py launcher. Rendering and events
 * remain on Ren'Py's owning thread inside its stackful cooperative loop.
 * OpenGL windows have no SDL software surface: cooperative_frame reads the
 * renderer's screenshot before yielding to Godot. */
#include <Python.h>
#include <limits.h>
#include <string.h>
#include "renpy_mobile_launcher.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__ANDROID__) || (defined(__APPLE__) && TARGET_OS_IPHONE && defined(METALANGLE))
#define AETHER_MOBILE_EGL 1
#include <EGL/egl.h>
#endif

static renpy_mobile_host_t aether_host;
static PyObject *aether_main_module;
static PyObject *aether_frame_bytes;
static unsigned long aether_owner_thread;
static int aether_started;
static int aether_paused;
static void *aether_window;
#if defined(AETHER_MOBILE_EGL)
static EGLDisplay aether_display = EGL_NO_DISPLAY;
static EGLContext aether_context = EGL_NO_CONTEXT;
static EGLSurface aether_draw_surface = EGL_NO_SURFACE;
static EGLSurface aether_read_surface = EGL_NO_SURFACE;
typedef struct graphics_scope {
    EGLDisplay display;
    EGLContext context;
    EGLSurface draw_surface;
    EGLSurface read_surface;
    EGLenum api;
} graphics_scope;
static int begin_graphics(graphics_scope *scope) {
    scope->display = eglGetCurrentDisplay();
    scope->context = eglGetCurrentContext();
    scope->draw_surface = eglGetCurrentSurface(EGL_DRAW);
    scope->read_surface = eglGetCurrentSurface(EGL_READ);
    scope->api = eglQueryAPI();
    if (aether_context != EGL_NO_CONTEXT) {
        eglBindAPI(EGL_OPENGL_ES_API);
        if (!eglMakeCurrent(aether_display, aether_draw_surface, aether_read_surface, aether_context)) {
            eglBindAPI(scope->api);
            return RENPY_MOBILE_ERROR;
        }
    }
    return RENPY_MOBILE_OK;
}
static int end_graphics(const graphics_scope *scope) {
    EGLBoolean restored = EGL_TRUE;
    if (scope->display != EGL_NO_DISPLAY) {
        eglBindAPI(scope->api);
        restored = eglMakeCurrent(scope->display, scope->draw_surface, scope->read_surface, scope->context);
    } else {
        EGLDisplay display = aether_display != EGL_NO_DISPLAY ? aether_display : eglGetCurrentDisplay();
        if (display != EGL_NO_DISPLAY) restored = eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglBindAPI(scope->api);
    }
    if (!restored && aether_host.log_utf8) aether_host.log_utf8(aether_host.user_data, 3,
        "Ren'Py failed to restore the host EGL context after a lifecycle call");
    return restored ? RENPY_MOBILE_OK : RENPY_MOBILE_ERROR;
}
#else
typedef struct graphics_scope { int unused; } graphics_scope;
static int begin_graphics(graphics_scope *scope) { (void)scope; return RENPY_MOBILE_OK; }
static int end_graphics(const graphics_scope *scope) { (void)scope; return RENPY_MOBILE_OK; }
#endif

int renpy_mobile_bind_window(void *window) {
    if (PyThread_get_thread_ident() != aether_owner_thread) return RENPY_MOBILE_INVALID_ARGUMENT;
    aether_window = window;
#if defined(AETHER_MOBILE_EGL)
    if (!window) {
        aether_display = EGL_NO_DISPLAY;
        aether_context = EGL_NO_CONTEXT;
        aether_draw_surface = EGL_NO_SURFACE;
        aether_read_surface = EGL_NO_SURFACE;
        return RENPY_MOBILE_OK;
    }
    aether_display = eglGetCurrentDisplay();
    aether_context = eglGetCurrentContext();
    aether_draw_surface = eglGetCurrentSurface(EGL_DRAW);
    aether_read_surface = eglGetCurrentSurface(EGL_READ);
    if (aether_display == EGL_NO_DISPLAY || aether_context == EGL_NO_CONTEXT ||
        aether_draw_surface == EGL_NO_SURFACE) return RENPY_MOBILE_INVALID_STATE;
#endif
    return RENPY_MOBILE_OK;
}

static PyObject *host_bind_window(PyObject *self, PyObject *args) {
    unsigned long long pointer;
    (void)self;
    if (!PyArg_ParseTuple(args, "K", &pointer)) return NULL;
    return PyLong_FromLong(renpy_mobile_bind_window((void *)(uintptr_t)pointer));
}
static PyMethodDef host_methods[] = {
    {"bind_window", host_bind_window, METH_VARARGS, "Bind the actual offscreen Ren'Py renderer window."},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef host_module = {
    PyModuleDef_HEAD_INIT, "_aether_host", NULL, -1, host_methods,
    NULL, NULL, NULL, NULL
};
PyMODINIT_FUNC PyInit__aether_host(void) { return PyModule_Create(&host_module); }

static void report_python_error(const char *operation) {
    PyObject *type = NULL, *value = NULL, *traceback = NULL;
    PyErr_Fetch(&type, &value, &traceback);
    PyErr_NormalizeException(&type, &value, &traceback);
    PyObject *text = value ? PyObject_Str(value) : NULL;
    const char *detail = text ? PyUnicode_AsUTF8(text) : NULL;
    if (aether_host.log_utf8) {
        aether_host.log_utf8(aether_host.user_data, 3, operation);
        if (detail) aether_host.log_utf8(aether_host.user_data, 3, detail);
    }
    Py_XDECREF(text);
    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(traceback);
    PyErr_Clear();
}

static int check_owner(void) {
    if (!aether_started || !Py_IsInitialized()) return RENPY_MOBILE_INVALID_STATE;
    if (PyThread_get_thread_ident() != aether_owner_thread) {
        if (aether_host.log_utf8) aether_host.log_utf8(aether_host.user_data, 3,
            "Ren'Py lifecycle called from a different thread than init");
        return RENPY_MOBILE_INVALID_STATE;
    }
    return RENPY_MOBILE_OK;
}

static int call_noargs(const char *name) {
    int status = check_owner();
    if (status != RENPY_MOBILE_OK) return status;
    graphics_scope graphics;
    status = begin_graphics(&graphics);
    if (status != RENPY_MOBILE_OK) return status;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *value = PyObject_CallMethod(aether_main_module, name, NULL);
    if (!value) { report_python_error(name); status = RENPY_MOBILE_ERROR; }
    Py_XDECREF(value);
    PyGILState_Release(gil);
    if (end_graphics(&graphics) != RENPY_MOBILE_OK) status = RENPY_MOBILE_ERROR;
    return status;
}

int renpy_mobile_init(const renpy_mobile_config_t *config,
                      const renpy_mobile_host_t *host) {
    if (!config || !host || config->struct_size < sizeof(*config) ||
        host->struct_size < sizeof(*host) ||
        config->abi_version != RENPY_MOBILE_LAUNCHER_ABI_VERSION ||
        host->abi_version != RENPY_MOBILE_LAUNCHER_ABI_VERSION ||
        !config->game_root_utf8 || !config->game_root_utf8[0]) return RENPY_MOBILE_INVALID_ARGUMENT;
    if (aether_started) return RENPY_MOBILE_INVALID_STATE;
    if (!Py_IsInitialized()) return RENPY_MOBILE_INVALID_STATE;
#if defined(__APPLE__) && TARGET_OS_IPHONE
    if (host->log_utf8) host->log_utf8(host->user_data, 3,
        "Ren'Py iOS rendering requires a verified host-isolated MetalANGLE backend; stock SDL UIKit windows are disabled");
    return RENPY_MOBILE_NOT_IMPLEMENTED;
#endif

    /* The caller is allowed to pass a temporary callback table. */
    aether_host = *host;
    PyGILState_STATE gil = PyGILState_Ensure();
    aether_main_module = PyImport_ImportModule("renpy.aether_mobile");
    PyObject *started = NULL;
    if (aether_main_module) started = PyObject_CallMethod(aether_main_module,
        "cooperative_start", "ss", config->game_root_utf8,
        config->argv0_utf8 ? config->argv0_utf8 : "AetherKiri");
    if (!started) {
        report_python_error("Ren'Py cooperative initialization failed");
        Py_CLEAR(aether_main_module);
        memset(&aether_host, 0, sizeof(aether_host));
        PyGILState_Release(gil);
        return RENPY_MOBILE_ERROR;
    }
    Py_DECREF(started);
    aether_owner_thread = PyThread_get_thread_ident();
    aether_started = 1;
    aether_paused = 0;
    PyGILState_Release(gil);
    return RENPY_MOBILE_OK;
}

int renpy_mobile_tick(uint32_t budget_ms) {
    int status = check_owner();
    if (status != RENPY_MOBILE_OK || aether_paused) return status;
    graphics_scope graphics;
    status = begin_graphics(&graphics);
    if (status != RENPY_MOBILE_OK) return status;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *result = PyObject_CallMethod(aether_main_module, "cooperative_tick", "I", budget_ms);
    if (!result) { report_python_error("Ren'Py cooperative tick failed"); status = RENPY_MOBILE_ERROR; }
    else if (PyUnicode_Check(result)) {
        const char *value = PyUnicode_AsUTF8(result);
        if (!value || !strcmp(value, "not_started")) status = RENPY_MOBILE_INVALID_STATE;
        else if (!strcmp(value, "finished")) status = RENPY_MOBILE_FINISHED;
        else if (strcmp(value, "yield")) status = RENPY_MOBILE_ERROR;
    } else status = RENPY_MOBILE_ERROR;
    Py_XDECREF(result);
    PyGILState_Release(gil);
    if (end_graphics(&graphics) != RENPY_MOBILE_OK) status = RENPY_MOBILE_ERROR;
    return status;
}

int renpy_mobile_frame(renpy_mobile_frame_t *out_frame) {
    if (!out_frame || out_frame->struct_size < sizeof(*out_frame)) return RENPY_MOBILE_INVALID_ARGUMENT;
    int status = check_owner();
    if (status != RENPY_MOBILE_OK) return status;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *frame = PyObject_CallMethod(aether_main_module, "cooperative_frame", NULL);
    if (!frame) { report_python_error("Ren'Py renderer screenshot failed"); status = RENPY_MOBILE_ERROR; }
    else if (frame == Py_None) status = RENPY_MOBILE_INVALID_STATE;
    else {
        PyObject *pixels = NULL;
        unsigned int width = 0, height = 0;
        unsigned long long serial = 0;
        if (!PyArg_ParseTuple(frame, "OIIK", &pixels, &width, &height, &serial) ||
            !PyBytes_Check(pixels) || !width || !height || width > UINT32_MAX / 4u ||
            (uint64_t)width * height * 4u > (uint64_t)PY_SSIZE_T_MAX ||
            PyBytes_GET_SIZE(pixels) != (Py_ssize_t)((uint64_t)width * height * 4u)) {
            PyErr_Clear(); status = RENPY_MOBILE_ERROR;
        } else {
            Py_INCREF(pixels);
            Py_XSETREF(aether_frame_bytes, pixels);
            out_frame->rgba = (const uint8_t *)PyBytes_AS_STRING(aether_frame_bytes);
            out_frame->width = width;
            out_frame->height = height;
            out_frame->stride = width * 4u;
            out_frame->serial = serial;
        }
    }
    Py_XDECREF(frame);
    PyGILState_Release(gil);
    return status;
}

int renpy_mobile_input(const renpy_mobile_input_t *event) {
    if (!event || event->struct_size < sizeof(*event)) return RENPY_MOBILE_INVALID_ARGUMENT;
    int status = check_owner();
    if (status != RENPY_MOBILE_OK) return status;
    PyGILState_STATE gil = PyGILState_Ensure();
    /* Python owns text before control can yield, unlike a borrowed SDL3
     * text-event pointer. Event kinds retain press/release/scroll semantics. */
    PyObject *input = Py_BuildValue("{s:I,s:i,s:i,s:i,s:f,s:f,s:f,s:f,s:I,s:I,s:s,s:K}",
        "type", event->type, "value", event->value, "device_id", event->device_id,
        "code", event->code, "x", event->x, "y", event->y,
        "delta_x", event->delta_x, "delta_y", event->delta_y,
        "modifiers", event->modifiers, "repeat", event->repeat,
        "text", event->text_utf8 ? event->text_utf8 : "",
        "timestamp_ns", (unsigned long long)event->timestamp_ns);
    PyObject *result = input ? PyObject_CallMethod(aether_main_module, "cooperative_input", "O", input) : NULL;
    if (!result) { report_python_error("Ren'Py input delivery failed"); status = RENPY_MOBILE_ERROR; }
    Py_XDECREF(result);
    Py_XDECREF(input);
    PyGILState_Release(gil);
    return status;
}

int renpy_mobile_pause(void) {
    int status = call_noargs("cooperative_pause");
    if (status == RENPY_MOBILE_OK) aether_paused = 1;
    return status;
}

int renpy_mobile_resume(void) {
    int status = call_noargs("cooperative_resume");
    if (status == RENPY_MOBILE_OK) aether_paused = 0;
    return status;
}

int renpy_mobile_text_input_state(uint32_t *active) {
    if (!active) return RENPY_MOBILE_INVALID_ARGUMENT;
    int status = check_owner();
    if (status != RENPY_MOBILE_OK) return status;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *result = PyObject_CallMethod(aether_main_module, "cooperative_text_input_state", NULL);
    if (!result) { report_python_error("Ren'Py text input state failed"); status = RENPY_MOBILE_ERROR; }
    else {
        int truth = PyObject_IsTrue(result);
        if (truth < 0) { report_python_error("Ren'Py text input state failed"); status = RENPY_MOBILE_ERROR; }
        else *active = truth ? 1u : 0u;
    }
    Py_XDECREF(result);
    PyGILState_Release(gil);
    return status;
}

int renpy_mobile_set_surface_size(uint32_t width, uint32_t height) {
    if (!width || !height) return RENPY_MOBILE_INVALID_ARGUMENT;
    int status = check_owner();
    if (status != RENPY_MOBILE_OK) return status;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *result = PyObject_CallMethod(aether_main_module, "cooperative_set_surface_size", "II", width, height);
    if (!result) { report_python_error("Ren'Py surface resize failed"); status = RENPY_MOBILE_ERROR; }
    Py_XDECREF(result);
    PyGILState_Release(gil);
    return status;
}

void renpy_mobile_shutdown(void) {
    if (!aether_started) return;
    if (check_owner() != RENPY_MOBILE_OK) {
        // Destruction on the wrong thread cannot switch a greenlet, but must
        // never retain callbacks whose user_data is about to be destroyed.
        memset(&aether_host, 0, sizeof(aether_host));
        return;
    }
    (void)call_noargs("cooperative_stop");
    PyGILState_STATE gil = PyGILState_Ensure();
    Py_CLEAR(aether_frame_bytes);
    Py_CLEAR(aether_main_module);
    memset(&aether_host, 0, sizeof(aether_host));
    aether_started = 0;
    aether_paused = 0;
    aether_owner_thread = 0;
    aether_window = NULL;
#if defined(__ANDROID__)
    aether_display = EGL_NO_DISPLAY;
    aether_context = EGL_NO_CONTEXT;
    aether_draw_surface = EGL_NO_SURFACE;
    aether_read_surface = EGL_NO_SURFACE;
#endif
    PyGILState_Release(gil);
}
