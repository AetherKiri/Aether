#pragma once

#include "emberfall/game_session.hpp"
#include "nnn/game_name_list.hpp"
#include <filesystem>
#include <fstream>
#include <system_error>
#include <unistd.h>

namespace aether::systemnnn {

class SaveBank {
public:
    explicit SaveBank(const std::filesystem::path &root) {
        directory = nnn::resource::find_directory(root, "sav");
        if (directory.empty()) directory = root / "sav";
        if (std::filesystem::is_symlink(directory))
            throw std::runtime_error("SystemNNN save directory must be inside the game");
        std::filesystem::create_directories(directory);
        const nnn::game_config::NameListSetup data(nnn::game_config::read(root, "init", "dataFile.xtx"));
        quick = std::clamp(data.integer("quickSlotNumber", 1) - 1, 0, 999);
    }

    void Configure(const emberfall::scene::GameSession &game, const std::filesystem::path &root) {
        prefix_ = game.shared_config_snapshot().trial_flag ? "tdata" : "data";
        for (const char *file : {"save.xtx", "load.xtx"}) {
            const nnn::game_config::NameListSetup setup(nnn::game_config::read(root, "init", file));
            const int page = std::clamp(setup.integer("blockNumberX", 4), 1, 16) * std::clamp(setup.integer("blockNumberY", 3), 1, 16);
            count = std::max(count, page * std::clamp(setup.integer("page", 10), 1, 1000 / page));
        }
    }

    std::filesystem::path Slot(int number) const {
        if (number < 0 || number >= std::max(count, quick + 1)) throw std::invalid_argument("Invalid SystemNNN save slot");
        const auto name = prefix_ + std::to_string(number) + ".sav";
        auto file = nnn::resource::find_file(directory, name);
        return file.empty() ? directory / name : file;
    }

    int LastSlot() const {
        for (const char *name : {".last-slot", ".last-slot.bak"}) {
            if (!std::filesystem::is_regular_file(std::filesystem::symlink_status(directory / name)))
                continue;
            std::ifstream file(directory / name, std::ios::binary);
            unsigned char bytes[8];
            if (!file.read(reinterpret_cast<char *>(bytes), 8) || file.peek() != EOF || bytes[0] != 'L' ||
                bytes[1] != 'S' || bytes[2] != 'T' || bytes[3] != '2')
                continue;
            const uint32_t slot =
                (uint32_t(bytes[4]) << 24) | (uint32_t(bytes[5]) << 16) | (uint32_t(bytes[6]) << 8) | bytes[7];
            if (slot < unsigned(std::max(count, quick + 1)) && std::filesystem::is_regular_file(Slot(int(slot))))
                return int(slot);
        }
        return -1;
    }

    void Remember(int slot) const {
        Write(directory / ".last-slot", {'L', 'S', 'T', '2', 0, 0, uint8_t(unsigned(slot) >> 8), uint8_t(slot)});
    }

    static std::vector<uint8_t> Read(const std::filesystem::path &path) {
        if (!std::filesystem::is_regular_file(std::filesystem::symlink_status(path)))
            throw std::runtime_error("Save slot is unavailable");
        const auto size = std::filesystem::file_size(path);
        if (!size || size > 16 * 1024 * 1024) throw std::runtime_error("Invalid PC save size");
        std::vector<uint8_t> bytes(size);
        std::ifstream file(path, std::ios::binary);
        if (!file.read(reinterpret_cast<char *>(bytes.data()), size)) throw std::runtime_error("Cannot read PC save");
        return bytes;
    }

    static void Write(const std::filesystem::path &path, const std::vector<uint8_t> &bytes) {
        if (std::filesystem::is_symlink(path) || std::filesystem::is_symlink(path.parent_path()))
            throw std::runtime_error("Save slot must be inside the game");
        std::string temp = path.string() + ".XXXXXX";
        int fd = mkstemp(temp.data());
        if (fd < 0) throw std::system_error(errno, std::generic_category(), "Create save");
        try {
            size_t offset = 0;
            while (offset < bytes.size()) {
                auto n = write(fd, bytes.data() + offset, bytes.size() - offset);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) throw std::system_error(errno, std::generic_category(), "Write save");
                offset += size_t(n);
            }
            if (fsync(fd) < 0) throw std::system_error(errno, std::generic_category(), "Sync save");
            const int result = close(fd);
            fd = -1;
            if (result < 0) throw std::system_error(errno, std::generic_category(), "Close save");
            std::filesystem::rename(temp, path);
        } catch (...) {
            if (fd >= 0) close(fd);
            unlink(temp.c_str());
            throw;
        }
    }

    std::filesystem::path directory;
    int count = 0, quick = 0;
private:
    std::string prefix_;
};

} // namespace aether::systemnnn
