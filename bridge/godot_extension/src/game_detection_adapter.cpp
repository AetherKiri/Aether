#include "game_detection_adapter.h"

#include "aether/game_detection.h"
#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace aether::godot_host {
namespace {

using namespace godot;
namespace detection = aether::game_detection;

String ToGodot(std::string_view value) {
    return String::utf8(value.data(), static_cast<int64_t>(value.size()));
}

std::string ToUtf8(const String &value) {
    const auto utf8 = value.utf8();
    return {utf8.get_data(), static_cast<size_t>(utf8.length())};
}

class GodotFile final : public detection::File {
public:
    explicit GodotFile(const Ref<FileAccess> &file) : file_(file) {}

    uint64_t Size() const override { return file_->get_length(); }

    std::string Read(uint64_t offset, size_t length) override {
        file_->seek(offset);
        const auto buffer = file_->get_buffer(static_cast<int64_t>(length));
        if (buffer.is_empty()) {
            return {};
        }
        return {reinterpret_cast<const char *>(buffer.ptr()), static_cast<size_t>(buffer.size())};
    }

private:
    Ref<FileAccess> file_;
};

class GodotFiles final : public detection::Files {
public:
    bool FileExists(const std::string &path) const override {
        return FileAccess::file_exists(ToGodot(path));
    }

    bool DirectoryExists(const std::string &path) const override {
        return DirAccess::dir_exists_absolute(ToGodot(path));
    }

    std::vector<detection::DirectoryEntry> List(const std::string &path, bool hidden) const override {
        std::vector<detection::DirectoryEntry> entries;
        auto directory = DirAccess::open(ToGodot(path));
        if (directory.is_null()) {
            return entries;
        }
        directory->set_include_hidden(hidden);
        if (directory->list_dir_begin() != OK) {
            return entries;
        }
        for (String name = directory->get_next(); !name.is_empty(); name = directory->get_next()) {
            const bool is_directory = directory->current_is_dir();
            entries.push_back({ToUtf8(name), is_directory, is_directory && directory->is_link(name)});
        }
        directory->list_dir_end();
        return entries;
    }

    std::unique_ptr<detection::File> Open(const std::string &path) const override {
        auto file = FileAccess::open(ToGodot(path), FileAccess::READ);
        if (file.is_null()) {
            return {};
        }
        return std::make_unique<GodotFile>(file);
    }

    std::string Lower(std::string_view value) const override {
        return ToUtf8(ToGodot(value).to_lower());
    }
};

} // namespace

godot::Dictionary InspectGame(const godot::String &path, const godot::String &probe_root) {
    const GodotFiles files;
    auto result = detection::Inspect(files, ToUtf8(path));
    if (!probe_root.is_empty()) {
        detection::ApplyProviderProbes(result, ToUtf8(probe_root));
    }
    PackedStringArray signals;
    for (const auto &signal : result.signals) {
        signals.append(ToGodot(signal));
    }
    Dictionary metadata;
    metadata["engine"] = ToGodot(result.engine);
    metadata["root"] = ToGodot(result.root);
    metadata["signals"] = signals;
    metadata["launchFile"] = ToGodot(result.launch_file);
    metadata["renpyDirectory"] = ToGodot(result.renpy_directory);
    if (result.provider_score > 0) {
        metadata["providerScore"] = result.provider_score;
    }
    return metadata;
}

godot::String InspectSpecialGame(const godot::String &path, const godot::String &runtime) {
    const GodotFiles files;
    const auto utf8 = ToUtf8(path);
    if (runtime == "tyranoscript") {
        return ToGodot(detection::TyranoEntry(files, utf8));
    }
    if (runtime == "renpy") {
        return ToGodot(detection::RenpyDirectory(files, utf8));
    }
    if (runtime == "flash") {
        return ToGodot(detection::InspectFlash(files, utf8).launch_file);
    }
    return {};
}

} // namespace aether::godot_host
