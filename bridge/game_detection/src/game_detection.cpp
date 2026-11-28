#include "aether/game_detection.h"

#include "engine_runtime_provider.h"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <optional>

namespace aether::game_detection {
namespace {

using namespace std::string_view_literals;
using Json = nlohmann::json;
using Names = std::vector<std::string>;
constexpr size_t kMaxText = 1024 * 1024;
constexpr uint64_t kMaxAsarBytes = 32ull * 1024 * 1024 * 1024;

std::string Join(const std::string &base, std::string_view relative) {
    if (base.empty() || base.back() == '/' || base.back() == '\\') {
        return base + std::string(relative);
    }
    return base + "/" + std::string(relative);
}

std::string_view FileName(std::string_view path) {
    const auto slash = path.find_last_of("/\\");
    return slash == path.npos ? path : path.substr(slash + 1);
}

std::string Parent(std::string_view path) {
    const auto slash = path.find_last_of("/\\");
    if (slash == path.npos) {
        return {};
    }
    const auto scheme = path.find("://");
    const bool root = slash == 0 || path[slash - 1] == ':' ||
                      (scheme != path.npos && slash == scheme + 2);
    return std::string(path.substr(0, slash + root));
}

std::string_view Extension(std::string_view name) {
    name = FileName(name);
    const auto dot = name.rfind('.');
    return dot == name.npos ? ""sv : name.substr(dot + 1);
}

bool StartsWith(std::string_view value, std::string_view prefix) {
    return value.substr(0, prefix.size()) == prefix;
}

bool EndsWith(std::string_view value, std::string_view suffix) {
    return value.size() >= suffix.size() && value.substr(value.size() - suffix.size()) == suffix;
}

bool Has(const Names &names, std::string_view value) {
    return std::find(names.begin(), names.end(), value) != names.end();
}

bool HasExtension(const Names &names, std::string_view extension) {
    return std::any_of(names.begin(), names.end(), [&](const auto &name) {
        return Extension(name) == extension;
    });
}

Names FileNames(const Files &files, const std::string &root) {
    Names names;
    for (const auto &entry : files.List(root, false)) {
        if (!entry.directory) {
            names.push_back(files.Lower(entry.name));
        }
    }
    return names;
}

std::string_view Trim(std::string_view text) {
    while (!text.empty() && static_cast<unsigned char>(text.front()) <= 32) {
        text.remove_prefix(1);
    }
    while (!text.empty() && static_cast<unsigned char>(text.back()) <= 32) {
        text.remove_suffix(1);
    }
    return text;
}

std::string ValueAfter(const Files &files, std::string_view text, std::string_view key) {
    while (!text.empty()) {
        const auto end = text.find('\n');
        const auto line = text.substr(0, end);
        const auto equal = line.find('=');
        if (equal != line.npos && files.Lower(Trim(line.substr(0, equal))) == key) {
            return std::string(Trim(line.substr(equal + 1)));
        }
        if (end == text.npos) {
            break;
        }
        text.remove_prefix(end + 1);
    }
    return {};
}

std::string ReadText(const Files &files, const std::string &path) {
    auto file = files.Open(path);
    if (!file || file->Size() > kMaxText) {
        return {};
    }
    auto text = file->Read(0, static_cast<size_t>(file->Size()));
    if (StartsWith(text, "\xef\xbb\xbf"sv)) {
        text.erase(0, 3);
    }
    return text;
}

std::optional<uint32_t> UnsignedLE(File &file, uint64_t offset, size_t width) {
    const auto bytes = file.Read(offset, width);
    if (bytes.size() != width) {
        return std::nullopt;
    }
    uint32_t value = 0;
    for (size_t index = 0; index < width; ++index) {
        value |= static_cast<uint32_t>(static_cast<unsigned char>(bytes[index])) << (8 * index);
    }
    return value;
}

Json ParseLegacyJson(std::string_view text) {
    auto parsed = Json::parse(text, nullptr, false);
    if (!parsed.is_discarded()) {
        return parsed;
    }

    // Godot JSON also accepts trailing commas and literal control characters
    // in strings. Normalize only those forms before the same JSON parse.
    std::string normalized;
    bool quoted = false;
    bool escaped = false;
    for (size_t i = 0; i < text.size(); ++i) {
        const auto byte = static_cast<unsigned char>(text[i]);
        if (quoted && !escaped && byte < 32) {
            constexpr char hex[] = "0123456789abcdef";
            normalized += "\\u00";
            normalized += hex[byte >> 4];
            normalized += hex[byte & 15];
            continue;
        }
        if (!quoted && byte == ',') {
            const auto next = text.find_first_not_of(" \t\r\n", i + 1);
            const auto prev = normalized.find_last_not_of(" \t\r\n");
            if (next != text.npos && prev != normalized.npos &&
                (text[next] == '}' || text[next] == ']') &&
                normalized[prev] != '{' && normalized[prev] != '[') {
                continue;
            }
        }
        if (byte == '"' && !escaped) {
            quoted = !quoted;
        }
        escaped = quoted && byte == '\\' && !escaped;
        normalized += static_cast<char>(byte);
    }
    return Json::parse(normalized, nullptr, false);
}

std::optional<uint64_t> AsarInteger(const Json &value) {
    if (value.is_string()) {
        const auto &text = value.get_ref<const std::string &>();
        if (text.empty() || text.size() > 16) {
            return std::nullopt;
        }
        uint64_t number = 0;
        for (const auto digit : text) {
            if (digit < '0' || digit > '9') {
                return std::nullopt;
            }
            number = number * 10 + digit - '0';
        }
        return number;
    }
    if (value.is_number()) {
        const auto number = value.get<double>();
        if (number >= 0 && number <= kMaxAsarBytes &&
            number == static_cast<uint64_t>(number)) {
            return static_cast<uint64_t>(number);
        }
    }
    return std::nullopt;
}

constexpr std::array kTyranoMarkers = {
    "index.html"sv, "tyrano/tyrano.js"sv, "tyrano/plugins/kag/kag.js"sv,
    "data/system/Config.tjs"sv,
};

struct AsarIndex {
    uint64_t available;
    uint64_t total = 0;
    size_t members = 0;
    std::array<bool, kTyranoMarkers.size()> markers{};

    bool ReadDirectory(const Json &node, const std::string &prefix, int depth) {
        if (depth > 64 || !node.is_object()) {
            return false;
        }
        const auto files = node.find("files");
        if (files == node.end() || !files->is_object()) {
            return false;
        }
        for (auto it = files->begin(); it != files->end(); ++it) {
            const auto &name = it.key();
            if (name.empty() || name == "." || name == ".." ||
                name.find_first_of("/\\:") != name.npos || name.find('\0') != name.npos ||
                !it->is_object() || it->contains("link")) {
                return false;
            }
            const std::string relative = prefix + name;
            if (it->contains("files")) {
                if (!ReadDirectory(*it, relative + "/", depth + 1)) {
                    return false;
                }
                continue;
            }
            if (++members > 100000 || !ReadFile(*it)) {
                return false;
            }
            const auto marker = std::find(kTyranoMarkers.begin(), kTyranoMarkers.end(), relative);
            if (marker != kTyranoMarkers.end()) {
                markers[marker - kTyranoMarkers.begin()] = true;
            }
        }
        return true;
    }

    bool ReadFile(const Json &entry) {
        const auto size = AsarInteger(entry.value("size", Json{}));
        if (!size || *size > kMaxAsarBytes - total) {
            return false;
        }
        if (entry.value("unpacked", Json{}) != Json(true)) {
            const auto offset = AsarInteger(entry.value("offset", Json{}));
            if (!offset || *offset > available || *size > available - *offset) {
                return false;
            }
        }
        total += *size;
        return true;
    }
};

bool IsTyranoArchive(const Files &files, const std::string &path) {
    auto file = files.Open(path);
    if (!file || file->Size() < 16 || UnsignedLE(*file, 0, 4) != 4) {
        return false;
    }
    const uint64_t header = UnsignedLE(*file, 4, 4).value_or(0);
    const uint32_t pickle = UnsignedLE(*file, 8, 4).value_or(0);
    const uint32_t json_size = UnsignedLE(*file, 12, 4).value_or(0);
    if (header < 8 || header > 16 * kMaxText || header % 4 != 0 ||
        8 + header > file->Size() || pickle != header - 4 ||
        json_size < 2 || json_size > header - 8 || header - 8 - json_size > 3) {
        return false;
    }
    AsarIndex index{file->Size() - 8 - header};
    return index.ReadDirectory(ParseLegacyJson(file->Read(16, json_size)), "", 0) &&
           std::all_of(index.markers.begin(), index.markers.end(), [](bool present) { return present; });
}

bool HasRenpyScripts(const Files &files, const std::string &root, int depth) {
    const auto entries = files.List(root, false);
    for (const auto &entry : entries) {
        if (entry.directory) {
            continue;
        }
        const auto extension = files.Lower(Extension(entry.name));
        if (extension == "rpy") {
            return true;
        }
        if (extension == "rpyc" || extension == "rpa") {
            auto file = files.Open(Join(root, entry.name));
            const auto signature = file ? file->Read(0, 10) : std::string();
            if ((extension == "rpyc" && StartsWith(signature, "RENPY RPC2")) ||
                (extension == "rpa" && (StartsWith(signature, "RPA-3.0 ") ||
                                        StartsWith(signature, "RPA-2.0 ")))) {
                return true;
            }
        }
    }
    if (depth == 0) {
        return false;
    }
    constexpr std::array ignored = {"cache"sv, "saves"sv, "savedata"sv, "renpy"sv, "lib"sv, ".git"sv};
    for (const auto &entry : entries) {
        if (entry.directory && !entry.symlink &&
            std::find(ignored.begin(), ignored.end(), entry.name) == ignored.end() &&
            HasRenpyScripts(files, Join(root, entry.name), depth - 1)) {
            return true;
        }
    }
    return false;
}

bool IsHcb(File &file) {
    const auto length = file.Size();
    if (length < 17 || length > 64 * kMaxText) {
        return false;
    }
    const auto descriptor = UnsignedLE(file, 0, 4).value_or(0);
    if (descriptor < 4 || descriptor > length - 13) {
        return false;
    }
    const auto start = UnsignedLE(file, descriptor, 4).value_or(0);
    if (start < 4 || start >= descriptor || UnsignedLE(file, descriptor + 8, 1).value_or(16) > 15) {
        return false;
    }
    uint64_t position = descriptor + 11 + UnsignedLE(file, descriptor + 10, 1).value_or(0);
    if (position + 4 > length) {
        return false;
    }
    const auto syscalls = UnsignedLE(file, position, 2).value_or(0);
    position += 2;
    for (uint32_t index = 0; index < syscalls; ++index) {
        if (position + 2 > length) {
            return false;
        }
        position += 2 + UnsignedLE(file, position + 1, 1).value_or(0);
        if (position + 2 > length) {
            return false;
        }
    }
    return position + 2 <= length;
}

std::string HcbLaunchFile(const Files &files, const std::string &root, const std::string &requested) {
    Names entries;
    for (const auto &entry : files.List(root, true)) {
        if (!entry.directory && files.Lower(Extension(entry.name)) == "hcb") {
            auto file = files.Open(Join(root, entry.name));
            if (file && IsHcb(*file)) {
                entries.push_back(entry.name);
            }
        }
    }
    std::sort(entries.begin(), entries.end());
    if (files.FileExists(requested) && Has(entries, FileName(requested))) {
        return std::string(FileName(requested));
    }
    const auto visible = std::find_if(entries.begin(), entries.end(), [](const auto &entry) {
        return !StartsWith(entry, ".");
    });
    return visible != entries.end() ? *visible : (entries.empty() ? "" : entries.front());
}

bool IsN2Profile(const Json &profile) {
    if (!profile.is_object() || !profile.contains("activeProfile")) {
        return false;
    }
    const auto &active = profile["activeProfile"];
    Json selected = profile;
    if (!active.is_null()) {
        const auto profiles = profile.find("profiles");
        if (!active.is_string() || profiles == profile.end() || !profiles->is_object()) {
            return false;
        }
        const auto entry = profiles->find(active.get_ref<const std::string &>());
        if (entry == profiles->end() || !entry->is_object()) {
            return false;
        }
        selected.update(*entry);
    }
    return selected.value("product.name", Json{}).is_string() &&
           selected.value("designResolution", Json{}).is_string();
}

bool IsN2Directory(const Files &files, const std::string &root) {
    int npa = 0;
    int pak = 0;
    Names names;
    for (const auto &entry : files.List(root, false)) {
        if (entry.directory) {
            continue;
        }
        const auto name = files.Lower(entry.name);
        names.push_back(name);
        if (name == "aether-n2system.json" ||
            (name == "profiles.json" && IsN2Profile(ParseLegacyJson(ReadText(files, Join(root, entry.name)))))) {
            return true;
        }
        if (name == "script.pak" || name == "system.pak") {
            auto file = files.Open(Join(root, entry.name));
            if (file && file->Size() >= 0x108 && UnsignedLE(*file, 0, 4) == 3 &&
                UnsignedLE(*file, 0x104, 4) == 100) {
                ++pak;
            }
        }
        if (name == "nss.npa" || name == "system.npa") {
            auto file = files.Open(Join(root, entry.name));
            if (file && file->Read(0, 7) == "NPA\x01\0\0\0"sv) {
                ++npa;
            }
        }
    }
    return npa == 2 || (pak == 2 &&
           (Has(names, "sys.ini") || Has(names, "sys_cn.ini")) &&
           (Has(names, "game.ini") || Has(names, "game_cn.ini")));
}

bool IsCmvs(const Files &files, const std::string &root) {
    const auto pack = Join(root, "data/pack");
    auto archive = files.Open(Join(pack, "script.cpz"));
    if (!archive || archive->Read(0, 3) != "CPZ") {
        return false;
    }
    for (auto name : {"start.ps3", "start.ps2"}) {
        auto script = files.Open(Join(pack, name));
        if (script && script->Read(0, 4) == "PS2A") {
            return true;
        }
    }
    return false;
}

bool IsCompiledYuris(const Files &files, const std::string &root, const Names &names) {
    for (auto name : {"ysbin/yscfg.ybn", "ysbin/ysc.ybn", "yscfg.ybn", "ysc.ybn"}) {
        auto script = files.Open(Join(root, name));
        if (script && script->Size() >= 16) {
            const auto magic = script->Read(0, 4);
            if (magic == "YSCF" || magic == "YSCM") {
                return true;
            }
        }
    }
    const auto has_pack = [&](const std::string &base, const Names &entries) {
        for (const auto &name : entries) {
            if (Extension(name) == "ypf") {
                // The Godot scanner opens the folded name on this path.
                auto archive = files.Open(Join(base, name));
                if (archive && archive->Size() >= 32 && archive->Read(0, 4) == "YPF\0"sv) {
                    return true;
                }
            }
        }
        return false;
    };
    const auto pac = Join(root, "pac");
    return has_pack(root, names) || has_pack(pac, FileNames(files, pac));
}

bool IsCatSystem(const Names &names) {
    const bool has_int = HasExtension(names, "int");
    const bool boot = Has(names, "boot.dfn");
    return (Has(names, "cs2.exe") && (has_int || boot)) ||
           (boot && Has(names, "kcs.int") && (Has(names, "cs2confx.dll") || has_int));
}

std::string KiriKiriLaunchFile(const Files &files, const std::string &root, const Names &names) {
    if (Has(names, "startup.tjs") || Has(FileNames(files, Join(root, "data")), "startup.tjs")) {
        return {};
    }
    std::string executable;
    std::string archive;
    for (const auto &entry : files.List(root, false)) {
        if (entry.directory) {
            continue;
        }
        const auto lower = files.Lower(entry.name);
        if (lower == "data.xp3") {
            return entry.name;
        }
        if (Extension(lower) == "xp3" && archive.empty()) {
            archive = entry.name;
        }
        if (Extension(lower) == "exe" && executable.empty()) {
            executable = entry.name;
        }
    }
    return archive.empty() ? executable : archive;
}

void Match(Result &result, const char *engine, const char *signal) {
    result.engine = engine;
    result.signals.emplace_back(signal);
}

} // namespace

std::string Files::Lower(std::string_view text) const {
    std::string lower;
    for (size_t index = 0; index < text.size(); ++index) {
        const char byte = text[index];
        const auto rest = text.substr(index);
        if (StartsWith(rest, "\xc4\xb0"sv)) {
            lower += 'i';
            ++index;
        } else if (StartsWith(rest, "\xe2\x84\xaa"sv)) {
            lower += 'k';
            index += 2;
        } else {
            lower += byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte;
        }
    }
    return lower;
}

std::string TyranoEntry(const Files &files, const std::string &root) {
    for (auto entry : {"index.html", "resources/app/index.html", "app/index.html"}) {
        const auto base = Parent(Join(root, entry));
        if (std::all_of(kTyranoMarkers.begin(), kTyranoMarkers.end(), [&](auto marker) {
                return files.FileExists(Join(base, marker));
            })) {
            return entry;
        }
    }
    for (auto entry : {"resources/app.asar", "app.asar"}) {
        if (IsTyranoArchive(files, Join(root, entry))) {
            return entry;
        }
    }
    return {};
}

std::string RenpyDirectory(const Files &files, const std::string &root) {
    for (auto relative : {"game"sv, "Contents/Resources/autorun/game"sv, "."sv}) {
        const int depth = relative != "." || files.Lower(FileName(root)) == "game" ? 3 : 0;
        if (HasRenpyScripts(files, Join(root, relative), depth)) {
            return std::string(relative);
        }
    }
    return {};
}

Result Inspect(const Files &files, const std::string &path) {
    Result result;
    result.root = files.FileExists(path) ? Parent(path) : path;
    if (result.root.empty() || !files.DirectoryExists(result.root)) {
        return result;
    }

    const auto &root = result.root;
    const auto names = FileNames(files, root);
    const auto tyrano = TyranoEntry(files, root);
    const auto renpy = RenpyDirectory(files, root);
    const auto hcb = HcbLaunchFile(files, root, path);
    const auto ini = Has(names, "system.ini") ? ReadText(files, Join(root, "system.ini")) : "";
    const bool pfs = HasExtension(names, "pfs");
    const bool artemis_boot = pfs && EndsWith(files.Lower(ValueAfter(files, ini, "boot")), ".iet");
    if (!tyrano.empty()) {
        Match(result, "tyranoscript", EndsWith(tyrano, ".asar") ?
              "tyranoscript-asar-project" : "tyranoscript-web-project");
        result.launch_file = tyrano;
    } else if (!renpy.empty()) {
        Match(result, "renpy", "renpy-game-directory");
        result.renpy_directory = renpy;
    } else if (IsN2Directory(files, root)) {
        Match(result, "n2system", "n2system-profile-or-npa");
    } else if (((Has(names, "system40.ini") || Has(names, "alicestart.ini")) && HasExtension(names, "ain")) ||
               (Has(names, "alicestart2.ini") && Has(names, "haru_c.ain")) ||
               (Has(names, "alicestart.chs") && Has(names, "chs.tbl") &&
                (HasExtension(names, "ain") || std::any_of(names.begin(), names.end(), [](const auto &name) {
                    return name != "alicestart.chs" && EndsWith(name, ".chs");
                })))) {
        Match(result, "xsystem4", "system4-ain-ini");
    } else if (Has(names, "adisk.ald") || std::any_of(names.begin(), names.end(), [](const auto &name) {
                   return EndsWith(name, "sa.ald");
               })) {
        Match(result, "xsystem35", "system35-scenario-ald");
    } else if ((Has(names, "adisk.dat") || Has(names, "gdisk.dat") ||
                Has(names, "agame.dat") || Has(names, "adisk.pat")) &&
               (Has(names, "acg.dat") || Has(names, "gcg.dat"))) {
        Match(result, "system3", "system3-dat");
    } else if (IsCmvs(files, root)) {
        Match(result, "cmvs", "cmvs-ps2a-cpz");
    } else if (Has(names, "exhibit.ini") &&
               (HasExtension(names, "rld") || HasExtension(FileNames(files, Join(root, "rld")), "rld"))) {
        Match(result, "exhibit", "exhibit-ini-rld");
    } else if (!hcb.empty()) {
        Match(result, "rfvp", "fvp-hcb");
        result.launch_file = hcb;
    } else if (Has(names, "0.txt") || Has(names, "00.txt") || Has(names, "nscr_sec.dat") ||
               Has(names, "nscript.___") || Has(names, "nscript.dat") ||
               std::any_of(names.begin(), names.end(), [](const auto &name) { return StartsWith(name, "onscript.nt"); })) {
        Match(result, "onscripter", "onscript-marker");
    } else if (IsCatSystem(names)) {
        Match(result, "catsystem2", "catsystem2-marker");
    } else if (Has(names, "yu-ris.exe") || files.FileExists(Join(root, "data/script/system_start.yst")) ||
               files.FileExists(Join(root, "data/script/system_start.txt")) || IsCompiledYuris(files, root, names)) {
        Match(result, "yuris", "yuris-marker");
        if (Has(names, "yu-ris.exe")) {
            result.launch_file = "yu-ris.exe";
        }
    } else if (Has(names, "system.ini") && (files.Lower(ini).find("artemis") != std::string::npos || artemis_boot)) {
        Match(result, "artemis", "artemis-system-ini");
        if (artemis_boot) {
            result.signals.emplace_back("artemis-pfs-boot");
        }
    } else if (pfs && !HasExtension(names, "xp3")) {
        Match(result, "artemis", "artemis-pfs-archive");
    } else if (Has(names, "gameexe.ini") || Has(names, "gameexe.dat") || Has(names, "scene.pck")) {
        Match(result, "siglus", "siglus-marker");
    } else if (Has(names, "script.mpk") && Has(names, "system.mpk") &&
               (Has(names, "bg1.mpk") || Has(names, "chara.mpk") || Has(names, "model.mpk"))) {
        Match(result, "mages", "mages-mpk-marker");
    } else {
        Match(result, "kirikiri", "kirikiri-xp3-or-default");
        result.launch_file = KiriKiriLaunchFile(files, root, names);
    }

    // This also preserves the metadata signals stored in existing library entries.
    for (auto marker : {"README.md", "title.ini", "title.ks", "startup.tjs", "config.tjs"}) {
        if (files.FileExists(Join(root, marker))) {
            result.signals.emplace_back(std::string("content:") + marker);
        }
    }
    return result;
}

Result InspectFlash(const Files &files, const std::string &path) {
    Result result;
    result.engine.clear();
    if (files.Lower(Extension(path)) == "swf" && files.FileExists(path)) {
        Match(result, "flash", "flash-swf-extension");
        result.root = Parent(path);
        result.launch_file = std::string(FileName(path));
    }
    return result;
}

void ApplyProviderProbes(Result &result, const std::string &root, const ProviderProbe &probe) {
    if (result.engine != "kirikiri") {
        return;
    }
    // Preserve the Godot fallback order and thresholds, independently of the
    // engine API's auto dispatch order.
    constexpr std::pair<const char *, int32_t> order[] = {
        {"exhibit", 1}, {"systemc", 1}, {"escude", 90}, {"entisgls", 90},
        {"advhd", 90}, {"bgi", 90}, {"yuris", 1}, {"catsystem2", 1},
        {"softpal", 1}, {"minori", 1}, {"wa2", 1}, {"mages", 1}, {"n2system", 1},
    };
    for (const auto &[engine, minimum] : order) {
        const auto score = probe(engine, root.c_str());
        if (score >= minimum) {
            result.engine = engine;
            result.provider_score = score;
            return;
        }
    }
}

void ApplyProviderProbes(Result &result, const std::string &root) {
    ApplyProviderProbes(result, root, engine_probe_runtime_provider);
}

Result DetectGame(const std::string &path) {
    auto result = Inspect(DiskFiles(), path);
    ApplyProviderProbes(result, result.root);
    return result;
}

} // namespace aether::game_detection
