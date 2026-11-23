#pragma once
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace aether::cache {
std::string Digest(const std::vector<uint8_t>& bytes);
// Publish atomically and reuse matching files. Partial writes never become hits.
void Write(const std::filesystem::path& path, const std::vector<uint8_t>& bytes);
std::filesystem::path Materialize(const std::filesystem::path& directory,
                                 const std::vector<uint8_t>& bytes,
                                 const std::string& extension);
}
