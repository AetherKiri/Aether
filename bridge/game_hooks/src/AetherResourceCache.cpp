#include "AetherResourceCache.h"
#include <openssl/evp.h>
#include <array>
#include <algorithm>
#include <atomic>
#include <fstream>
#include <random>
#include <stdexcept>

namespace aether::cache {
std::string Digest(const std::vector<uint8_t>& bytes) {
    std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
    unsigned length = 0;
    if (EVP_Digest(bytes.data(), bytes.size(), digest.data(), &length, EVP_sha256(), nullptr) != 1)
        throw std::runtime_error("cannot hash resource cache");
    constexpr char hex[] = "0123456789abcdef";
    std::string result;
    for (unsigned i = 0; i < length; ++i) {
        result += hex[digest[i] >> 4]; result += hex[digest[i] & 15];
    }
    return result;
}

void Write(const std::filesystem::path& path, const std::vector<uint8_t>& bytes) {
    std::error_code error;
    if (std::filesystem::is_regular_file(path, error) && std::filesystem::file_size(path, error) == bytes.size()) {
        // Resource overlays keep authored names. Verify their bytes as well as
        // length so interrupted/corrupt files and same-sized updates are repaired.
        std::ifstream input(path, std::ios::binary);
        std::array<char, 65536> buffer{};
        size_t offset = 0;
        while (input && offset < bytes.size()) {
            const auto count = std::min(buffer.size(), bytes.size() - offset);
            input.read(buffer.data(), std::streamsize(count));
            if (size_t(input.gcount()) != count ||
                !std::equal(buffer.begin(), buffer.begin() + count, bytes.begin() + offset,
                    [](char a, uint8_t b) { return uint8_t(a) == b; })) break;
            offset += count;
        }
        if (input && offset == bytes.size()) return;
    }
    std::filesystem::create_directories(path.parent_path());
    static std::atomic<uint64_t> serial{0};
    static const auto nonce = std::random_device{}();
    auto temporary = path;
    temporary += ".partial-" + std::to_string(nonce) + "-" + std::to_string(serial++);
    struct Cleanup {
        std::filesystem::path path;
        ~Cleanup() { std::error_code ignored; std::filesystem::remove(path, ignored); }
    } cleanup{temporary};
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char*>(bytes.data()), std::streamsize(bytes.size()));
    output.close();
    if (!output) throw std::runtime_error("cannot write resource cache");
    std::filesystem::rename(temporary, path, error);
    if (error) { // Windows does not replace existing destinations with rename.
        std::filesystem::remove(path);
        std::filesystem::rename(temporary, path);
    }
}

std::filesystem::path Materialize(const std::filesystem::path& directory,
                                 const std::vector<uint8_t>& bytes, const std::string& extension) {
    if (directory.empty() || extension.find_first_of("/\\:") != std::string::npos)
        throw std::runtime_error("invalid resource cache location");
    const auto path = directory / (Digest(bytes) + extension);
    Write(path, bytes);
    return path;
}
}
