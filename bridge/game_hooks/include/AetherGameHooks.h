#pragma once

#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace aether::hooks {

// One startup script and its read-only resource overlay, owned by one game.
// Lua runs before the engine reads scripts; it is closed after registration.
class GameHooks {
public:
    using Bytes = std::vector<uint8_t>;
    void Load(const std::filesystem::path& root, const std::string& engine);
    const Bytes* Find(const std::string& name) const;
    const std::map<std::string, Bytes>& Files() const { return files_; }
    const std::string& Encoding() const { return encoding_; }
    const std::filesystem::path& Font() const { return font_; }
    const std::vector<std::string>& Messages() const { return messages_; }
    bool Active() const { return active_; }
    // Byte-text engines share this complete set. Unicode-only formats may
    // explicitly pass an empty list to reject a global byte encoding override.
    void RequireEncoding(const std::vector<std::string>& supported =
        {"CP932", "GBK", "GB18030", "BIG5", "UTF-8"}) const;

    // For engines whose resource consumers require a native file path. The
    // caller owns this cache directory; original game files are never written.
    void Materialize(const std::filesystem::path& directory) const;
    std::filesystem::path CacheDirectory(const std::filesystem::path& parent) const;
    static std::string ResourceKey(std::string name);

private:
    struct Script;
    struct Cache;
    mutable std::shared_ptr<Cache> cache_;
    std::map<std::string, Bytes> files_;
    std::string encoding_;
    std::filesystem::path font_;
    std::vector<std::string> messages_;
    bool active_ = false;
};

} // namespace aether::hooks
