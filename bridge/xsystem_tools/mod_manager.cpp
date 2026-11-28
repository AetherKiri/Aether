#include "mod_manager.h"
#include <archive.h>
#include <archive_entry.h>
#include <nlohmann/json.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>
#include <vector>
#ifdef __APPLE__
#include <sys/clonefile.h>
#endif
#ifdef _WIN32
#include <windows.h>
#endif

namespace aether::xsystem {
namespace {
namespace fs = std::filesystem;
using Json = nlohmann::json;
constexpr auto store_name = ".aether-mods";
constexpr uint64_t max_bytes = 100ull * 1024 * 1024 * 1024;
constexpr size_t max_files = 100000;
std::mutex operation_mutex;
std::atomic<unsigned> sequence{0};
struct Failure : std::runtime_error {
    std::string code;
    Failure(std::string c, const std::string &detail = {})
        : std::runtime_error(detail), code(std::move(c)) {}
};
std::string lower(std::string value) {
    for (char &c : value)
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}
bool path_exists(const fs::path &path) { return fs::exists(fs::symlink_status(path)); }
std::string relative_name(const fs::path &path) { return path.generic_u8string(); }
fs::path relative_path(const std::string &raw) {
    if (raw.empty() || raw.front() == '/' || raw.front() == '\\' ||
        raw.find(':') != raw.npos || raw.find('\0') != raw.npos)
        throw Failure("unsafe_path", raw);
    std::string name = raw;
    std::replace(name.begin(), name.end(), '\\', '/');
    fs::path result;
    size_t start = 0;
    while (start < name.size()) {
        auto end = name.find('/', start);
        auto part = name.substr(start, end == name.npos ? name.size() - start : end - start);
        if (part.empty() || part == "." || part == "..")
            throw Failure("unsafe_path", raw);
        result /= fs::u8path(part);
        if (end == name.npos) break;
        start = end + 1;
    }
    if (result.empty()) throw Failure("unsafe_path", raw);
    return result;
}
fs::path checked(const fs::path &root, const fs::path &relative) {
    relative_path(relative_name(relative));
    fs::path current = root;
    if (fs::is_symlink(fs::symlink_status(root))) throw Failure("unsafe_path", root.u8string());
    for (const auto &part : relative) {
        current /= part;
        if (fs::is_symlink(fs::symlink_status(current)))
            throw Failure("unsafe_path", current.u8string());
    }
    return current;
}
bool protected_path(const fs::path &path) {
    for (const auto &part : path) {
        auto name = lower(part.u8string());
        if (name.empty() || name.front() == '.' || name == "__macosx" ||
            name == "save" || name == "saves" || name.find("savedata") != name.npos ||
            name == "savefolder" || name == "savedir" || name == "directx")
            return true;
    }
    auto ext = lower(path.extension().u8string());
    static const std::set<std::string> skip = {
        ".sav", ".save", ".asd", ".asdd", ".gds", ".s39", ".bak",
        ".dll", ".exe", ".lnk", ".bat", ".cmd", ".ps1", ".torrent"
    };
    return skip.count(ext) || lower(path.filename().u8string()) == "thumbs.db";
}
bool asset(const fs::path &path) {
    static const std::set<std::string> extensions = {
        ".ain", ".afa", ".ald", ".ex", ".fnl", ".bgi", ".wai",
        ".acx", ".pact", ".pms", ".qnt", ".png", ".webp", ".ogg", ".ttf", ".otf"
    };
    return extensions.count(lower(path.extension().u8string())) != 0;
}
std::set<std::string> save_folders(const fs::path &game) {
    std::set<std::string> folders;
    auto trim = [](std::string value) {
        auto first = value.find_first_not_of(" \t\r\n\"");
        return first == value.npos ? std::string() : value.substr(first, value.find_last_not_of(" \t\r\n\"") - first + 1);
    };
    for (const auto &entry : fs::directory_iterator(game)) {
        if (lower(entry.path().extension().u8string()) != ".ini" ||
            entry.is_symlink() || !entry.is_regular_file() || entry.file_size() > 1024 * 1024) continue;
        std::ifstream stream(entry.path(), std::ios::binary);
        std::string line;
        while (std::getline(stream, line)) {
            auto separator = line.find('=');
            if (separator == line.npos) continue;
            auto key = lower(trim(line.substr(0, separator)));
            if (key != "savefolder" && key != "savedir") continue;
            auto value = trim(line.substr(separator + 1));
            if (value.empty() || value == ".") continue;
            try { folders.insert(lower(relative_name(relative_path(value)))); }
            catch (const Failure &) { /* An external save directory is never a MOD target. */ }
        }
    }
    return folders;
}
bool within_save_folder(const fs::path &path, const std::set<std::string> &folders) {
    auto name = lower(relative_name(path));
    for (const auto &folder : folders)
        if (name == folder || name.compare(0, folder.size() + 1, folder + "/") == 0) return true;
    return false;
}
void replace(const fs::path &source, const fs::path &destination) {
#ifdef _WIN32
    if (!MoveFileExW(source.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        throw Failure("write_failed", destination.u8string());
#else
    fs::rename(source, destination);
#endif
}
void copy_contents(const fs::path &source, const fs::path &destination) {
    fs::create_directories(destination.parent_path());
    if (!fs::is_regular_file(source) || fs::is_symlink(fs::symlink_status(source)))
        throw Failure("unsafe_path", source.u8string());
    fs::remove(destination);
#ifdef __APPLE__
    if (clonefile(source.c_str(), destination.c_str(), 0) == 0) return;
#endif
    fs::copy_file(source, destination);
}
void publish(const fs::path &source, const fs::path &destination, const fs::path &temporary) {
    if (path_exists(destination) && !fs::is_regular_file(destination))
        throw Failure("file_conflict", destination.u8string());
    copy_contents(source, temporary);
    replace(temporary, destination);
}
Json read_json(const fs::path &file) {
    if (fs::file_size(file) > 32 * 1024 * 1024) throw Failure("invalid_manifest");
    std::ifstream stream(file, std::ios::binary);
    auto value = Json::parse(stream, nullptr, false);
    if (!value.is_object()) throw Failure("invalid_manifest");
    return value;
}
void write_json(const fs::path &file, const Json &value) {
    auto temporary = file;
    temporary += ".tmp";
    if (fs::is_symlink(fs::symlink_status(temporary))) throw Failure("unsafe_path");
    std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
    stream << value.dump(2);
    stream.flush();
    if (!stream) throw Failure("write_failed", file.u8string());
    stream.close();
    replace(temporary, file);
}
bool valid_id(const std::string &id) {
    return !id.empty() && id.size() <= 64 &&
        id.find_first_not_of("0123456789-") == id.npos;
}
Json empty_manifest() { return {{"version", 1}, {"mods", Json::array()}, {"base", Json::object()}}; }
void validate_manifest(const Json &manifest) {
    if (manifest.value("version", 0) != 1 || !manifest.contains("mods") ||
        !manifest["mods"].is_array() || !manifest.contains("base") || !manifest["base"].is_object())
        throw Failure("invalid_manifest");
    std::set<std::string> ids;
    for (const auto &mod : manifest["mods"]) {
        if (!mod.is_object() || !valid_id(mod.value("id", "")) ||
            !mod.contains("files") || !mod["files"].is_array() ||
            !ids.insert(mod.value("id", "")).second ||
            mod["files"].size() > max_files) throw Failure("invalid_manifest");
        std::set<std::string> files;
        for (const auto &name : mod["files"]) {
            auto path = relative_path(name.get<std::string>());
            if (protected_path(path) || !manifest["base"].contains(name.get<std::string>()) ||
                !files.insert(lower(name.get<std::string>())).second)
                throw Failure("invalid_manifest");
        }
    }
    for (auto it = manifest["base"].begin(); it != manifest["base"].end(); ++it)
        if (!it.value().is_boolean() || protected_path(relative_path(it.key())))
            throw Failure("invalid_manifest");
}
// Match Windows game paths on case-sensitive hosts without introducing two overlays.
fs::path resolve_destination(const fs::path &root, const fs::path &relative) {
    fs::path current = root, result;
    for (const auto &part : relative) {
        auto selected = part;
        if (fs::is_directory(current)) {
            for (const auto &entry : fs::directory_iterator(current))
                if (lower(entry.path().filename().u8string()) == lower(part.u8string())) {
                    selected = entry.path().filename(); break;
                }
        }
        result /= selected;
        current = checked(root, result);
    }
    return result;
}
std::vector<fs::path> collect(const fs::path &root) {
    std::vector<fs::path> files;
    uint64_t total = 0;
    for (fs::recursive_directory_iterator it(root), end; it != end; ++it) {
        auto rel = it->path().lexically_relative(root);
        if (fs::is_symlink(it->symlink_status())) throw Failure("unsafe_path", rel.u8string());
        if (protected_path(rel)) {
            if (it->is_directory()) it.disable_recursion_pending();
            continue;
        }
        if (it->is_directory()) continue;
        if (!it->is_regular_file()) throw Failure("unsafe_path", rel.u8string());
        total += it->file_size();
        if (total > max_bytes || files.size() >= max_files) throw Failure("too_large");
        files.push_back(rel);
    }
    return files;
}
void extract(const fs::path &source, const fs::path &destination) {
    struct Reader {
        archive *value = archive_read_new();
        ~Reader() { archive_read_free(value); }
    } reader;
    archive_read_support_filter_all(reader.value);
    archive_read_support_format_all(reader.value);
#ifdef _WIN32
    const int opened = archive_read_open_filename_w(reader.value, source.c_str(), 128 * 1024);
#else
    const int opened = archive_read_open_filename(reader.value, source.c_str(), 128 * 1024);
#endif
    if (opened != ARCHIVE_OK)
        throw Failure("invalid_archive", archive_error_string(reader.value) ? archive_error_string(reader.value) : "");
    archive_entry *entry;
    uint64_t total = 0;
    size_t count = 0;
    int status;
    std::vector<char> buffer(1024 * 1024);
    while ((status = archive_read_next_header(reader.value, &entry)) == ARCHIVE_OK) {
        const char *name = archive_entry_pathname_utf8(entry);
        if (!name) name = archive_entry_pathname(entry);
        if (!name) throw Failure("unsafe_path");
        auto relative = relative_path(name);
        if (archive_entry_symlink(entry) || archive_entry_hardlink(entry))
            throw Failure("unsafe_path", name);
        if (protected_path(relative)) { archive_read_data_skip(reader.value); continue; }
        auto type = archive_entry_filetype(entry);
        if (type == AE_IFDIR) continue;
        if (type != AE_IFREG) throw Failure("unsafe_path", name);
        if (++count > max_files || archive_entry_size(entry) < 0 ||
            uint64_t(archive_entry_size(entry)) > max_bytes) throw Failure("too_large");
        auto output = checked(destination, relative);
        if (path_exists(output)) throw Failure("file_conflict", name);
        fs::create_directories(output.parent_path());
        std::ofstream stream(output, std::ios::binary);
        la_ssize_t size;
        while ((size = archive_read_data(reader.value, buffer.data(), buffer.size())) > 0) {
            total += size;
            if (total > max_bytes) throw Failure("too_large");
            stream.write(buffer.data(), size);
            if (!stream) throw Failure("write_failed", name);
        }
        if (size < 0) throw Failure("invalid_archive", name);
        stream.close();
        if (!stream) throw Failure("write_failed", name);
    }
    if (status != ARCHIVE_EOF) throw Failure("invalid_archive");
}
fs::path find_root(const fs::path &root, const fs::path &game) {
    auto files = collect(root);
    std::set<fs::path> parents;
    bool has_asset = false;
    for (const auto &file : files) {
        has_asset |= asset(file);
        auto ext = lower(file.extension().u8string());
        if (ext == ".ain" || ext == ".afa" || ext == ".ald" || ext == ".ex")
            parents.insert(file.parent_path());
    }
    if (!has_asset) throw Failure("no_assets");
    // Resource-only folders retain their paths (for example data/face.png).
    if (parents.empty()) return root;
    fs::path prefix = *parents.begin();
    for (const auto &parent : parents) {
        while (!prefix.empty()) {
            auto rel = parent.lexically_relative(prefix);
            if (!rel.empty() && *rel.begin() != "..") break;
            prefix = prefix.parent_path();
        }
    }
    if (!prefix.empty() && fs::is_directory(game / resolve_destination(game, *prefix.begin()))) return root;
    return root / prefix;
}
void prune(const fs::path &store, const Json &manifest) {
    std::set<std::string> ids;
    for (const auto &mod : manifest["mods"]) ids.insert(mod["id"].get<std::string>());
    auto packages = checked(store, "packages");
    if (fs::is_directory(packages))
        for (const auto &entry : fs::directory_iterator(packages))
            if (!ids.count(entry.path().filename().u8string())) fs::remove_all(entry.path());
    auto base = checked(store, "base");
    if (fs::is_directory(base))
        for (const auto &entry : fs::recursive_directory_iterator(base)) {
            if (entry.is_symlink()) throw Failure("unsafe_path");
            if (entry.is_regular_file() && !manifest["base"].contains(relative_name(entry.path().lexically_relative(base))))
                fs::remove(entry.path());
        }
    fs::remove_all(checked(store, "staging"));
    fs::remove_all(checked(store, "rollback"));
}
void recover(const fs::path &root, const fs::path &store) {
    auto pending = store / "pending.json";
    if (!path_exists(pending)) return;
    auto state = read_json(pending);
    if (!state.contains("previous") || !state.contains("files") || !state["files"].is_object())
        throw Failure("invalid_manifest");
    validate_manifest(state["previous"]);
    for (auto it = state["files"].begin(); it != state["files"].end(); ++it) {
        auto rel = relative_path(it.key());
        if (!it.value().is_boolean() || protected_path(rel)) throw Failure("invalid_manifest");
        auto target = checked(root, rel);
        if (it.value().get<bool>()) {
            auto backup = checked(store / "rollback", rel);
            if (!fs::is_regular_file(backup)) throw Failure("recovery_failed", it.key());
            fs::create_directories(target.parent_path());
            publish(backup, target, store / "restore.tmp");
        } else if (path_exists(target)) {
            if (!fs::is_regular_file(target)) throw Failure("recovery_failed", it.key());
            fs::remove(target);
        }
    }
    write_json(store / "manifest.json", state["previous"]);
    fs::remove(pending);
    fs::remove_all(store / "rollback");
}
void apply(const fs::path &root, const fs::path &store, const Json &before,
           const Json &after, const std::set<std::string> &affected) {
    fs::remove_all(store / "rollback");
    Json pending = {{"previous", before}, {"files", Json::object()}};
    for (const auto &name : affected) {
        auto rel = relative_path(name), target = checked(root, rel);
        bool present = path_exists(target);
        if (present) copy_contents(target, checked(store / "rollback", rel));
        pending["files"][name] = present;
    }
    write_json(store / "pending.json", pending);
    try {
        for (const auto &name : affected) {
            auto rel = relative_path(name), target = checked(root, rel);
            fs::path source;
            for (auto it = after["mods"].rbegin(); it != after["mods"].rend(); ++it)
                if (std::find((*it)["files"].begin(), (*it)["files"].end(), name) != (*it)["files"].end()) {
                    source = checked(store / "packages" / (*it)["id"].get<std::string>(), rel);
                    break;
                }
            if (source.empty() && after["base"].value(name, before["base"].value(name, false)))
                source = checked(store / "base", rel);
            if (source.empty()) {
                if (path_exists(target) && !fs::is_regular_file(target)) throw Failure("file_conflict", name);
                fs::remove(target);
            } else {
                fs::create_directories(target.parent_path());
                publish(source, target, store / "apply.tmp");
            }
        }
        write_json(store / "manifest.json", after);
        fs::remove(store / "pending.json");
    } catch (...) {
        try { recover(root, store); }
        catch (...) { throw Failure("recovery_failed", store.u8string()); }
        throw;
    }
    // Once the journal is removed, cleanup failure must not turn a committed
    // operation into an apparent failure. The next operation prunes leftovers.
    std::error_code cleanup;
    fs::remove_all(store / "rollback", cleanup);
}
Json run(const fs::path &requested, const std::string &operation, const fs::path &argument) {
    if (!requested.is_absolute() || !fs::is_directory(requested) ||
        fs::is_symlink(fs::symlink_status(requested))) throw Failure("invalid_game");
    auto root = fs::canonical(requested);
    auto store = checked(root, store_name);
    if (!path_exists(store) && operation == "list") return {{"ok", true}, {"mods", Json::array()}};
    fs::create_directories(store);
    for (const auto &name : {"manifest.json", "pending.json", "base", "packages", "rollback", "staging"})
        checked(store, name);
    recover(root, store);
    Json before = path_exists(store / "manifest.json") ? read_json(store / "manifest.json") : empty_manifest();
    validate_manifest(before);
    prune(store, before);
    if (operation == "list") return {{"ok", true}, {"mods", before["mods"]}};
    if (operation != "install" && operation != "uninstall") throw Failure("invalid_operation");
    Json after = before;
    std::set<std::string> affected;
    fs::path package;
    std::string installed_id;
    if (operation == "install") {
        if (!argument.is_absolute() || !path_exists(argument) || fs::is_symlink(fs::symlink_status(argument)))
            throw Failure("invalid_source");
        auto source = fs::canonical(argument);
        auto from_game = source.lexically_relative(root);
        auto contains_game = root.lexically_relative(source);
        if ((!from_game.empty() && *from_game.begin() != "..") ||
            (!contains_game.empty() && *contains_game.begin() != ".."))
            throw Failure("source_overlaps_game");
        fs::remove_all(store / "staging");
        fs::create_directories(store / "staging");
        auto input = source;
        if (!fs::is_directory(source)) {
            if (asset(source))
                copy_contents(source, store / "staging" / source.filename());
            else extract(source, store / "staging");
            input = store / "staging";
        }
        auto mod_root = find_root(input, root);
        auto files = collect(mod_root);
        const auto saves = save_folders(root);
        files.erase(std::remove_if(files.begin(), files.end(), [&](const fs::path &path) {
            return within_save_folder(path, saves);
        }), files.end());
        if (files.empty()) throw Failure("no_assets");
        installed_id = std::to_string(std::chrono::system_clock::now().time_since_epoch().count()) +
            "-" + std::to_string(++sequence);
        package = store / "packages" / installed_id;
        Json names = Json::array();
        std::set<std::string> folded;
        for (const auto &rel : files) {
            auto resolved = resolve_destination(root, rel);
            auto name = relative_name(resolved);
            if (!folded.insert(lower(name)).second) throw Failure("file_conflict", name);
            auto target = checked(root, resolved);
            if (path_exists(target) && !fs::is_regular_file(target)) throw Failure("file_conflict", name);
            copy_contents(checked(mod_root, rel), checked(package, resolved));
            if (!after["base"].contains(name)) {
                bool present = path_exists(target);
                if (present) copy_contents(target, checked(store / "base", resolved));
                after["base"][name] = present;
            }
            names.push_back(name);
            affected.insert(name);
        }
        after["mods"].push_back({{"id", installed_id}, {"name", source.filename().u8string()},
            {"source", source.u8string()}, {"files", names},
            {"installed_at", std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())}});
    } else {
        auto id = argument.u8string();
        if (!valid_id(id)) throw Failure("invalid_mod");
        auto &mods = after["mods"];
        auto found = std::find_if(mods.begin(), mods.end(), [&](const Json &mod) { return mod["id"] == id; });
        if (found == mods.end()) throw Failure("invalid_mod");
        for (const auto &name : (*found)["files"]) affected.insert(name.get<std::string>());
        mods.erase(found);
        package = store / "packages" / id;
    }
    std::set<std::string> live;
    for (const auto &mod : after["mods"])
        for (const auto &name : mod["files"]) live.insert(name.get<std::string>());
    Json old_base = after["base"];
    for (auto it = old_base.begin(); it != old_base.end(); ++it)
        if (!live.count(it.key())) after["base"].erase(it.key());
    apply(root, store, before, after, affected);
    std::error_code cleanup;
    if (operation == "uninstall") fs::remove_all(package, cleanup);
    fs::remove_all(store / "staging", cleanup);
    for (auto it = old_base.begin(); it != old_base.end(); ++it)
        if (!live.count(it.key())) fs::remove(checked(store / "base", relative_path(it.key())), cleanup);
    return {{"ok", true}, {"mods", after["mods"]}, {"installed_id", installed_id}};
}
}
std::string mod_operation(const std::string &root, const std::string &operation, const std::string &argument) {
    std::lock_guard<std::mutex> lock(operation_mutex);
    try { return run(fs::u8path(root), operation, fs::u8path(argument)).dump(); }
    catch (const Failure &error) { return Json({{"ok", false}, {"error", error.code}, {"detail", error.what()}}).dump(); }
    catch (const std::exception &error) { return Json({{"ok", false}, {"error", "io_failed"}, {"detail", error.what()}}).dump(); }
}
}
