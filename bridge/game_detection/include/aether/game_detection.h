#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace aether::game_detection {

struct DirectoryEntry {
    std::string name;
    bool directory;
    bool symlink;
};

class File {
public:
    virtual ~File() = default;
    virtual uint64_t Size() const = 0;
    virtual std::string Read(uint64_t offset, size_t length) = 0;
};

// A frontend can supply its virtual filesystem. List preserves the order
// used by that filesystem for the old first-file launch hint.
class Files {
public:
    virtual ~Files() = default;
    virtual bool FileExists(const std::string &path) const = 0;
    virtual bool DirectoryExists(const std::string &path) const = 0;
    virtual std::vector<DirectoryEntry> List(const std::string &path, bool hidden) const = 0;
    virtual std::unique_ptr<File> Open(const std::string &path) const = 0;
    virtual std::string Lower(std::string_view text) const;
};

struct Result {
    std::string engine = "kirikiri";
    std::string root;
    std::vector<std::string> signals;
    std::string launch_file;
    std::string renpy_directory;
    // Positive only when an optional Provider changed the fallback result.
    int32_t provider_score = 0;
};

using ProviderProbe = std::function<int32_t(const char *runtime, const char *root)>;

const Files &DiskFiles();

// The visual-novel library and the dedicated Flash library are separate
// contexts. Inspect leaves the visual-novel fallback unchanged for SWF files.
Result Inspect(const Files &files, const std::string &path);
Result InspectFlash(const Files &files, const std::string &path);
std::string TyranoEntry(const Files &files, const std::string &root);
std::string RenpyDirectory(const Files &files, const std::string &root);

void ApplyProviderProbes(Result &result, const std::string &root,
                         const ProviderProbe &probe);
void ApplyProviderProbes(Result &result, const std::string &root);

// Standalone entry point for consumers using ordinary filesystem paths.
Result DetectGame(const std::string &path);

} // namespace aether::game_detection
