#pragma once
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

// Minimal stable libarchive read ABI. macOS exports these symbols from libarchive;
// its SDK ships the library stub but omits the public headers. No bundled decoder.
// Signatures checked against upstream archive.h/archive_entry.h (BSD licensed).
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
uint16_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
