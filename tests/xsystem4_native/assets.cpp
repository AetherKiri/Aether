extern "C" {
#include "asset_manager.h"
#include "xsystem4.h"
#include "system4/archive.h"
#include "system4/utfsjis.h"
#include "system4/zlib.h"
void asset_manager_fini(void);
}
#include <algorithm>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace fs = std::filesystem;
using Bytes = std::vector<uint8_t>;

static void Require(bool value, const char *message) {
    if(!value)
        throw std::runtime_error(message);
}

static void Put32(Bytes &bytes, size_t offset, uint32_t value) {
    for(int i = 0; i < 4; ++i)
        bytes[offset + i] = value >> (i * 8);
}

static void Write(const fs::path &file, const Bytes &bytes) {
    std::ofstream stream(file, std::ios::binary);
    stream.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
    Require(bool(stream), "Could not write archive fixture");
}

static Bytes Ald(const char *payload) {
    Bytes bytes(768);
    bytes[0] = 1; // Pointer table, link table, then one file.
    bytes[3] = 2;
    bytes[6] = 3;
    bytes[256] = bytes[257] = 1;
    bytes[259] = 2;
    bytes[260] = 1;
    Put32(bytes, 512, 32);
    Put32(bytes, 516, 4);
    std::copy_n("file.bin", 8, bytes.begin() + 528);
    std::copy_n(payload, 4, bytes.begin() + 544);
    return bytes;
}

static Bytes Afa(const char *payload) {
    const std::string name = "file.bin";
    Bytes table(8 + name.size() + 1 + 20);
    Put32(table, 0, name.size());
    Put32(table, 4, name.size() + 1);
    std::copy(name.begin(), name.end(), table.begin() + 8);
    Put32(table, table.size() - 20, 1);
    Put32(table, table.size() - 8, 8);
    Put32(table, table.size() - 4, 4);
    Bytes compressed(zlib_compress_bound(table.size()));
    const size_t size = zlib_compress(compressed.data(), compressed.size(),
                                      table.data(), table.size(), 6);
    Require(size, "Could not compress archive fixture");
    Bytes bytes(4108);
    std::copy_n("AFAH", 4, bytes.begin());
    Put32(bytes, 4, 28);
    std::copy_n("AlicArch", 8, bytes.begin() + 8);
    Put32(bytes, 16, 1);
    Put32(bytes, 20, 1);
    Put32(bytes, 24, 4096);
    std::copy_n("INFO", 4, bytes.begin() + 28);
    Put32(bytes, 32, size + 16);
    Put32(bytes, 36, table.size());
    Put32(bytes, 40, 1);
    std::copy_n(compressed.begin(), size, bytes.begin() + 44);
    std::copy_n("DATA", 4, bytes.begin() + 4096);
    Put32(bytes, 4100, 12);
    std::copy_n(payload, 4, bytes.begin() + 4104);
    return bytes;
}

static void Close() {
    asset_manager_fini();
    free(config.game_dir);
    free(config.ain_filename);
    free(config.bgi_path);
    free(config.wai_path);
    free(config.ex_path);
    free(config.fnl_path);
    config.game_dir = config.ain_filename = config.bgi_path = config.wai_path =
        config.ex_path = config.fnl_path = nullptr;
}

static void Open(const fs::path &directory, const char *script, bool chinese) {
    Close();
    use_gbk = chinese;
    config.game_dir = strdup(directory.string().c_str());
    config.ain_filename = utf2sjis(script, 0);
    asset_manager_init();
}

static void Check(enum asset_type type, int id, const char *expected) {
    Require(asset_exists(type, id), "Resource archive was not discovered");
    struct archive_data *data = asset_get(type, id);
    const bool valid =
        data && data->size == 4 && !memcmp(data->data, expected, 4);
    if(data)
        archive_free_data(data);
    Require(valid, "Wrong resource family or volume was loaded");
}

int main() {
    const fs::path root = fs::temp_directory_path() /
        ("aether-assets-contract-" +
         std::to_string(
             std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        const fs::path ald = root / "ald";
        fs::create_directories(ald);
        Write(ald / fs::u8path(u8"原版GA.ald"), Ald("base"));
        Write(ald / fs::u8path(u8"原版GB.ald"), Ald("next"));
        Write(ald / fs::u8path(u8"原版BA.ald"), Ald("bgm!"));
        Write(ald / fs::u8path(u8"原版WA.ald"), Ald("snd!"));
        Write(ald / fs::u8path(u8"原版BA.bgi"), {});
        Write(ald / fs::u8path(u8"原版WA.wai"), {});
        fs::create_directories(ald / "DecoyGA.ald");
        Write(ald / "unrelated.ald", {});
        Open(ald, "Translated.ain", true);
        Check(ASSET_CG, 1, "base");
        Check(ASSET_CG, 2, "next");
        Check(ASSET_BGM, 1, "bgm!");
        Check(ASSET_SOUND, 1, "snd!");
        Require(config.bgi_path && config.wai_path,
                "Archive sidecars were not selected with their family");

        // Exact script/archive names retain priority, even with other families.
        Write(ald / "TranslatedGA.ald", Ald("same"));
        Write(ald / "TranslatedBackupGA.ald", Ald("no!!"));
        Open(ald, "Translated.ain", true);
        Check(ASSET_CG, 1, "same");
        Require(!asset_exists(ASSET_BGM, 1),
                "Different archive families were mixed");

        const fs::path afa = root / "afa";
        fs::create_directories(afa);
        Write(afa / "OriginalCG.afa", Afa("cg!!"));
        Write(afa / "OriginalSound.afa", Afa("snd!"));
        Open(afa, "Renamed.ain", false);
        Check(ASSET_CG, 1, "cg!!");
        Check(ASSET_SOUND, 1, "snd!");

        // Multiple candidates must never depend on directory enumeration order.
        Write(afa / "OtherCG.afa", Afa("no!!"));
        Open(afa, "Renamed.ain", false);
        Require(!asset_exists(ASSET_CG, 1) && !asset_exists(ASSET_SOUND, 1),
                "Ambiguous archive family was selected");
        Open(afa, "Original.ain", false);
        Check(ASSET_CG, 1, "cg!!");

        const fs::path japanese = root / "japanese";
        fs::create_directories(japanese);
        Write(japanese / fs::u8path(u8"テストGA.ald"), Ald("sjis"));
        Open(japanese, u8"テスト.ain", false);
        Check(ASSET_CG, 1, "sjis");

        const fs::path mixed = root / "mixed-case";
        fs::create_directories(mixed);
        Write(mixed / "MixedGa.AlD", Ald("case"));
        Write(mixed / "mixedBA.ald", Ald("bgm!"));
        Open(mixed, "RENAMED.ain", false);
        Check(ASSET_CG, 1, "case");
        Check(ASSET_BGM, 1, "bgm!");
        const fs::path afa_case = root / "afa-case";
        fs::create_directories(afa_case);
        Write(afa_case / "Mixedcg.AFA", Afa("case"));
        Write(afa_case / "mixedSOUND.afa", Afa("snd!"));
        Open(afa_case, "RENAMED.ain", false);
        Check(ASSET_CG, 1, "case");
        Check(ASSET_SOUND, 1, "snd!");
        Close();
        fs::remove_all(root);
        std::cout << "XSYSTEM4_ASSETS_CONTRACT_OK\n";
        return 0;
    } catch(const std::exception &error) {
        Close();
        fs::remove_all(root);
        std::cerr << "XSYSTEM4_ASSETS_CONTRACT_FAILED: " << error.what()
                  << '\n';
        return 1;
    }
}
