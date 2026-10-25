extern "C" {
#include "system4/afa.h"
#include "system4/archive.h"
#include "system4/zlib.h"
}
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using Bytes = std::vector<uint8_t>;

static void Require(bool condition, const char *message) {
    if(!condition)
        throw std::runtime_error(message);
}

static void Put32(Bytes &bytes, size_t pos, uint32_t value) {
    for(int i = 0; i < 4; ++i)
        bytes[pos + i] = (value >> (8 * i)) & 0xff;
}

static Bytes Fixture(bool payload_size, bool numbered) {
    const std::string name = "image.qnt";
    const size_t fields = 8 + name.size() + 1;
    Bytes table(fields + (numbered ? 20 : 16));
    Put32(table, 0, name.size());
    Put32(table, 4, name.size() + 1);
    std::copy(name.begin(), name.end(), table.begin() + 8);
    if(numbered)
        Put32(table, fields, 1);
    Put32(table, table.size() - 8, 8);
    Put32(table, table.size() - 4, 4);
    Bytes compressed(zlib_compress_bound(table.size()));
    const size_t size = zlib_compress(compressed.data(), compressed.size(),
                                      table.data(), table.size(), 6);
    Require(size > 16, "Index compression failed");
    compressed.resize(size);

    Bytes bytes(4096 + 12);
    std::copy_n("AFAH", 4, bytes.begin());
    Put32(bytes, 4, 28);
    std::copy_n("AlicArch", 8, bytes.begin() + 8);
    Put32(bytes, 16, numbered ? 1 : 2);
    Put32(bytes, 20, 1);
    Put32(bytes, 24, 4096);
    std::copy_n("INFO", 4, bytes.begin() + 28);
    Put32(bytes, 32, size + (payload_size ? 0 : 16));
    Put32(bytes, 36, table.size());
    Put32(bytes, 40, 1);
    std::copy(compressed.begin(), compressed.end(), bytes.begin() + 44);
    std::copy_n("DATA", 4, bytes.begin() + 4096);
    Put32(bytes, 4100, 12);
    std::copy_n("test", 4, bytes.begin() + 4104);
    return bytes;
}

int main() {
    const fs::path directory = fs::temp_directory_path() /
        ("aether-afa-contract-" +
         std::to_string(
             std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        fs::create_directories(directory);
        const fs::path file = directory / "archive.afa";
        const auto check = [&](const Bytes &bytes, bool expected, int flags) {
            std::ofstream output(file, std::ios::binary);
            output.write(reinterpret_cast<const char *>(bytes.data()),
                         bytes.size());
            output.close();
            int error = ARCHIVE_SUCCESS;
            struct afa_archive *archive =
                afa_open(file.string().c_str(), flags, &error);
            Require(bool(archive) == expected,
                    "Unexpected AFA validation result");
            if(!archive) {
                Require(error != ARCHIVE_SUCCESS,
                        "Invalid AFA did not report an error");
                return;
            }
            struct archive_data *entry =
                archive_get_by_name(&archive->ar, "image.qnt");
            const bool valid = entry && entry->size == 4 &&
                std::string(reinterpret_cast<char *>(entry->data), 4) == "test";
            if(entry)
                archive_free_data(entry);
            archive_free(&archive->ar);
            Require(valid, "AFA entry payload changed");
        };
        for(int flags : { 0, int(ARCHIVE_MMAP) }) {
            for(bool numbered : { false, true })
                for(bool payload_size : { false, true })
                    check(Fixture(payload_size, numbered), true, flags);
            Bytes corrupt = Fixture(true, false);
            corrupt[50] ^= 0xff;
            check(corrupt, false, flags);
            corrupt = Fixture(true, false);
            Put32(corrupt, 36, 1); // Decompressed size must match exactly.
            check(corrupt, false, flags);
            corrupt = Fixture(true, false);
            Put32(corrupt, 32, 15); // Do not underflow INFO's header size.
            check(corrupt, false, flags);
            corrupt = Fixture(true, false);
            Put32(corrupt, 32, 8192); // Index must not overlap DATA.
            check(corrupt, false, flags);
            corrupt = Fixture(true, false);
            const uint32_t compressed = corrupt[32] | (corrupt[33] << 8);
            Put32(corrupt, 32, compressed - 1); // Retry cannot mask truncation.
            corrupt[44 + compressed - 1] = 0;
            check(corrupt, false, flags);
            corrupt.resize(60);
            check(corrupt, false, flags);
        }
        fs::remove_all(directory);
        std::cout << "XSYSTEM4_AFA_CONTRACT_OK\n";
        return 0;
    } catch(const std::exception &error) {
        fs::remove_all(directory);
        std::cerr << "XSYSTEM4_AFA_CONTRACT_FAILED: " << error.what() << '\n';
        return 1;
    }
}
