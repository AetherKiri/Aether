#pragma once
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef __APPLE__
#include <sys/syscall.h>
#endif

/* Android's emulated storage and some removable filesystems do not support
 * RENAME_NOREPLACE or hard links. Reserve the name exclusively there, then
 * publish the complete staged file or directory in a single ordinary rename. */
static inline int aether_archive_rename_exclusive(int from_dir, const char *from, int to_dir, const char *to) {
#ifdef __APPLE__
    if (!renameatx_np(from_dir, from, to_dir, to, RENAME_EXCL)) return 0;
#else
    if (!syscall(SYS_renameat2, from_dir, from, to_dir, to, 1 /* RENAME_NOREPLACE */)) return 0;
#endif
    if (errno != EINVAL && errno != ENOTSUP && errno != ENOSYS) return -1;
    struct stat incoming;
    if (fstatat(from_dir, from, &incoming, AT_SYMLINK_NOFOLLOW)) return -1;
    const int directory = S_ISDIR(incoming.st_mode);
    int reserved;
    if (directory) {
        if (mkdirat(to_dir, to, 0700)) return -1;
        reserved = openat(to_dir, to, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    } else {
        if (!S_ISREG(incoming.st_mode)) { errno = EINVAL; return -1; }
        reserved = openat(to_dir, to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    }
    if (reserved < 0) return -1;
    struct stat held, current;
    int result = -1;
    if (!fstat(reserved, &held) && !fstatat(to_dir, to, &current, AT_SYMLINK_NOFOLLOW)) {
        if (held.st_dev == current.st_dev && held.st_ino == current.st_ino) {
            result = renameat(from_dir, from, to_dir, to);
            if (result) {
                const int error = errno;
                if (!fstatat(to_dir, to, &current, AT_SYMLINK_NOFOLLOW) &&
                    held.st_dev == current.st_dev && held.st_ino == current.st_ino)
                    unlinkat(to_dir, to, directory ? AT_REMOVEDIR : 0);
                errno = error;
            }
        } else errno = EEXIST;
    }
    const int error = errno;
    close(reserved);
    errno = error;
    return result;
}
