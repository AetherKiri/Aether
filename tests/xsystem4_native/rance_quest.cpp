extern "C" {
#include "system4/ain.h"
#include "system4/string.h"
#include "system4/utfsjis.h"
#include "vm.h"
#include "xsystem4.h"
void apply_game_specific_hacks(struct ain *script);
extern struct static_library lib_MonsterInfo;
}
#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

static void Require(bool condition, const char *message) {
    if(!condition)
        throw std::runtime_error(message);
}

static std::string Encode(const char *text, bool gbk) {
    const bool previous = use_gbk;
    use_gbk = gbk;
    char *encoded = utf2sjis(text, 0);
    std::string result(encoded);
    free(encoded);
    use_gbk = previous;
    return result;
}

template <typename Function>
static Function MonsterFunction(const char *name) {
    for(auto *f = lib_MonsterInfo.functions; f->name; ++f)
        if(std::string(f->name) == name)
            return reinterpret_cast<Function>(f->fun);
    throw std::runtime_error("Missing MonsterInfo export");
}

static void CheckDetection(const char *title, bool gbk, bool tapir,
                           bool expected, bool english = false) {
    use_gbk = gbk;
    config.game_name = strdup(Encode(title, gbk).c_str());
    struct ain *script = ain_new(6, 0);
    ain_add_library(script, "ChipmunkSpriteEngine");
    ain_add_library(script, "GoatGUIEngine");
    if(tapir)
        ain_add_library(script, "TapirEngine");
    apply_game_specific_hacks(script);
    const bool detected = game_rance8, english_detected = game_rance8_mg;
    ain_free(script);
    free(config.game_name);
    config.game_name = nullptr;
    Require(detected == expected, "Incorrect Rance Quest compatibility mode");
    Require(english_detected == english,
            "English workaround leaked into another translation");
    Require(use_gbk == gbk, "Game detection changed dialogue encoding");
}

static void WriteArchive(const fs::path &root, const std::string &data) {
    const std::string name = "Data\\MonsterInfo.txt";
    const size_t offset = 24 + name.size() + 1;
    std::vector<uint8_t> bytes(offset + data.size());
    const auto put = [&](size_t pos, uint32_t value) {
        for(int i = 0; i < 4; ++i)
            bytes[pos + i] = (value >> (8 * i)) & 0xff;
    };
    std::copy_n("AAR", 3, bytes.begin());
    put(8, 1);
    put(12, offset);
    put(16, data.size());
    put(20, 1); // AAR_RAW
    std::copy(name.begin(), name.end(), bytes.begin() + 24);
    std::copy(data.begin(), data.end(), bytes.begin() + offset);
    fs::create_directories(root / "Data");
    std::ofstream output(root / "Data/ReignData.red", std::ios::binary);
    output.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
    Require(bool(output), "Could not write synthetic metadata archive");
}

static void CheckMetadata(const fs::path &root, bool dialogue_gbk,
                          bool metadata_gbk) {
    const std::string data =
        Encode("// fixture: leading comments and blank lines\r\n\t\r\n"
               "モンスター [1] = {\r\n名前 = \"テスト\"\r\n"
               "データ = \"モデル\"\r\nスケール = 1.25\r\n位置 = (1, 2, 3)\r\n"
               "モーション [0] = {\r\n名前 = \"待機\"\r\nデータ = \"動作\"\r\n"
               "タイプ = ループ\r\nフレーム = 10, 20\r\n"
               "ループフレーム = 13, 18\r\n}\r\n}\r\n",
               metadata_gbk);
    WriteArchive(root, data);
    use_gbk = dialogue_gbk;
    config.game_dir = strdup(root.string().c_str());
    struct string *filename = cstr_to_string("Data\\MonsterInfo.txt");
    const bool loaded =
        MonsterFunction<bool (*)(struct string *)>("Load")(filename);
    free_string(filename);
    Require(loaded, "Mixed-encoding monster metadata failed to load");
    Require(use_gbk == dialogue_gbk, "Metadata load changed dialogue encoding");
    Require(MonsterFunction<int (*)()>("GetNumof")() == 2,
            "Monster index was not retained");
    Require(std::fabs(MonsterFunction<float (*)(int)>("GetScale")(1) - 1.25f) <
                0.0001f,
            "Monster scale was not parsed");
    Require(MonsterFunction<int (*)(int, int)>("GetMotionType")(1, 0) == 2,
            "Motion loop was not parsed");
    struct string *value = nullptr;
    MonsterFunction<void (*)(int, struct string **)>("GetPolyName")(1, &value);
    Require(value && value->text == Encode("モデル", metadata_gbk),
            "Model resource identifier was transcoded");
    free_string(value);
    value = nullptr;
    MonsterFunction<void (*)(int, int, struct string **)>("GetMotionDataName")(
        1, 0, &value);
    Require(value && value->text == Encode("動作", metadata_gbk),
            "Motion resource identifier was transcoded");
    free_string(value);
    MonsterFunction<void (*)()>("Release")();

    // A malformed final line must fail without crashing or changing encoding.
    WriteArchive(root, Encode("モンスター [1] = {\nunknown", metadata_gbk));
    filename = cstr_to_string("Data\\MonsterInfo.txt");
    Require(!MonsterFunction<bool (*)(struct string *)>("Load")(filename),
            "Malformed metadata was accepted");
    free_string(filename);
    Require(use_gbk == dialogue_gbk,
            "Failed metadata load changed dialogue encoding");
    MonsterFunction<void (*)()>("Release")();
    Require(MonsterFunction<int (*)()>("GetNumof")() == 0,
            "Monster data leaked into the next session");
    free(config.game_dir);
    config.game_dir = nullptr;
}

int main() {
    const fs::path root = fs::temp_directory_path() /
        ("aether-rance-quest-" +
         std::to_string(
             std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        CheckDetection("兰斯8", true, true, true);
        CheckDetection("Renamed", false, true, true);
        CheckDetection("ランス・クエスト", false, false, true);
        CheckDetection("Rance Quest", false, true, true, true);
        CheckDetection("Unrelated", true, false, false);
        CheckDetection("Renamed", false, true, true);
        for(bool dialogue_gbk : { false, true })
            for(bool metadata_gbk : { false, true })
                CheckMetadata(root, dialogue_gbk, metadata_gbk);
        fs::remove_all(root);
        std::cout << "XSYSTEM4_RANCE_QUEST_CONTRACT_OK\n";
        return 0;
    } catch(const std::exception &error) {
        fs::remove_all(root);
        std::cerr << "XSYSTEM4_RANCE_QUEST_CONTRACT_FAILED: " << error.what()
                  << '\n';
        return 1;
    }
}
