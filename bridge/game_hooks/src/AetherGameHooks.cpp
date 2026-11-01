#include "AetherGameHooks.h"
#include "AetherGb18030.h"
#include <lua.hpp>
#include <zlib.h>
#include <zstd.h>
#include <boost/locale/encoding.hpp>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <memory>
#include <random>
#include <stdexcept>
#include <string_view>

namespace aether::hooks {
namespace {
constexpr size_t kFileLimit = 256u * 1024u * 1024u;
constexpr size_t kOverlayLimit = 512u * 1024u * 1024u;
constexpr size_t kLuaLimit = 256u * 1024u * 1024u;
constexpr size_t kEntryLimit = 65536;
std::string Upper(std::string value) {
    for(char& c : value) if(c >= 'a' && c <= 'z') c -= 'a' - 'A';
    return value;
}
GameHooks::Bytes Read(const std::filesystem::path& path, uint64_t offset,
                     uint64_t length) {
    const auto size = std::filesystem::file_size(path);
    if(offset > size) throw std::runtime_error("file offset exceeds size");
    if(length == UINT64_MAX) length = size - offset;
    if(length > size - offset || length > kFileLimit)
        throw std::runtime_error("file read exceeds size or 256 MiB limit");
    GameHooks::Bytes bytes(static_cast<size_t>(length));
    std::ifstream stream(path, std::ios::binary);
    if(!stream.seekg(static_cast<std::streamoff>(offset)) ||
       (length && !stream.read(reinterpret_cast<char*>(bytes.data()), length)))
        throw std::runtime_error("cannot read patch file: " + path.filename().u8string());
    return bytes;
}
} // namespace

std::string GameHooks::ResourceKey(std::string name) {
    for(char& c : name) {
        if(c == '\\') c = '/';
        if(c >= 'A' && c <= 'Z') c += 'a' - 'A';
    }
    if(name.empty() || name.size() > 4096 || name.front() == '/' ||
       name.find(':') != std::string::npos || name.find('\0') != std::string::npos)
        throw std::runtime_error("invalid resource path");
    const auto path = std::filesystem::u8path(name);
    for(const auto& part : path)
        if(part == "..") throw std::runtime_error("resource path escapes game directory");
    name = path.lexically_normal().generic_u8string();
    if(name == "." || name.back() == '/') throw std::runtime_error("invalid resource path");
    return name;
}

struct GameHooks::Script {
    GameHooks output;
    std::filesystem::path root;
    size_t allocated = 0, overlay_bytes = 0;
    unsigned ticks = 0;
    Bytes scratch;
    std::string error;
    bool boolean_result = false;

    static std::string_view String(lua_State* state, int index) {
        if(lua_type(state, index) != LUA_TSTRING) throw std::runtime_error("expected a string argument");
        size_t size;
        const char* value = lua_tolstring(state, index, &size);
        return {value, size};
    }
    static lua_Integer Integer(lua_State* state, int index, lua_Integer fallback) {
        if(lua_isnoneornil(state, index)) return fallback;
        if(!lua_isinteger(state, index)) throw std::runtime_error("expected an integer argument");
        return lua_tointeger(state, index);
    }

    static void* Allocate(void* user, void* ptr, size_t old_size, size_t size) {
        auto& self = *static_cast<Script*>(user);
        if(!ptr) old_size = 0; // Lua passes a type tag for new allocations.
        if(size == 0) { std::free(ptr); self.allocated -= old_size; return nullptr; }
        if(size > kLuaLimit || self.allocated - old_size > kLuaLimit - size) return nullptr;
        void* result = std::realloc(ptr, size);
        if(result) self.allocated = self.allocated - old_size + size;
        return result;
    }
    static Script& Self(lua_State* state) {
        return **static_cast<Script**>(lua_getextraspace(state));
    }
    static void Budget(lua_State* state, lua_Debug*) {
        if(++Self(state).ticks > 10000) luaL_error(state, "aether.lua instruction limit exceeded");
    }
    std::filesystem::path Path(const std::string& name) const {
        // Validate components without lowercasing the physical filename.
        GameHooks::ResourceKey(name);
        auto normalized = name;
        std::replace(normalized.begin(), normalized.end(), '\\', '/');
        const auto path = std::filesystem::weakly_canonical(root / std::filesystem::u8path(normalized));
        const auto relative = path.lexically_relative(root);
        if(relative.empty() || relative.is_absolute()) throw std::runtime_error("patch path escapes game directory");
        for(const auto& part : relative)
            if(part == "..") throw std::runtime_error("patch symlink escapes game directory");
        return path;
    }
    void Add(const std::string& name, Bytes bytes) {
        const auto key = GameHooks::ResourceKey(name);
        const auto found = output.files_.find(key);
        const size_t old_size = found == output.files_.end() ? 0 : found->second.size();
        if(bytes.size() > kFileLimit || overlay_bytes - old_size > kOverlayLimit - bytes.size() ||
           (found == output.files_.end() && output.files_.size() >= kEntryLimit))
            throw std::runtime_error("patch overlay exceeds resource limit");
        overlay_bytes = overlay_bytes - old_size + bytes.size();
        output.files_[key] = std::move(bytes);
    }
    static int Call(lua_State* state) {
        // Every allocation/error that can longjmp through Lua happens after
        // Invoke's C++ objects have been destroyed, including out-of-memory.
        int result = -1;
        try { result = Self(state).Invoke(state, lua_tostring(state, lua_upvalueindex(1))); }
        catch(const std::exception& e) { Self(state).error = e.what(); }
        catch(...) { Self(state).error = "unknown patch hook failure"; }
        if(result == 0) return 0;
        if(result == 1) {
            lua_pushlstring(state, reinterpret_cast<const char*>(Self(state).scratch.data()), Self(state).scratch.size());
            Self(state).scratch.clear();
            return 1;
        }
        if(result == 2) { lua_pushboolean(state, Self(state).boolean_result); return 1; }
        luaL_where(state, 1);
        lua_pushlstring(state, Self(state).error.data(), Self(state).error.size());
        lua_concat(state, 2);
        return lua_error(state);
    }
    int Invoke(lua_State* state, std::string_view operation) {
        const auto input = String(state, 1);
        const char* first = input.data();
        const auto length = input.size();
        if(operation == "read_file") {
            const auto offset = Integer(state, 2, 0);
            const auto size = Integer(state, 3, -1);
            if(offset < 0 || size < -1) throw std::runtime_error("negative file range");
            scratch = Read(Path(std::string(first, length)), offset, size < 0 ? UINT64_MAX : uint64_t(size));
            return 1;
        }
        if(operation == "exists") {
            boolean_result = std::filesystem::exists(Path(std::string(first, length)));
            return 2;
        }
        if(operation == "transcode") {
            const std::string from(String(state, 2));
            const std::string to(lua_isnoneornil(state, 3) ? std::string_view("UTF-8") : String(state, 3));
            if(length > kFileLimit) throw std::runtime_error("text conversion exceeds limit");
            const auto convert = [](std::string_view bytes, const std::string& from, const std::string& to) {
                return boost::locale::conv::between(bytes.data(), bytes.data() + bytes.size(), to, from, boost::locale::conv::stop);
            };
            std::string converted;
            if(Upper(from) == "GB18030" || Upper(to) == "GB18030") {
                const auto decode = [&](std::string_view bytes) { return convert(bytes, from, "UTF-8"); };
                const auto utf8 = Upper(from) == "GB18030" ? aether::text::Gb18030ToUtf8(input, decode) : decode(input);
                const auto encode = [&](std::string_view bytes) { return convert(bytes, "UTF-8", to); };
                converted = Upper(to) == "GB18030" ? aether::text::Utf8ToGb18030(utf8, encode) : encode(utf8);
            } else converted = convert(input, from, to);
            scratch.assign(converted.begin(), converted.end());
            return 1;
        }
        if(operation == "add_file") {
            const auto bytes = String(state, 2);
            if(bytes.size() > kFileLimit) throw std::runtime_error("patch file exceeds 256 MiB limit");
            Add(std::string(first, length), Bytes(bytes.begin(), bytes.end()));
            return 0;
        }
        if(operation == "mount_dir") {
            const auto directory = Path(std::string(first, length));
            if(!std::filesystem::is_directory(directory)) throw std::runtime_error("patch directory does not exist");
            for(const auto& file : std::filesystem::recursive_directory_iterator(directory)) {
                if(file.is_symlink()) throw std::runtime_error("patch directories cannot contain symlinks");
                if(file.is_regular_file())
                    Add(file.path().lexically_relative(directory).generic_u8string(), Read(file.path(), 0, UINT64_MAX));
            }
            return 0;
        }
        if(operation == "set_encoding") {
            auto encoding = Upper(std::string(first, length));
            if(encoding == "SJIS" || encoding == "SHIFT-JIS" || encoding == "SHIFT_JIS" || encoding == "SHIFTJIS") encoding = "CP932";
            if(encoding == "CP936" || encoding == "GB2312") encoding = "GBK";
            if(encoding == "CP950" || encoding == "BIG-5") encoding = "BIG5";
            if(encoding == "UTF8") encoding = "UTF-8";
            if(encoding != "CP932" && encoding != "GBK" && encoding != "GB18030" &&
               encoding != "BIG5" && encoding != "UTF-8")
                throw std::runtime_error("unsupported text encoding; expected CP932, GBK, GB18030, BIG5 or UTF-8");
            output.encoding_ = std::move(encoding);
            return 0;
        }
        if(operation == "set_font") {
            output.font_ = Path(std::string(first, length));
            if(!std::filesystem::is_regular_file(output.font_)) throw std::runtime_error("patch font does not exist");
            return 0;
        }
        if(operation == "log") {
            if(length > 4096 || output.messages_.size() >= 128) throw std::runtime_error("patch log limit exceeded");
            output.messages_.emplace_back(first, length);
            return 0;
        }
        if(operation == "decompress") {
            const auto format = String(state, 2);
            const auto expected = Integer(state, 3, -1);
            if(expected < -1 || expected > kFileLimit || length > kFileLimit)
                throw std::runtime_error("decompression size exceeds limit");
            scratch.clear();
            if(format == "zstd") {
                auto size = expected < 0 ? ZSTD_getFrameContentSize(first, length) : uint64_t(expected);
                if(size > kFileLimit) throw std::runtime_error("zstd requires a valid decompressed size");
                scratch.resize(size);
                const auto result = ZSTD_decompress(scratch.data(), scratch.size(), first, length);
                if(ZSTD_isError(result) || result != size) throw std::runtime_error("invalid zstd patch data");
            } else if(format == "zlib") {
                z_stream stream{};
                stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(first));
                stream.avail_in = static_cast<uInt>(length);
                if(inflateInit(&stream) != Z_OK) throw std::runtime_error("cannot initialize zlib");
                struct End { z_stream* stream; ~End() { inflateEnd(stream); } } end{&stream};
                std::array<uint8_t, 32768> chunk{};
                int result;
                do {
                    stream.next_out = chunk.data(); stream.avail_out = chunk.size();
                    result = inflate(&stream, Z_NO_FLUSH);
                    const auto produced = chunk.size() - stream.avail_out;
                    if(scratch.size() > kFileLimit - produced) throw std::runtime_error("decompressed patch exceeds limit");
                    scratch.insert(scratch.end(), chunk.begin(), chunk.begin() + produced);
                } while(result == Z_OK);
                if(result != Z_STREAM_END || stream.avail_in != 0 ||
                   (expected >= 0 && scratch.size() != uint64_t(expected)))
                    throw std::runtime_error("invalid zlib patch data");
            } else throw std::runtime_error("decompression format must be zlib or zstd");
            return 1;
        }
        throw std::runtime_error("unknown patch operation");
    }
    static int Initialize(lua_State* state) {
        for(const auto& library : std::array<std::pair<const char*, lua_CFunction>, 5>{{
                {"_G", luaopen_base}, {LUA_STRLIBNAME, luaopen_string},
                {LUA_TABLIBNAME, luaopen_table}, {LUA_MATHLIBNAME, luaopen_math},
                {LUA_UTF8LIBNAME, luaopen_utf8}}}) {
            luaL_requiref(state, library.first, library.second, 1); lua_pop(state, 1);
        }
        for(const char* name : {"dofile", "loadfile", "load", "collectgarbage", "print"}) {
            lua_pushnil(state); lua_setglobal(state, name);
        }
        lua_newtable(state);
        for(const char* name : {"read_file", "exists", "add_file", "mount_dir", "set_encoding", "set_font", "log", "decompress", "transcode"}) {
            lua_pushstring(state, name); lua_pushcclosure(state, Call, 1); lua_setfield(state, -2, name);
        }
        lua_pushvalue(state, 1); lua_setfield(state, -2, "engine");
        lua_pushinteger(state, 1); lua_setfield(state, -2, "api_version");
        lua_setglobal(state, "aether");
        return 0;
    }
};

void GameHooks::Load(const std::filesystem::path& root, const std::string& engine) {
    *this = GameHooks{};
    Script script;
    script.root = std::filesystem::canonical(root);
    const auto path = script.Path("aether.lua");
    if(!std::filesystem::exists(path)) return;
    if(std::filesystem::file_size(path) > 1024 * 1024) throw std::runtime_error("aether.lua exceeds 1 MiB limit");
    const auto source = Read(path, 0, UINT64_MAX);
    std::string_view script_source(reinterpret_cast<const char*>(source.data()), source.size());
    if(script_source.substr(0, 3) == "\xef\xbb\xbf") script_source.remove_prefix(3);
    std::unique_ptr<lua_State, decltype(&lua_close)> state(lua_newstate(Script::Allocate, &script), lua_close);
    if(!state) throw std::runtime_error("cannot create aether.lua state");
    *static_cast<Script**>(lua_getextraspace(state.get())) = &script;
    lua_sethook(state.get(), Script::Budget, LUA_MASKCOUNT, 10000);
    lua_pushcfunction(state.get(), Script::Initialize);
    lua_pushlstring(state.get(), engine.data(), engine.size());
    int result = lua_pcall(state.get(), 1, 0, 0);
    if(result == LUA_OK) result = luaL_loadbufferx(state.get(), script_source.data(), script_source.size(), "@aether.lua", "t");
    if(result == LUA_OK) result = lua_pcall(state.get(), 0, 0, 0);
    if(result != LUA_OK) {
        const char* message = lua_type(state.get(), -1) == LUA_TSTRING ? lua_tostring(state.get(), -1) : nullptr;
        throw std::runtime_error(std::string("aether.lua: ") + (message ? message : "script failed"));
    }
    script.output.active_ = true;
    *this = std::move(script.output);
}

const GameHooks::Bytes* GameHooks::Find(const std::string& name) const {
    if(files_.empty()) return nullptr;
    std::string key;
    try { key = ResourceKey(name); } catch(const std::runtime_error&) { return nullptr; }
    const auto found = files_.find(key);
    return found == files_.end() ? nullptr : &found->second;
}
void GameHooks::RequireEncoding(const std::vector<std::string>& supported) const {
    if(!encoding_.empty() && std::find(supported.begin(), supported.end(), encoding_) == supported.end())
        throw std::runtime_error("aether.lua: this engine does not support " + encoding_);
}
void GameHooks::Materialize(const std::filesystem::path& directory) const {
    std::filesystem::create_directories(directory);
    for(const auto& [name, bytes] : files_) {
        const auto path = directory / std::filesystem::u8path(name);
        std::filesystem::create_directories(path.parent_path());
        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        if(!output.write(reinterpret_cast<const char*>(bytes.data()), bytes.size()))
            throw std::runtime_error("aether.lua: cannot write resource cache");
    }
}

struct GameHooks::Cache {
    std::filesystem::path path;
    ~Cache() { std::error_code ignored; std::filesystem::remove_all(path, ignored); }
};
std::filesystem::path GameHooks::CacheDirectory(const std::filesystem::path& parent) const {
    if(files_.empty()) return {};
    if(cache_) return cache_->path;
    if(parent.empty()) throw std::runtime_error("aether.lua: resource overlay requires a host cache directory");
    std::filesystem::create_directories(parent);
    std::random_device random;
    auto cache = std::make_shared<Cache>();
    for(int attempt = 0; attempt < 32; ++attempt) {
        const auto candidate = parent / ("aether-lua-" + std::to_string(random()) + "-" + std::to_string(random()));
        if(std::filesystem::create_directory(candidate)) { cache->path = candidate; break; }
    }
    if(cache->path.empty()) throw std::runtime_error("aether.lua: cannot create resource cache");
    Materialize(cache->path);
    cache_ = std::move(cache);
    return cache_->path;
}

} // namespace aether::hooks
