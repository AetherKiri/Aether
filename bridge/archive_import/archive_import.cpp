#include "archive_import.h"
#include <aetherunzip/archive.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
#include <charconv>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <map>
#include <memory>
#include <vector>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace aether::archive {
namespace fs = std::filesystem;
namespace {
using Source = std::unique_ptr<au_source, decltype(&aether_unzip_source_close)>;
using Catalog = std::unique_ptr<au_archive, decltype(&aether_unzip_archive_close)>;
using Context = std::unique_ptr<au_context, decltype(&aether_unzip_context_destroy)>;
constexpr char marker[] = "aether-import-in-progress.json";
constexpr char marker_value[] = "Aether archive import v1";
constexpr char prefix[] = "Extracting-";

std::string lower(std::string value) {
    for (char &c : value) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return value;
}

bool read_at(au_source *source, uint64_t offset, void *buf, size_t size) {
    size_t got = 0;
    return aether_unzip_source_read_at(source, offset, buf, size, &got) == AU_OK && got == size;
}
unsigned u16(const uint8_t *p) { return p[0] | (unsigned(p[1]) << 8); }
uint32_t u32(const uint8_t *p) { return u16(p) | (uint32_t(u16(p + 2)) << 16); }
uint64_t u64(const uint8_t *p) { return u32(p) | (uint64_t(u32(p + 4)) << 32); }

// Some distribution files contain a playable media prefix and a trailer after the
// ZIP comment. Verify both directory offsets and signatures before exposing a slice.
Source embedded_zip(au_source *source) {
    Source result(nullptr, aether_unzip_source_close);
    uint64_t length = 0;
    if (aether_unzip_source_length(source, &length) != AU_OK || length < 22) return result;
    std::vector<uint8_t> tail(static_cast<size_t>(std::min<uint64_t>(length, 1024 * 1024)));
    const uint64_t start = length - tail.size();
    if (!read_at(source, start, tail.data(), tail.size())) return result;
    for (size_t i = tail.size() - 21; i-- > 0;) {
        const auto *p = tail.data() + i;
        if (std::memcmp(p, "PK\x05\x06", 4) || u16(p + 4) || u16(p + 6) ||
            !u16(p + 10) || u16(p + 8) != u16(p + 10)) continue;
        const uint64_t end = start + i + 22 + u16(p + 20);
        uint64_t central_end = start + i;
        uint64_t central_size = u32(p + 12), central_offset = u32(p + 16);
        // ZIP64 end records may be present even when all ZIP32 fields fit.
        if (i >= 76 && std::memcmp(p - 20, "PK\x06\x07", 4) == 0) {
            const size_t locator = i - 20;
            bool found = false;
            for (size_t j = locator - 55; j-- > 0;) {
                auto *record = tail.data() + j;
                if (std::memcmp(record, "PK\x06\x06", 4) || u64(record + 4) != locator - j - 12 ||
                    u32(record + 16) || u32(record + 20) || u64(record + 24) != u64(record + 32)) continue;
                central_end = start + j;
                central_size = u64(record + 40);
                central_offset = u64(record + 48);
                found = true;
                break;
            }
            if (!found) continue;
        }
        if (end > length || central_size < 46 || central_size > central_end ||
            central_offset > central_end - central_size) continue;
        uint64_t base = central_end - central_size - central_offset;
        std::array<uint8_t, 46> header{};
        char local[4];
        if (!read_at(source, base + central_offset, header.data(), header.size()) ||
            std::memcmp(header.data(), "PK\x01\x02", 4) || u16(header.data() + 34) ||
            !read_at(source, base + u32(header.data() + 42), local, sizeof(local)) ||
            std::memcmp(local, "PK\x03\x04", 4)) continue;
        au_source *slice = nullptr;
        if (aether_unzip_source_slice(source, base, end - base, &slice) == AU_OK) result.reset(slice);
        return result;
    }
    return result;
}

bool metadata(const fs::path &p) {
    const auto n = p.filename().string();
    return n == "__MACOSX" || n == ".DS_Store" || n == "Thumbs.db" || n.rfind("._", 0) == 0;
}
bool transport_archive(const fs::path &path) {
    static const std::array<const char *, 12> extensions = {
        ".zip", ".rar", ".7z", ".tar", ".gz", ".xz", ".bz2", ".zst", ".lz4", ".cab", ".lha", ".tgz"};
    auto ext = lower(path.extension().string());
    return std::find(extensions.begin(), extensions.end(), ext) != extensions.end();
}
std::vector<fs::path> children(const fs::path &path, std::error_code &ec) {
    std::vector<fs::path> list;
    for (fs::directory_iterator it(path, ec), end; !ec && it != end; it.increment(ec))
        if (!metadata(it->path())) list.push_back(it->path());
    return list;
}
struct Stream {
    Job &job;
    uint64_t total = 0;
    uint64_t written = 0;
    int begin = 0, span = 1000;
};
int32_t cancelled(void *ptr) { return static_cast<Stream *>(ptr)->job.cancel.load(); }
void report_progress(void *ptr, const au_entry *, uint64_t bytes, uint64_t, uint64_t) {
    auto &s = *static_cast<Stream *>(ptr);
    s.written = bytes;
    if (s.total) s.job.progress = s.begin + static_cast<int>(s.span * std::min(1.0, double(bytes) / s.total));
}

// Preserve volume order even when the user opens a middle part. The core
// retains each source for its concatenated reader without copying the payload.
enum class VolumeKind { Single, ByteSplit, ZipDisk, LegacyRar, PartRar };
struct Volume {
    VolumeKind kind = VolumeKind::Single;
    std::string name;
    int index = 0;
};
int sequence(const std::string &s, size_t minimum) {
    if (s.size() < minimum || s.front() < '0' || s.front() > '9') return -1;
    int value = 0;
    auto parsed = std::from_chars(s.data(), s.data() + s.size(), value);
    return parsed.ec == std::errc{} && parsed.ptr == s.data() + s.size() ? value : -1;
}
Volume volume(const fs::path &path) {
    const auto stem = path.stem();
    const auto suffix = lower(path.extension().string());
    if (suffix.size() >= 4 && suffix[1] == 'z') {
        const int n = sequence(suffix.substr(2), 2);
        if (n > 0) return {VolumeKind::ZipDisk, stem.string() + ".zip", n};
    }
    if (suffix.size() == 4 && suffix[1] == 'r') {
        const int n = sequence(suffix.substr(2), 2);
        if (n >= 0) return {VolumeKind::LegacyRar, stem.string() + ".rar", n + 2};
    }
    auto inner = lower(stem.extension().string());
    if (suffix == ".rar" && inner.rfind(".part", 0) == 0) {
        const int n = sequence(inner.substr(5), 1);
        if (n > 0) return {VolumeKind::PartRar, stem.stem().string() + ".rar", n};
    }
    if (suffix.size() >= 4 && (inner == ".zip" || inner == ".7z")) {
        const int n = sequence(suffix.substr(1), 3);
        if (n > 0) return {VolumeKind::ByteSplit, stem.string(), n};
    }
    // A final .zip or initial .rar also opens as an ordinary single file.
    if (suffix == ".zip") return {VolumeKind::ZipDisk, path.filename().string(), 0};
    if (suffix == ".rar") return {VolumeKind::LegacyRar, path.filename().string(), 1};
    return {VolumeKind::Single, path.filename().string(), 0};
}
int open_source(const fs::path &path, const Volume &part, Source &source, std::vector<std::string> &members) {
    au_source *raw = nullptr;
    if (part.kind == VolumeKind::Single) {
        const int status = aether_unzip_source_file(path.c_str(), &raw);
        source.reset(raw);
        return status;
    }
    std::map<int, fs::path> parts;
    std::error_code ec;
    const auto key = lower(part.name);
    const auto dir = path.has_parent_path() ? path.parent_path() : fs::path(".");
    for (fs::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec)) {
        const auto other = volume(it->path().filename());
        if (other.kind != part.kind || lower(other.name) != key) continue;
        if (it->is_regular_file(ec) && !parts.emplace(other.index, it->path()).second) return AU_INVALID;
    }
    if (ec) return AU_IO;
    fs::path final;
    if (part.kind == VolumeKind::ZipDisk) {
        auto last = parts.find(0);
        if (last == parts.end()) return AU_NOT_FOUND;
        final = last->second;
        parts.erase(last);
    }
    std::vector<Source> owned;
    std::vector<au_source *> refs;
    const auto append = [&](const fs::path &p) {
        au_source *file = nullptr;
        auto status = aether_unzip_source_file(p.c_str(), &file);
        if (status == AU_OK) {
            owned.emplace_back(file, aether_unzip_source_close);
            refs.push_back(file);
            members.push_back(p.string());
        }
        return status;
    };
    for (const auto &entry : parts) {
        if (entry.first != static_cast<int>(owned.size()) + 1) return AU_NOT_FOUND;
        auto status = append(entry.second);
        if (status != AU_OK) return status;
    }
    if (!final.empty()) {
        auto status = append(final);
        if (status != AU_OK) return status;
    }
    if (owned.empty()) return AU_NOT_FOUND;
    if (owned.size() == 1) {
        source = std::move(owned.front());
        return AU_OK;
    }
    auto status = aether_unzip_source_concat(refs.data(), refs.size(), &raw);
    source.reset(raw);
    return status;
}

struct Archive {
    Source source{nullptr, aether_unzip_source_close};
    std::string hint;
    Result open(const fs::path &path, const au_context *ctx, au_options &options) {
        Result r;
        auto part = volume(path.filename());
        hint = part.name;
        r.placement.archive_name = archive_folder_name(part.name);
        r.status = open_source(path, part, source, r.members);
        if (r.status != AU_OK) return r;
        au_archive *cursor = nullptr;
        r.status = aether_unzip_archive_open_catalog(ctx, source.get(), hint.c_str(), &options, &cursor);
        // libarchive's stream bidder can return a seemingly empty ZIP for an
        // MP4 with an appended ZIP. Prefer its verified central directory.
        char first[4]{};
        bool wrapped_zip = cursor && aether_unzip_archive_info(cursor)->format == AU_FORMAT_ZIP &&
            read_at(source.get(), 0, first, sizeof(first)) && std::memcmp(first, "PK", 2) != 0;
        if (wrapped_zip || r.status == AU_UNKNOWN_FORMAT || r.status == AU_CORRUPT || r.status == AU_UNSUPPORTED) {
            if (auto slice = embedded_zip(source.get())) {
                if (cursor) aether_unzip_archive_close(cursor);
                cursor = nullptr;
                source = std::move(slice);
                hint = "archive.zip";
                r.status = aether_unzip_archive_open_catalog(ctx, source.get(), hint.c_str(), &options, &cursor);
            }
        }
        Catalog catalog(cursor, aether_unzip_archive_close);
        if (r.status != AU_OK) return r;
        r.format = aether_unzip_format_name(aether_unzip_archive_info(cursor)->format);
        const au_entry *entry = nullptr;
        uint64_t files = 0;
        bool first_root = true, top_file = false, descendants = false;
        fs::path shared_parent, first_file;
        std::vector<fs::path> directories;
        bool nested_transport = false;
        while ((r.status = aether_unzip_archive_next_entry(cursor, &entry)) == AU_OK) {
            if (++r.entries > options.max_entries) { r.status = AU_LIMIT; break; }
            r.encrypted |= entry->encrypted != 0;
            if (entry->size_known) {
                if (entry->size > options.max_entry_bytes || entry->size > options.max_total_bytes - r.bytes) {
                    r.status = AU_LIMIT; break;
                }
                r.bytes += entry->size;
            }
            const char *normalized = nullptr;
            size_t size = 0;
            const auto safe = aether_unzip_normalize_entry_path(entry->name, entry->kind, options.max_path_depth,
                                                                &normalized, &size);
            if (safe == AU_END) continue;
            if (safe != AU_OK) { r.status = safe; break; }
            const fs::path relative(std::string(normalized, size));
            const auto top = relative.begin()->string();
            if (first_root) r.placement.common_directory = top;
            else if (r.placement.common_directory != top) r.placement.common_directory.clear();
            first_root = false;
            descendants |= relative.has_parent_path();
            top_file |= entry->kind == AU_ENTRY_FILE && !relative.has_parent_path();
            if (metadata(top) || metadata(relative)) continue;
            if (entry->kind == AU_ENTRY_DIRECTORY) directories.push_back(relative);
            if (entry->kind != AU_ENTRY_FILE) continue;
            const auto parent = relative.parent_path();
            if (++files == 1) {
                first_file = relative;
                shared_parent = parent;
                nested_transport = transport_archive(relative);
            } else {
                const auto shared = std::mismatch(shared_parent.begin(), shared_parent.end(), parent.begin(), parent.end());
                fs::path prefix;
                for (auto it = shared_parent.begin(); it != shared.first; ++it) prefix /= *it;
                shared_parent = prefix;
            }
            if (launcher_file(relative) && (r.placement.launcher.empty() ||
                    (lower(relative.extension().string()) == ".exe" && lower(fs::path(r.placement.launcher).extension().string()) != ".exe")))
                r.placement.launcher = relative.string();
        }
        if (r.status == AU_END) r.status = AU_OK;
        if (top_file) r.placement.common_directory.clear();
        r.placement.can_strip = !r.placement.common_directory.empty() && descendants;
        bool extra_directory = false;
        for (const auto &directory : directories) {
            auto shared = std::mismatch(shared_parent.begin(), shared_parent.end(), directory.begin(), directory.end());
            if (shared.second == directory.end()) continue; // An explicit entry for a wrapper.
            extra_directory = true;
            fs::path prefix;
            for (auto part = shared_parent.begin(); part != shared.first; ++part) prefix /= *part;
            shared_parent = prefix;
        }
        r.placement.inner_archive = files == 1 && nested_transport && !extra_directory;
        if (files == 1 && !first_file.has_parent_path() && !extra_directory) r.placement.single_file = first_file.string();
        if (files == 0) shared_parent = r.placement.common_directory;
        const fs::path launcher(r.placement.launcher);
        if (launcher.empty() || launcher.parent_path() != shared_parent) {
            fs::path prefix;
            for (const auto &component : shared_parent) {
                if (runtime_data_directory(component)) break;
                prefix /= component;
            }
            shared_parent = prefix;
        }
        r.placement.smart_subdir = shared_parent.string();
        return r;
    }
};

struct Work {
    fs::path path;
    int fd = -1;
    bool keep_recovery = false;
    ~Work() {
        if (!path.empty()) {
            std::error_code ec;
            if (keep_recovery) fs::remove(path / marker, ec);
            else fs::remove_all(path, ec);
        }
        if (fd >= 0) close(fd);
    }
    bool create(const fs::path &games) {
        std::error_code ec;
        fs::create_directories(games, ec);
        if (ec) return false;
        auto pattern = (games / "Extracting-XXXXXX").string();
        if (!mkdtemp(pattern.data())) return false;
        path = pattern;
        fd = ::open(path.c_str(), O_RDONLY | O_DIRECTORY);
        if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB)) return false;
        const int tag = openat(fd, marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (tag < 0) return false;
        const auto count = write(tag, marker_value, sizeof(marker_value) - 1);
        close(tag);
        return count == sizeof(marker_value) - 1;
    }
};

int publish(const fs::path &from, const fs::path &to) {
    return rename_exclusive(AT_FDCWD, from.c_str(), AT_FDCWD, to.c_str());
}
}

void clean_interrupted(const std::string &games) {
    std::error_code ec;
    for (fs::directory_iterator it(games, ec), end; !ec && it != end; it.increment(ec)) {
        const auto work = it->path();
        const auto name = work.filename().string();
        if (name.rfind(prefix, 0) != 0 || name.size() != sizeof(prefix) - 1 + 6 ||
            !fs::is_directory(it->symlink_status(ec))) continue;
        const int fd = ::open(work.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (fd < 0) continue;
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            const int tag = openat(fd, marker, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
            if (tag >= 0) {
                char value[sizeof(marker_value)]{};
                if (read(tag, value, sizeof(value)) == sizeof(marker_value) - 1 &&
                    std::memcmp(value, marker_value, sizeof(marker_value) - 1) == 0) {
                    std::error_code ignored;
                    fs::remove_all(work, ignored);
                }
                close(tag);
            }
        }
        close(fd);
    }
}

Result Job::copy_provider(const std::string &games, const std::string &name, uint64_t length,
                          const std::function<int64_t(uint8_t *, size_t)> &read) {
    Result r;
    Work work;
    if (!work.create(games)) { r.status = errno == ENOSPC ? AU_NO_SPACE : AU_IO; return r; }
    const auto temporary = work.path / "document";
    FILE *out = std::fopen(temporary.c_str(), "wb");
    if (!out) { r.status = AU_IO; return r; }
    std::vector<uint8_t> buf(1024 * 1024);
    while (!cancel.load()) {
        const auto n = read(buf.data(), buf.size());
        if (n < 0 || static_cast<uint64_t>(n) > buf.size()) { r.status = AU_IO; break; }
        if (!n) break;
        if (std::fwrite(buf.data(), 1, static_cast<size_t>(n), out) != static_cast<size_t>(n)) {
            r.status = errno == ENOSPC ? AU_NO_SPACE : AU_IO;
            break;
        }
        r.bytes += n;
        if (length) progress = static_cast<int>(1000 * std::min(1.0, double(r.bytes) / length));
    }
    if (std::fclose(out) && r.status == AU_OK) r.status = errno == ENOSPC ? AU_NO_SPACE : AU_IO;
    if (cancel.load()) r.status = AU_CANCELLED;
    if (r.status == AU_OK && length && r.bytes != length) r.status = AU_IO;
    if (r.status != AU_OK) return r;
    auto leaf = fs::path(name).filename();
    if (leaf.empty() || leaf.string().front() == '.') leaf = "Archive";
    for (int copy = 1; copy <= 10000; ++copy) {
        const auto target = fs::path(games) / (copy == 1 ? leaf.string() :
            leaf.stem().string() + " (" + std::to_string(copy) + ")" + leaf.extension().string());
        if (publish(temporary, target) == 0) {
            r.destination = target.string();
            progress = 1000;
            return r;
        }
        if (errno != EEXIST && errno != ENOTEMPTY) { r.status = AU_IO; return r; }
    }
    r.status = AU_EXISTS;
    return r;
}

Result Job::inspect(const std::string &path, const std::string &password) {
    au_context *ctx = nullptr;
    Result r;
    r.status = aether_unzip_context_create_with_passphrase(password.empty() ? nullptr : password.c_str(), &ctx);
    Context context(ctx, aether_unzip_context_destroy);
    if (r.status != AU_OK) return r;
    auto options = aether_unzip_options_default();
    Stream stream{*this};
    options.cancel = cancelled;
    options.user = &stream;
    Archive archive;
    return archive.open(path, ctx, options);
}

Result Job::extract(const std::string &path, const std::string &games, const std::string &password,
                    const std::string &layout_name, const std::string &policy_name, const std::string &library) {
    Layout layout;
    uint32_t policy;
    if (!parse_plan(layout_name, policy_name, layout, policy) || !fs::path(games).is_absolute()) {
        Result invalid;
        invalid.status = AU_INVALID;
        return invalid;
    }
    au_context *ctx = nullptr;
    Result r;
    r.status = aether_unzip_context_create_with_passphrase(password.empty() ? nullptr : password.c_str(), &ctx);
    Context context(ctx, aether_unzip_context_destroy);
    if (r.status != AU_OK) return r;
    Work work;
    if (!work.create(games)) { r.status = errno == ENOSPC ? AU_NO_SPACE : AU_IO; return r; }
    auto options = aether_unzip_options_default();
    Stream stream{*this};
    options.cancel = cancelled;
    options.progress = report_progress;
    options.conflict_policy = policy;
    options.user = &stream;
    const fs::path destination(games);
    fs::path input(path);
    std::vector<std::string> members;
    std::error_code ec;
    for (int level = 0; level < 5; ++level) {
        Archive archive;
        r = archive.open(input, ctx, options);
        if (level == 0) {
            members = r.members;
            if (members.empty()) members.push_back(path);
        }
        if (r.status != AU_OK) return r;
        auto output = work.path / std::to_string(level);
        if (!fs::create_directory(output, ec)) { r.status = AU_IO; return r; }
        stream.total = r.bytes;
        stream.written = 0;
        const auto &plan = r.placement;
        const bool unpack_inner = layout == Layout::Smart && plan.inner_archive;
        if (layout == Layout::Strip && !plan.can_strip) { r.status = AU_INVALID; return r; }
        stream.span = (1000 - stream.begin) / (unpack_inner ? 2 : 1);
        r.status = aether_unzip_extract(ctx, archive.source.get(), archive.hint.c_str(),
                                        output.c_str(), nullptr, 0, &options);
        if (r.status != AU_OK) return r;
        options.max_total_bytes -= std::min(options.max_total_bytes, stream.written);
        options.max_entries -= std::min(options.max_entries, r.entries);
        if (level) fs::remove(input, ec);
        if (cancel.load()) { r.status = AU_CANCELLED; return r; }
        const fs::path smart_dir = plan.smart_subdir.empty() ? output : output / plan.smart_subdir;
        if (unpack_inner) {
            // The sole meaningful file may itself be inside several wrapper directories.
            auto nested = output;
            auto items = children(nested, ec);
            while (!ec && items.size() == 1 && fs::is_directory(items.front(), ec))
                items = children(items.front(), ec);
            if (ec || items.size() != 1 || !transport_archive(items.front())) { r.status = AU_INVALID; return r; }
            if (!options.max_entries || !options.max_total_bytes) { r.status = AU_LIMIT; return r; }
            input = items.front();
            stream.begin += stream.span;
            continue;
        }
        const bool loose = layout == Layout::Smart && !plan.single_file.empty() && plan.launcher.empty();
        const bool create_folder = layout == Layout::Folder || (layout == Layout::Smart && !loose);
        if (create_folder) {
            const auto root = layout == Layout::Smart ? smart_dir : output;
            const auto candidate = layout == Layout::Smart ? fs::path(plan.smart_subdir).filename().string() : std::string{};
            const auto name = candidate.empty() || candidate.front() == '.' ? plan.archive_name : candidate;
            for (int copy = 1; copy <= 10000; ++copy) {
                const auto leaf = copy == 1 ? name : name + " (" + std::to_string(copy) + ")";
                const auto target = destination / leaf;
                if (publish(root, target) == 0) {
                    r.destination = target.string();
                    r.game_root = (layout == Layout::Folder && !plan.smart_subdir.empty()
                        ? target / plan.smart_subdir : target).string();
                    break;
                }
                if (errno != EEXIST && errno != ENOTEMPTY) { r.status = errno == ENOSPC ? AU_NO_SPACE : AU_IO; return r; }
            }
            if (r.destination.empty()) { r.status = AU_EXISTS; return r; }
        } else {
            const auto root = layout == Layout::Strip ? output / plan.common_directory : output;
            auto tracked = !plan.launcher.empty() ? output / plan.launcher :
                           !plan.single_file.empty() ? output / plan.single_file : fs::path{};
            fs::path actual = tracked.empty() ? fs::path{} : destination / tracked.lexically_relative(root);
            const fs::path inside = smart_dir.lexically_relative(root);
            const auto game_dir = inside.empty() || inside == "." || *inside.begin() == ".." ? destination : destination / inside;
            bool shared = game_dir == fs::path(library) || game_dir == fs::path(path).parent_path();
            if (!shared && fs::is_directory(game_dir, ec)) {
                // Merging into an existing collection must never give one game ownership
                // of that whole collection when the user later deletes the game on iOS.
                for (fs::directory_iterator it(game_dir, ec), end; !ec && it != end; it.increment(ec)) {
                    if (it->path() != work.path) { shared = true; break; }
                }
                if (ec) { r.status = AU_IO; return r; }
            }
            const bool skipped_launcher = shared && policy == AU_CONFLICT_SKIP && !actual.empty() && fs::exists(actual, ec);
            r.status = merge_outputs(root, destination, policy, members, cancel, work.path, tracked, actual, work.keep_recovery);
            if (r.status != AU_OK) return r;
            if (!plan.launcher.empty() || !plan.smart_subdir.empty()) {
                r.game_root = shared ? (plan.launcher.empty() || skipped_launcher ? "" : actual.string()) : game_dir.string();
            }
            r.destination = !plan.single_file.empty() && !actual.empty() ? actual.string()
                : layout == Layout::Direct && !plan.common_directory.empty() ? (destination / plan.common_directory).string()
                : destination.string();
        }
        r.members = std::move(members);
        progress = 1000;
        return r;
    }
    r.status = AU_LIMIT;
    return r;
}
}
