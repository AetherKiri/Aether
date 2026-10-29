#include "AetherGameHooks.h"
#include <catch2/catch_test_macros.hpp>
#include <fstream>
#include <random>

using aether::hooks::GameHooks;
namespace fs = std::filesystem;
namespace {
struct Fixture {
    fs::path root = fs::temp_directory_path() / ("aether-hook-test-" + std::to_string(std::random_device{}()));
    Fixture() { fs::create_directories(root); }
    ~Fixture() { std::error_code error; fs::remove_all(root, error); }
    void Write(const std::string& name, const std::string& bytes) {
        const auto file = root / fs::u8path(name);
        fs::create_directories(file.parent_path());
        std::ofstream stream(file, std::ios::binary);
        stream.write(bytes.data(), bytes.size());
    }
};
}
TEST_CASE("aether.lua registers binary overrides and explicit settings") {
    Fixture f;
    f.Write("补丁/台词.bin", std::string("a\0b", 3));
    f.Write("font.ttf", "font");
    f.Write("aether.lua", R"(
        assert(aether.api_version == 1 and aether.engine == 'bgi')
        assert(io == nil and os == nil and package == nil and debug == nil)
        assert(dofile == nil and loadfile == nil)
        assert(aether.exists('补丁/台词.bin'))
        aether.add_file('SCRIPT\\TEST.BIN', aether.read_file('补丁/台词.bin', 1, 2))
        aether.set_encoding('cp936')
        aether.set_font('font.ttf')
        aether.log('中文补丁')
    )");
    GameHooks hooks;
    hooks.Load(f.root, "bgi");
    REQUIRE(hooks.Active());
    REQUIRE(hooks.Encoding() == "GBK");
    REQUIRE(hooks.Find("script/test.bin"));
    CHECK(*hooks.Find("SCRIPT/TEST.BIN") == GameHooks::Bytes{0, 'b'});
    CHECK(hooks.Font() == fs::canonical(f.root / "font.ttf"));
    CHECK(hooks.Messages() == std::vector<std::string>{"中文补丁"});
    const auto cache = hooks.CacheDirectory(f.root / "cache");
    CHECK(fs::file_size(cache / "script/test.bin") == 2);
    fs::remove(f.root / "aether.lua");
    hooks.Load(f.root, "bgi");
    CHECK_FALSE(hooks.Active());
    CHECK(hooks.Files().empty());
    CHECK_FALSE(fs::exists(cache));
}
TEST_CASE("script failures discard partially registered resources") {
    Fixture f;
    GameHooks hooks;
    for(const auto& code : {"error('bad patch')", "aether.read_file('../outside')",
            "aether.add_file('/absolute', 'bad')", "aether.read_file('aether.lua', -2)",
            "aether.set_encoding('unknown')", "aether.add_file(nil, 'bad')",
            "string.rep('x', 300 * 1024 * 1024)", "while true do end"}) {
        f.Write("aether.lua", std::string("aether.add_file('first', 'partial'); ") + code);
        CHECK_THROWS(hooks.Load(f.root, "softpal"));
        CHECK_FALSE(hooks.Active());
        CHECK(hooks.Files().empty());
    }
}
TEST_CASE("directory mounts preserve names and support empty overrides") {
    Fixture f;
    f.Write("patch/Sub/NEW.CST", "scene");
    f.Write("aether.lua", "aether.mount_dir('patch'); aether.add_file('sub/new.cst', '')");
    GameHooks hooks;
    hooks.Load(f.root, "catsystem2");
    REQUIRE(hooks.Find("Sub/NEW.CST"));
    CHECK(hooks.Find("Sub/NEW.CST")->empty());
    CHECK(hooks.Find("missing") == nullptr);
}
TEST_CASE("patch paths cannot follow symlinks outside the game") {
    Fixture f, outside;
    outside.Write("secret", "private");
    std::error_code error;
    fs::create_directory_symlink(outside.root, f.root / "escape", error);
    if(error) return; // Windows hosts may not grant symlink creation rights.
    f.Write("aether.lua", "aether.add_file('stolen', aether.read_file('escape/secret'))");
    GameHooks hooks;
    CHECK_THROWS(hooks.Load(f.root, "advhd"));
}
TEST_CASE("zlib patch decoding rejects truncated payloads") {
    Fixture f;
    f.Write("aether.lua", R"(
        local data = string.char(120,156,203,72,205,201,201,7,0,6,44,2,21)
        aether.add_file('test', aether.decompress(data, 'zlib', 5))
        assert(not pcall(aether.decompress, data:sub(1,-2), 'zlib'))
        assert(not pcall(aether.decompress, data, 'zlib', 6))
    )");
    GameHooks hooks;
    hooks.Load(f.root, "yuris");
    REQUIRE(hooks.Find("test"));
    CHECK(std::string(hooks.Find("test")->begin(), hooks.Find("test")->end()) == "hello");
}

TEST_CASE("Lua patch transcodes validate the selected encoding") {
    Fixture f;
    f.Write("aether.lua", R"(
        local gbk = aether.transcode('中文', 'UTF-8', 'GBK')
        assert(gbk == string.char(0xd6,0xd0,0xce,0xc4))
        assert(aether.transcode(gbk, 'GBK') == '中文')
        assert(not pcall(aether.transcode, string.char(0x81), 'GBK'))
        aether.add_file('text', gbk)
    )");
    GameHooks hooks;
    hooks.Load(f.root, "softpal");
    CHECK(hooks.Find("text")->size() == 4);
}

TEST_CASE("Windows UTF8 BOM scripts load as text") {
    Fixture f;
    f.Write("aether.lua", "\xef\xbb\xbf" "aether.add_file('test', 'ok')");
    GameHooks hooks;
    hooks.Load(f.root, "bgi");
    CHECK(hooks.Find("test") != nullptr);
}
