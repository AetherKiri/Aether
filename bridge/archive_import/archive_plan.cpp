#include "archive_plan.h"
#include "archive_publish.h"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <map>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace aether::archive {
namespace fs = std::filesystem;
bool parse_plan(const std::string &mode, const std::string &conflict, Layout &layout, uint32_t &policy) {
    if (mode == "smart") layout = Layout::Smart;
    else if (mode == "direct") layout = Layout::Direct;
    else if (mode == "folder") layout = Layout::Folder;
    else if (mode == "strip") layout = Layout::Strip;
    else return false;
    if (conflict == "keep") policy = AU_CONFLICT_KEEP_BOTH;
    else if (conflict == "skip") policy = AU_CONFLICT_SKIP;
    else if (conflict == "stop") policy = AU_CONFLICT_FAIL;
    else if (conflict == "replace") policy = AU_CONFLICT_REPLACE;
    else return false;
    return true;
}
int rename_exclusive(int from_dir, const char *from, int to_dir, const char *to) {
    return aether_archive_rename_exclusive(from_dir, from, to_dir, to);
}
namespace {
std::string lowercase(std::string s) {
    for (auto &c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}
struct ScopedFd {
    int fd;
    explicit ScopedFd(int owned) : fd(owned) {}
    explicit ScopedFd(int parent, const char *name) : fd(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) {}
    ~ScopedFd() { if (fd >= 0) close(fd); }
    ScopedFd(const ScopedFd &) = delete;
};
int output_error() { return errno == ENOSPC || errno == EDQUOT ? AU_NO_SPACE : AU_IO; }
bool same_file(const struct stat &a, const struct stat &b) { return a.st_dev == b.st_dev && a.st_ino == b.st_ino; }

int open_parent(int root, const fs::path &relative) {
    int parent = dup(root);
    for (const auto &part : relative.parent_path()) {
        if (parent < 0) break;
        const int next = openat(parent, part.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(parent);
        parent = next;
    }
    return parent;
}

struct Original {
    struct stat identity{};
    fs::path copy;
};

int backup_file(int parent, const std::string &name, const Original &original, const std::atomic<bool> &cancel) {
    if (!linkat(parent, name.c_str(), AT_FDCWD, original.copy.c_str(), 0)) return AU_OK;
    // Emulated Android storage has no hard links. Keep the old contents intact
    // until every replacement can be made, including a low-space failure.
    ScopedFd input(openat(parent, name.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    struct stat identity{};
    if (input.fd < 0 || fstat(input.fd, &identity) || !same_file(original.identity, identity)) return AU_IO;
    const int copy = open(original.copy.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, identity.st_mode & 0777);
    if (copy < 0) return output_error();
    int status = AU_OK;
    char buffer[64 * 1024];
    while (status == AU_OK && !cancel.load()) {
        ssize_t size = read(input.fd, buffer, sizeof(buffer));
        if (size == 0) break;
        if (size < 0) { if (errno == EINTR) continue; status = output_error(); break; }
        for (ssize_t offset = 0; offset < size;) {
            const ssize_t n = write(copy, buffer + offset, static_cast<size_t>(size - offset));
            if (n <= 0) { if (n < 0 && errno == EINTR) continue; status = output_error(); break; }
            offset += n;
        }
    }
    if (close(copy) && status == AU_OK) status = output_error();
    return cancel.load() ? AU_CANCELLED : status;
}

struct Publication {
    fs::path source, relative, backup;
    struct stat identity{};
};

struct Merge {
    uint32_t policy;
    const std::atomic<bool> &cancel;
    std::vector<struct stat> protected_files;
    struct stat work{};
    fs::path tracked;
    fs::path actual;
    fs::path staging;
    std::map<fs::path, Original> originals;
    std::vector<Publication> written;
    bool apply = false;
    int record(int parent, const fs::path &path, const fs::path &relative, const fs::path &backup = {}) {
        Publication publication{path, relative, backup};
        if (fstatat(parent, relative.filename().c_str(), &publication.identity, AT_SYMLINK_NOFOLLOW)) return AU_IO;
        written.emplace_back(std::move(publication));
        return AU_OK;
    }
    bool undo(int root) const {
        bool restored = true;
        for (auto it = written.rbegin(); it != written.rend(); ++it) {
            ScopedFd parent(open_parent(root, it->relative));
            if (parent.fd < 0) { restored = false; continue; }
            const auto name = it->relative.filename();
            struct stat current{};
            if (fstatat(parent.fd, name.c_str(), &current, AT_SYMLINK_NOFOLLOW) || !same_file(current, it->identity)) {
                restored = false;
                continue;
            }
            const int status = it->backup.empty()
                ? rename_exclusive(parent.fd, name.c_str(), AT_FDCWD, it->source.c_str())
                : renameat(AT_FDCWD, it->backup.c_str(), parent.fd, name.c_str());
            if (status) restored = false;
        }
        return restored;
    }
    // The descriptors keep writes inside the inspected directory even if some
    // other process changes a parent path while a game is being imported.
    int tree(const fs::path &directory, int output, const fs::path &relative = {}) {
        ScopedFd source(AT_FDCWD, directory.c_str());
        if (source.fd < 0) return AU_IO;
        std::error_code ec;
        std::vector<fs::path> children;
        for (fs::directory_iterator it(directory, ec), end; !ec && it != end; it.increment(ec))
            children.push_back(it->path());
        if (ec) return AU_IO;
        for (const auto &path : children) {
            // Cancellation remains available while validating and decoding. Finish
            // the short publication once the first complete file can be visible.
            if (!apply && cancel.load()) return AU_CANCELLED;
            const auto name = path.filename().string();
            struct stat incoming{}, existing{};
            if (fstatat(source.fd, name.c_str(), &incoming, AT_SYMLINK_NOFOLLOW)) return AU_IO;
            const bool folder = S_ISDIR(incoming.st_mode);
            if (!folder && !S_ISREG(incoming.st_mode)) return AU_UNSAFE_PATH;
            if (fstatat(output, name.c_str(), &existing, AT_SYMLINK_NOFOLLOW)) {
                if (errno != ENOENT) return output_error();
                if (!apply) continue;
                if (!rename_exclusive(source.fd, name.c_str(), output, name.c_str())) {
                    const int saved = record(output, path, relative / name);
                    if (saved != AU_OK) return saved;
                    continue;
                }
                if ((errno != EEXIST && errno != ENOTEMPTY) ||
                    fstatat(output, name.c_str(), &existing, AT_SYMLINK_NOFOLLOW)) return output_error();
            }
            if (folder) {
                if (!S_ISDIR(existing.st_mode) || same_file(existing, work)) return AU_UNSAFE_PATH;
                ScopedFd child(output, name.c_str());
                if (child.fd < 0) return AU_UNSAFE_PATH;
                const auto status = tree(path, child.fd, relative / name);
                if (status != AU_OK) return status;
                continue;
            }
            if (!S_ISREG(existing.st_mode)) return AU_UNSAFE_PATH;
            if (policy == AU_CONFLICT_FAIL) return AU_EXISTS;
            if (policy == AU_CONFLICT_SKIP) continue;
            if (policy == AU_CONFLICT_REPLACE) {
                for (const auto &input : protected_files) if (same_file(input, existing)) return AU_EXISTS;
                if (!apply) {
                    Original original{existing, staging / "Originals" / relative / name};
                    fs::create_directories(original.copy.parent_path(), ec);
                    if (ec) return AU_IO;
                    const int status = backup_file(output, name, original, cancel);
                    if (status != AU_OK) return status;
                    originals.emplace(path, std::move(original));
                    continue;
                }
                const auto old = originals.find(path);
                if (old == originals.end() || !same_file(existing, old->second.identity)) return AU_EXISTS;
                if (renameat(source.fd, name.c_str(), output, name.c_str())) return output_error();
                const int saved = record(output, path, relative / name, old->second.copy);
                if (saved != AU_OK) return saved;
                continue;
            }
            if (!apply) continue;
            int number = 2;
            for (; number <= 10000; ++number) {
                const auto target = path.stem().string() + " (" + std::to_string(number) + ")" + path.extension().string();
                if (!rename_exclusive(source.fd, name.c_str(), output, target.c_str())) {
                    if (path == tracked) actual = actual.parent_path() / target;
                    const int saved = record(output, path, relative / target);
                    if (saved != AU_OK) return saved;
                    break;
                }
                if (errno != EEXIST && errno != ENOTEMPTY) return output_error();
            }
            if (number > 10000) return AU_EXISTS;
        }
        return AU_OK;
    }
};
}
bool runtime_data_directory(const fs::path &p) {
    const auto n = lowercase(p.filename().string());
    return n == "data" || n == "pac" || n == "pack" || n == "game" || n == "www" || n == "gamedata";
}
bool launcher_file(const fs::path &p) {
    const auto ext = lowercase(p.extension().string());
    return ext == ".exe" || ext == ".xp3" || ext == ".hcb" || ext == ".ain" || ext == ".a";
}
std::string archive_folder_name(const fs::path &source) {
    auto stem = source.stem().filename().string();
    if (lowercase(fs::path(stem).extension().string()) == ".tar") stem = fs::path(stem).stem().string();
    return stem.empty() || stem.front() == '.' ? "Game" : stem;
}
int merge_outputs(const fs::path &staged, const fs::path &destination, uint32_t policy,
                  const std::vector<std::string> &inputs, const std::atomic<bool> &cancel,
                  const fs::path &work, const fs::path &tracked, fs::path &actual_tracked, bool &keep_recovery) {
    ScopedFd target(AT_FDCWD, destination.c_str());
    if (target.fd < 0) return AU_IO;
    Merge merge{policy, cancel, {}, {}, tracked, actual_tracked, work, {}, {}};
    if (stat(work.c_str(), &merge.work)) return AU_IO;
    for (const auto &input : inputs) {
        struct stat identity{};
        if (stat(input.c_str(), &identity)) return AU_IO;
        merge.protected_files.push_back(identity);
    }
    int status = merge.tree(staged, target.fd);
    if (status == AU_OK && !cancel.load()) {
        merge.apply = true;
        status = merge.tree(staged, target.fd);
        if (status != AU_OK && !merge.undo(target.fd)) keep_recovery = true;
    } else if (cancel.load()) return AU_CANCELLED;
    actual_tracked = merge.actual;
    return status;
}
}
