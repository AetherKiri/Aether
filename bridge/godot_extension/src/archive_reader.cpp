#include "archive_import.h"
#include <aetherunzip/error.h>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <limits>
#include <unistd.h>
using namespace godot;

class AetherArchiveReader : public RefCounted {
    GDCLASS(AetherArchiveReader, RefCounted)
    aether::archive::Job job;

    static Dictionary dictionary(const aether::archive::Result &r) {
        Dictionary d;
        d["status"] = r.status;
        d["format"] = String::utf8(r.format.c_str());
        d["destination"] = String::utf8(r.destination.c_str());
        d["game_root"] = String::utf8(r.game_root.c_str());
        Dictionary plan;
        plan["archive_name"] = String::utf8(r.placement.archive_name.c_str());
        plan["common_directory"] = String::utf8(r.placement.common_directory.c_str());
        plan["can_strip"] = r.placement.can_strip;
        plan["smart_subdir"] = String::utf8(r.placement.smart_subdir.c_str());
        plan["single_file"] = String::utf8(r.placement.single_file.c_str());
        plan["has_launcher"] = !r.placement.launcher.empty();
        plan["inner_archive"] = r.placement.inner_archive;
        d["placement"] = plan;
        PackedStringArray parts;
        for (const auto &path : r.members) parts.push_back(String::utf8(path.c_str()));
        d["members"] = parts;
        d["encrypted"] = r.encrypted;
        d["entries"] = static_cast<int64_t>(r.entries);
        d["bytes"] = static_cast<int64_t>(r.bytes);
        d["message"] = r.status < 0 ? String::utf8(aether_unzip_error_message(r.status)) : String();
        return d;
    }

protected:
    static void _bind_methods() {
        ClassDB::bind_static_method("AetherArchiveReader", D_METHOD("is_writable_directory", "path"), &AetherArchiveReader::is_writable_directory);
        ClassDB::bind_method(D_METHOD("inspect", "path", "password"), &AetherArchiveReader::inspect, DEFVAL(""));
        ClassDB::bind_method(D_METHOD("extract_to", "path", "destination", "password", "layout", "conflict", "library"),
                             &AetherArchiveReader::extract_to, DEFVAL("smart"), DEFVAL("keep"), DEFVAL(""));
        ClassDB::bind_method(D_METHOD("copy_provider_file", "uri", "games", "name"), &AetherArchiveReader::copy_provider_file);
        ClassDB::bind_method(D_METHOD("cancel"), &AetherArchiveReader::cancel);
        ClassDB::bind_method(D_METHOD("get_progress"), &AetherArchiveReader::get_progress);
        ClassDB::bind_method(D_METHOD("clean_interrupted", "games"), &AetherArchiveReader::clean_interrupted);
    }
public:
    static bool is_writable_directory(const String &path) {
        const auto directory = path.utf8();
        std::error_code ec;
        return std::filesystem::is_directory(directory.get_data(), ec) && access(directory.get_data(), W_OK | X_OK) == 0;
    }
    Dictionary inspect(const String &path, const String &password) {
        return dictionary(job.inspect(path.utf8().get_data(), password.utf8().get_data()));
    }
    Dictionary extract_to(const String &path, const String &destination, const String &password,
                          const String &layout, const String &conflict, const String &library) {
        return dictionary(job.extract(path.utf8().get_data(), destination.utf8().get_data(), password.utf8().get_data(),
                                      layout.utf8().get_data(), conflict.utf8().get_data(), library.utf8().get_data()));
    }
    Dictionary copy_provider_file(const String &uri, const String &games, const String &name) {
        auto file = FileAccess::open(uri, FileAccess::READ);
        if (file.is_null()) {
            aether::archive::Result result;
            result.status = AU_IO;
            return dictionary(result);
        }
        // Android document providers may report an unknown (signed -1) byte count.
        const auto length = file->get_length();
        const auto known_length = length <= std::numeric_limits<int64_t>::max() ? length : 0;
        return dictionary(job.copy_provider(games.utf8().get_data(), name.utf8().get_data(),
            known_length, [&](uint8_t *buffer, size_t size) -> int64_t {
                const auto count = file->get_buffer(buffer, size);
                const auto error = file->get_error();
                return error == OK || error == ERR_FILE_EOF ? static_cast<int64_t>(count) : -1;
            }));
    }
    void cancel() { job.cancel = true; }
    double get_progress() const { const int n = job.progress.load(); return n < 0 ? -1.0 : n / 1000.0; }
    void clean_interrupted(const String &games) { aether::archive::clean_interrupted(games.utf8().get_data()); }
};

void register_aether_archive_reader() { ClassDB::register_class<AetherArchiveReader>(); }
