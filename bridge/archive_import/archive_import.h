#pragma once

#include "archive_plan.h"
#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace aether::archive {
struct Result {
    int status = 0;
    std::string format;
    std::string destination;
    std::string game_root;
    Placement placement;
    std::vector<std::string> members;
    bool encrypted = false;
    uint64_t entries = 0;
    uint64_t bytes = 0;
};

// Construct a new job for each operation. Only cancel and progress are shared
// between the UI thread and the worker.
struct Job {
    std::atomic<bool> cancel{false};
    std::atomic<int> progress{-1};
    Result copy_provider(const std::string &games, const std::string &name, uint64_t length,
                         const std::function<int64_t(uint8_t *, size_t)> &read);
    Result inspect(const std::string &path, const std::string &password = {});
    Result extract(const std::string &path, const std::string &destination, const std::string &password,
                   const std::string &layout = "smart", const std::string &policy = "keep",
                   const std::string &library = {});
};
void clean_interrupted(const std::string &games);
}
