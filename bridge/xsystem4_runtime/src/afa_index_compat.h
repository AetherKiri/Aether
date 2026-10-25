/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <stdio.h>
#include <stdlib.h>
#include "system4/afa.h"
#include "system4/zlib.h"

static bool aether_afa_decompress_index(FILE *file, struct afa_archive *archive,
                                        void *table, uint8_t **compressed) {
    if(zlib_decompress_exact(table, archive->uncompressed_size, *compressed,
                             archive->compressed_size))
        return true;

    // Some fan repackers store the compressed payload size in INFO instead of
    // the size including INFO's 16-byte header (Rance9CG / Rance9CGEx).
    // Retry only that variant, within the index region, with a full checksum
    // and exact decompressed-size check. Never repair the imported file.
    const size_t end = 44u + (size_t)archive->compressed_size;
    if(end > archive->data_start || archive->data_start - end < 16)
        return false;
    uint8_t *extended = realloc(*compressed, archive->compressed_size + 16u);
    if(!extended)
        return false;
    *compressed = extended;
    if(fseek(file, (long)end, SEEK_SET) ||
       fread(extended + archive->compressed_size, 16, 1, file) != 1)
        return false;
    if(!zlib_decompress_exact(table, archive->uncompressed_size, extended,
                              archive->compressed_size + 16u))
        return false;
    archive->compressed_size += 16;
    return true;
}
