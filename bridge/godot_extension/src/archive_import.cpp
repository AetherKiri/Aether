// archive_import.cpp — asynchronous archive import through the
// GalgameExtractor (HRD) host engine.
//
// The HRD engine (packages/GalgameExtractor/cpp) is statically linked into
// the extension together with the cross-platform 7-Zip SDK from the vcpkg
// "7zip" port. libarchive is never involved in this path. The engine owns
// password discovery (user-supplied password, password books, sibling
// README hints), multi-volume assembly, MP4/PNG carrier steg detection, and
// bomb protection; this file only bridges it to Godot as pollable jobs.

#include "archive_import.h"

#include "hrd.h"

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

namespace godot {
namespace {

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
    std::string result;
    hrd_options_t options{};
    options.struct_size = sizeof(options);
    options.max_depth = 8;
    options.max_ratio = 100;
    options.max_total_bytes = 32ull * 1024ull * 1024ull * 1024ull;
    options.overwrite = 0;
    // The need-password callback runs on this worker thread and cannot reach
    // the UI loop; the host retries with an explicit password instead.
    options.interactive = 0;
    options.password_db =
        password_db.empty() ? nullptr : password_db.c_str();
    options.temp_dir = nullptr;

    hrd_ctx_t *ctx = hrd_ctx_create(&options);
    if (ctx == nullptr) {
        result =
            "{\"status\":\"error\",\"code\":9,\"error\":\"Unable to create "
            "the GalgameExtractor context\"}";
    } else {
        if (!password.empty()) hrd_ctx_add_password(ctx, password.c_str());
        const char *inputs[] = {input.c_str()};
        char *report = nullptr;
        const int status = hrd_process(ctx, inputs, 1, output.c_str(), &report);
        if (status == HRD_OK) {
            result = R"({"status":"ok","report":)";
            result += report != nullptr ? report : "{}";
            result += "}";
        } else {
            result = "{\"status\":\"error\",\"code\":" +
                     std::to_string(status) + ",\"error\":\"" +
                     JsonEscape(hrd_status_string(
                         static_cast<hrd_status_t>(status))) +
                     "\"}";
        }
        if (report != nullptr) hrd_free(report);
        hrd_ctx_destroy(ctx);
    }

    std::lock_guard<std::mutex> lock(job->mutex);
    job->result = std::move(result);
    job->done = true;
}

uint64_t ParseJobId(const String &id) {
    return static_cast<uint64_t>(id.to_int());
}

}  // namespace

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

}  // namespace godot
