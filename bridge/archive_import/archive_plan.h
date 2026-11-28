#pragma once

#include <atomic>
#include <filesystem>
#include <string>
#include <vector>
#include <aetherunzip/archive.h>

namespace aether::archive {
enum class Layout { Smart, Direct, Folder, Strip };
// Catalog metadata bounds the preview to the current archive. A nested transport
// or an encrypted catalog can only reveal the inner game after opening it.
struct Placement {
    std::string archive_name;
    std::string common_directory;
    std::string smart_subdir;
    std::string single_file;
    std::string launcher;
    bool can_strip = false;
    bool inner_archive = false;
};
bool parse_plan(const std::string &layout_name, const std::string &policy_name, Layout &layout, uint32_t &policy);
std::string archive_folder_name(const std::filesystem::path &filename);
bool runtime_data_directory(const std::filesystem::path &path);
bool launcher_file(const std::filesystem::path &path);

// All bytes are decoded into a private directory first. Only complete files
// can reach the chosen location; stop detects existing conflicts before writing.
int merge_outputs(const std::filesystem::path &staged, const std::filesystem::path &destination,
                  uint32_t policy, const std::vector<std::string> &inputs,
                  const std::atomic<bool> &cancel, const std::filesystem::path &work,
                  const std::filesystem::path &tracked, std::filesystem::path &actual_tracked,
                  bool &keep_recovery);
int rename_exclusive(int from_dir, const char *from, int to_dir, const char *to);
}
