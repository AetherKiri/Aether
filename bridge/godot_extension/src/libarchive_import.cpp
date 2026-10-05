#include "libarchive_import.h"

#if defined(AETHERKIRI_WITH_LIBARCHIVE)

#include <archive.h>
#include <archive_entry.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <vector>

namespace godot {
namespace {
namespace fs = std::filesystem;
constexpr uint64_t kMaxOutputBytes = 32ull * 1024ull * 1024ull * 1024ull;
constexpr uint32_t kMaxDepth = 8;
constexpr uint32_t kMaxExpansionRatio = 100;

struct Limits { uint64_t input_bytes = 1; uint64_t output_bytes = 0; };
struct PasswordState { std::string value; bool used = false; };

const char *PassphraseCallback(struct archive *, void *opaque, const char *) {
    auto *state = static_cast<PasswordState *>(opaque);
    if (state == nullptr || state->value.empty() || state->used) return nullptr;
    state->used = true;
    return state->value.c_str();
}

bool SafeRelativePath(const char *raw, fs::path &relative) {
    if (raw == nullptr || raw[0] == '\0') return false;
    const fs::path candidate = fs::u8path(raw);
    if (candidate.is_absolute() || candidate.has_root_name() || candidate.has_root_directory()) return false;
    for (const auto &component : candidate) if (component == "..") return false;
    relative = candidate.lexically_normal();
    return !relative.empty() && relative != ".";
}

bool ExtractOne(const fs::path &input, const fs::path &output,
                const std::string &password, Limits &limits, std::string &error) {
    struct archive *reader = archive_read_new();
    if (reader == nullptr) { error = "libarchive allocation failed"; return false; }
    archive_read_support_filter_all(reader);
    archive_read_support_format_all(reader);
    PasswordState password_state{password, false};
    archive_read_set_passphrase_callback(reader, &password_state, PassphraseCallback);
    if (archive_read_open_filename(reader, input.u8string().c_str(), 1024 * 1024) != ARCHIVE_OK) {
        error = archive_error_string(reader) != nullptr ? archive_error_string(reader) : "archive open failed";
        archive_read_free(reader); return false;
    }
    std::error_code fs_error;
    fs::create_directories(output, fs_error);
    bool saw_file = false;
    struct archive_entry *entry = nullptr;
    int status = ARCHIVE_OK;
    while ((status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        fs::path relative;
        if (!SafeRelativePath(archive_entry_pathname(entry), relative)) { archive_read_data_skip(reader); continue; }
        const fs::path destination = output / relative;
        const int type = archive_entry_filetype(entry);
        if (type == AE_IFDIR) { fs::create_directories(destination, fs_error); archive_read_data_skip(reader); continue; }
        if (type != AE_IFREG) { archive_read_data_skip(reader); continue; }
        fs::create_directories(destination.parent_path(), fs_error);
        std::ofstream file(destination, std::ios::binary | std::ios::trunc);
        if (!file) { error = "unable to create extracted file"; archive_read_free(reader); return false; }
        const void *buffer = nullptr; size_t size = 0; la_int64_t offset = 0;
        int block_status = ARCHIVE_OK;
        while ((block_status = archive_read_data_block(reader, &buffer, &size, &offset)) == ARCHIVE_OK) {
            if (size > kMaxOutputBytes || limits.output_bytes > kMaxOutputBytes - size ||
                limits.output_bytes > limits.input_bytes * kMaxExpansionRatio) {
                error = "archive expansion limit exceeded"; archive_read_free(reader); return false;
            }
            file.write(static_cast<const char *>(buffer), static_cast<std::streamsize>(size));
            if (!file) { error = "unable to write extracted file"; archive_read_free(reader); return false; }
            limits.output_bytes += static_cast<uint64_t>(size);
        }
        if (block_status != ARCHIVE_EOF) {
            error = archive_error_string(reader) != nullptr ? archive_error_string(reader) : "archive entry extraction failed";
            archive_read_free(reader); return false;
        }
        saw_file = true;
    }
    if (status != ARCHIVE_EOF) {
        error = archive_error_string(reader) != nullptr ? archive_error_string(reader) : "archive extraction failed";
        archive_read_free(reader); return false;
    }
    archive_read_free(reader);
    return saw_file;
}

bool LoadPasswordBook(const std::string &path, std::vector<std::string> &passwords) {
    if (path.empty()) return true;
    std::ifstream file(path, std::ios::binary); if (!file) return false;
    std::string line;
    while (std::getline(file, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t')) line.pop_back();
        const size_t first = line.find_first_not_of(" \t");
        if (first == std::string::npos || line[first] == '#' || line[first] == ';') continue;
        line.erase(0, first);
        if (line.size() <= 256 && std::find(passwords.begin(), passwords.end(), line) == passwords.end()) passwords.push_back(line);
    }
    return true;
}

bool ExtractRecursive(const fs::path &input, const fs::path &output,
                      const std::vector<std::string> &passwords, Limits limits,
                      uint32_t depth, std::string &error) {
    if (depth >= kMaxDepth) { error = "archive nesting depth exceeded"; return false; }
    std::error_code fs_error;
    const fs::path level = output / ("_archive_" + std::to_string(depth));
    bool extracted = false;
    for (const std::string &candidate : passwords) {
        fs::remove_all(level, fs_error);
        Limits attempt = limits;
        if (ExtractOne(input, level, candidate, attempt, error)) { limits = attempt; extracted = true; break; }
    }
    if (!extracted) return false;
    for (fs::recursive_directory_iterator it(level, fs_error), end; it != end && !fs_error; it.increment(fs_error)) {
        const auto extension = it->path().extension().string();
        if (!it->is_regular_file(fs_error) || extension.empty()) continue;
        std::string lower = extension;
        std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        if (lower != ".zip" && lower != ".rar" && lower != ".7z" && lower != ".tar" && lower != ".gz" && lower != ".bz2" && lower != ".xz" && lower != ".cab") continue;
        const fs::path nested = output / ("_archive_" + std::to_string(depth + 1));
        std::string nested_error;
        if (ExtractRecursive(it->path(), nested, passwords, limits, depth + 1, nested_error)) fs::remove(it->path(), fs_error);
    }
    return true;
}
}

bool RunLibarchiveImport(const std::string &input_path, const std::string &output_path,
                         const std::string &password_db, const std::string &password,
                         std::string &error) {
    std::vector<std::string> passwords;
    if (!password.empty()) passwords.push_back(password);
    if (!LoadPasswordBook(password_db, passwords)) { error = "unable to read password book"; return false; }
    passwords.emplace_back();
    for (const char *common : {"123456", "password", "12345678", "000000"}) if (std::find(passwords.begin(), passwords.end(), common) == passwords.end()) passwords.emplace_back(common);
    Limits limits; std::error_code fs_error;
    const auto input_size = fs::file_size(fs::u8path(input_path), fs_error);
    if (!fs_error && input_size > 0) limits.input_bytes = input_size;
    return ExtractRecursive(fs::u8path(input_path), fs::u8path(output_path), passwords, limits, 0, error);
}
}

#else
namespace godot {
bool RunLibarchiveImport(const std::string &, const std::string &, const std::string &, const std::string &, std::string &error) {
    error = "libarchive backend is not compiled for this platform";
    return false;
}
}
#endif
