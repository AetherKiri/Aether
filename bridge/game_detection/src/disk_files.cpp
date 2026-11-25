#include "aether/game_detection.h"

#include <filesystem>
#include <fstream>

namespace aether::game_detection {
namespace {

namespace fs = std::filesystem;

class DiskFile final : public File {
public:
    explicit DiskFile(const fs::path &path) : stream_(path, std::ios::binary) {
        stream_.seekg(0, std::ios::end);
        const auto end = stream_.tellg();
        if (end >= 0) {
            size_ = static_cast<uint64_t>(end);
        }
    }

    bool IsOpen() const { return static_cast<bool>(stream_); }
    uint64_t Size() const override { return size_; }

    std::string Read(uint64_t offset, size_t length) override {
        stream_.clear();
        stream_.seekg(static_cast<std::streamoff>(offset));
        std::string buffer(length, '\0');
        stream_.read(buffer.data(), static_cast<std::streamsize>(length));
        buffer.resize(static_cast<size_t>(stream_.gcount()));
        return buffer;
    }

private:
    std::ifstream stream_;
    uint64_t size_ = 0;
};

class DiskFileSystem final : public Files {
public:
    bool FileExists(const std::string &path) const override {
        std::error_code error;
        return fs::is_regular_file(fs::u8path(path), error);
    }

    bool DirectoryExists(const std::string &path) const override {
        std::error_code error;
        return fs::is_directory(fs::u8path(path), error);
    }

    std::vector<DirectoryEntry> List(const std::string &path, bool hidden) const override {
        std::vector<DirectoryEntry> entries;
        std::error_code error;
        for (fs::directory_iterator it(fs::u8path(path), error), end;
             !error && it != end; it.increment(error)) {
            auto name = it->path().filename().u8string();
            if (!hidden && !name.empty() && name.front() == '.') {
                continue;
            }
            std::error_code type_error;
            const bool directory = it->is_directory(type_error);
            const bool link = it->is_symlink(type_error);
            entries.push_back({std::move(name), directory, link});
        }
        return entries;
    }

    std::unique_ptr<File> Open(const std::string &path) const override {
        auto file = std::make_unique<DiskFile>(fs::u8path(path));
        if (!file->IsOpen()) {
            return {};
        }
        return file;
    }
};

} // namespace

const Files &DiskFiles() {
    static const DiskFileSystem files;
    return files;
}

} // namespace aether::game_detection
