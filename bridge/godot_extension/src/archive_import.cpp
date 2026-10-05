#include "archive_import.h"

#include "hrd.h"
#include "libarchive_import.h"
#include "sevenzip_import.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace godot {
namespace {

struct HrdApi {
    using AbiVersion = uint32_t (*)();
    using StatusString = const char *(*)(int);
    using CtxCreate = hrd_ctx_t *(*)(const hrd_options_t *);
    using CtxDestroy = void (*)(hrd_ctx_t *);
    using AddPassword = int (*)(hrd_ctx_t *, const char *);
    using Process = int (*)(hrd_ctx_t *, const char *const *, size_t,
                            const char *, char **);
    using Free = void (*)(void *);

    void *handle = nullptr;
    AbiVersion abi_version = nullptr;
    StatusString status_string = nullptr;
    CtxCreate ctx_create = nullptr;
    CtxDestroy ctx_destroy = nullptr;
    AddPassword add_password = nullptr;
    Process process = nullptr;
    Free free_value = nullptr;

    ~HrdApi() {
#if defined(_WIN32)
        if (handle != nullptr) FreeLibrary(static_cast<HMODULE>(handle));
#else
        if (handle != nullptr) dlclose(handle);
#endif
    }

    bool load() {
#if defined(_WIN32)
        char module_path[MAX_PATH] = {};
        HMODULE self = nullptr;
        if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                   GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               reinterpret_cast<LPCSTR>(&ArchiveImportStart),
                               &self) != 0) {
            GetModuleFileNameA(self, module_path, sizeof(module_path));
        }
        std::string sibling_dir(module_path);
        const size_t slash = sibling_dir.find_last_of("\\/");
        if (slash != std::string::npos) sibling_dir.resize(slash + 1);
        const std::vector<std::string> paths = {
            sibling_dir + "hrd.dll", sibling_dir + "libhrd.dll",
            "hrd.dll", "libhrd.dll"};
        for (const std::string &name : paths) {
            handle = static_cast<void *>(LoadLibraryA(name.c_str()));
            if (handle != nullptr) break;
        }
        if (handle == nullptr) return false;
#define HRD_SYM(type, name) reinterpret_cast<type>(GetProcAddress(static_cast<HMODULE>(handle), #name))
#else
        const char *names[] = {"libhrd.dylib", "libhrd.so"};
        for (const char *name : names) {
            handle = dlopen(name, RTLD_NOW | RTLD_LOCAL);
            if (handle != nullptr) break;
        }
        if (handle == nullptr) return false;
#define HRD_SYM(type, name) reinterpret_cast<type>(dlsym(handle, #name))
#endif
        abi_version = HRD_SYM(AbiVersion, hrd_abi_version);
        status_string = HRD_SYM(StatusString, hrd_status_string);
        ctx_create = HRD_SYM(CtxCreate, hrd_ctx_create);
        ctx_destroy = HRD_SYM(CtxDestroy, hrd_ctx_destroy);
        add_password = HRD_SYM(AddPassword, hrd_ctx_add_password);
        process = HRD_SYM(Process, hrd_process);
        free_value = HRD_SYM(Free, hrd_free);
#undef HRD_SYM
        return abi_version != nullptr && ctx_create != nullptr &&
               ctx_destroy != nullptr && add_password != nullptr &&
               process != nullptr && free_value != nullptr &&
               abi_version() >> 16 == 1;
    }
};

struct Job {
    std::mutex mutex;
    bool done = false;
    std::string result;
};

std::mutex jobs_mutex;
std::unordered_map<uint64_t, std::shared_ptr<Job>> jobs;
std::atomic<uint64_t> next_job{1};

std::string JsonEscape(const std::string &value) {
    std::string result;
    result.reserve(value.size() + 8);
    for (const char ch : value) {
        switch (ch) {
        case '\\': result += "\\\\"; break;
        case '"': result += "\\\""; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default: result += ch; break;
        }
    }
    return result;
}

void RunJob(const std::shared_ptr<Job> &job, std::string input,
            std::string output, std::string password_db,
            std::string password) {
    HrdApi api;
    std::string result;
    std::string sevenzip_error;
#if defined(AETHERKIRI_WITH_7ZIP_SDK)
    if (RunSevenZipImport(input, output, password_db, password, sevenzip_error)) {
        result = R"({"status":"ok","backend":"7zip-sdk"})";
    } else
#endif
    {
    std::string libarchive_error;
#if defined(AETHERKIRI_WITH_LIBARCHIVE)
    // Keep one import contract on every native platform.  libarchive handles
    // the common formats everywhere; Windows may still fall through to HRD
    // for disguised carriers, unusual split volumes, and stronger 7-Zip/RAR
    // coverage.
    if (RunLibarchiveImport(input, output, password_db, password,
                            libarchive_error)) {
        result = R"({"status":"ok","backend":"libarchive"})";
    } else
#endif
    if (!api.load()) {
        result = "{\"status\":\"error\",\"code\":3,\"error\":\"" +
                 JsonEscape(!sevenzip_error.empty() ? sevenzip_error :
                            (libarchive_error.empty()
                                ? "No archive backend is available on this build"
                                : libarchive_error)) + "\"}";
    } else {
        hrd_options_t options{};
        options.struct_size = sizeof(options);
        options.max_depth = 8;
        options.max_ratio = 100;
        options.max_total_bytes = 32ull * 1024ull * 1024ull * 1024ull;
        options.overwrite = 0;
        options.interactive = 0;
        options.password_db = password_db.empty() ? nullptr : password_db.c_str();
        options.temp_dir = nullptr;
        hrd_ctx_t *ctx = api.ctx_create(&options);
        if (ctx == nullptr) {
            result = R"({"status":"error","code":9,"error":"Unable to create HRD context"})";
        } else {
            if (!password.empty()) api.add_password(ctx, password.c_str());
            const char *inputs[] = {input.c_str()};
            char *report = nullptr;
            const int status = api.process(ctx, inputs, 1, output.c_str(), &report);
            if (status == HRD_OK) {
                result = R"({"status":"ok","report":)";
                result += report != nullptr ? report : "{}";
                result += "}";
            } else {
                result = "{\"status\":\"error\",\"code\":" +
                         std::to_string(status) + ",\"error\":\"" +
                         JsonEscape(api.status_string != nullptr
                                        ? api.status_string(status)
                                        : "HRD extraction failed") +
                         "\"}";
            }
            if (report != nullptr) api.free_value(report);
            api.ctx_destroy(ctx);
        }
    }
    }
    {
        std::lock_guard<std::mutex> lock(job->mutex);
        job->result = std::move(result);
        job->done = true;
    }
}

uint64_t ParseJobId(const String &id) {
    return static_cast<uint64_t>(id.to_int());
}

} // namespace

String ArchiveImportStart(const String &input_path, const String &output_path,
                          const String &password_db, const String &password) {
    const uint64_t id = next_job.fetch_add(1);
    const auto job = std::make_shared<Job>();
    {
        std::lock_guard<std::mutex> lock(jobs_mutex);
        jobs.emplace(id, job);
    }
    std::thread(RunJob, job, std::string(input_path.utf8().get_data()),
                std::string(output_path.utf8().get_data()),
                std::string(password_db.utf8().get_data()),
                std::string(password.utf8().get_data())).detach();
    return String::num_int64(static_cast<int64_t>(id));
}

String ArchiveImportTakeResult(const String &job_id) {
    const uint64_t id = ParseJobId(job_id);
    std::shared_ptr<Job> job;
    {
        std::lock_guard<std::mutex> lock(jobs_mutex);
        const auto it = jobs.find(id);
        if (it == jobs.end()) return "{\"status\":\"missing\"}";
        job = it->second;
    }
    std::lock_guard<std::mutex> lock(job->mutex);
    if (!job->done) return "{\"status\":\"pending\"}";
    const String result = String::utf8(job->result.c_str());
    std::lock_guard<std::mutex> jobs_lock(jobs_mutex);
    jobs.erase(id);
    return result;
}

} // namespace godot
