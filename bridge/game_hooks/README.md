# Game-local Lua resource hooks

[简体中文](README.zh-CN.md) | English

BGI, YU-RIS, ADVHD, SoftPal, CatSystem2, Escude, SystemC and EntisGLS run
`aether.lua` from the selected game directory before loading scenario resources. The script runs once per
open, using a separate Lua 5.4 state. Registered resources override native
archives and loose files. A missing script preserves normal engine behavior;
a script error stops startup with an `aether.lua` diagnostic. Reopening a game
loads its script again and discards the previous game's replacements.

Lua is the fallback for formats the engine does not yet recognize. Native
translation discovery does not require `aether.lua`: YU-RIS reads unfiltered
XP3 packs containing YBN resources (zlib/zstd), SoftPal reads RPCK v1 bundles
with STRINGS.JSON in DLL RT_RCDATA, and BGI mounts the default AlwaysLoad view
of ChihanaPackerVer2.0 `.chs` packages. Discovery uses format signatures and
contents rather than game titles. DLLs are only read as data.

Resource precedence is explicit Lua replacements, native translation resources,
then original resources. SoftPal decodes RPCK images on demand and merges
Unicode text by native ID into a CP936 bank, retaining untranslated strings
and the font referenced by the patch module. BGI uses UTF-8 with CP932 fallback,
respects an explicit Japanese selection, and excludes optional image modules
and all-CG saves. YU-RIS retains automatic strict encoding validation.

```lua
assert(aether.engine == "bgi")
aether.set_encoding("GBK")
aether.mount_dir("translation")
aether.add_file("chapter01", aether.read_file("patch/chapter01.bin"))
if aether.exists("patch/font.ttf") then
    aether.set_font("patch/font.ttf")
end
aether.log("Translation resources loaded")
```

The `aether` table exposes:

| API | Meaning |
| --- | --- |
| `api_version` | `1` |
| `engine` | `bgi`, `yuris`, `advhd`, `softpal`, `catsystem2`, `escude`, `systemc`, or `entisgls` |
| `read_file(path [, offset [, size]])` | Read binary bytes from a game-relative physical file. Offsets are zero-based; omitted size reads to EOF. |
| `exists(path)` | Test whether a game-relative physical path exists. |
| `add_file(name, bytes)` | Register bytes under an engine resource name. Later registrations replace earlier ones. Empty replacements are supported. |
| `mount_dir(path)` | Register all files below a directory, relative to that directory. |
| `decompress(bytes, format [, size])` | Decode `zlib` or `zstd`. Supply size when the zstd frame omits it. An explicit size must match the decoded result. |
| `transcode(bytes, from [, to])` | Strict character conversion; `to` defaults to UTF-8. Invalid/unrepresentable text raises an error. |
| `set_encoding(name)` | Select the scenario encoding. The explicit patch selection overrides automatic detection and launcher encoding settings. |
| `set_font(path)` | Select a game-relative font file. |
| `log(message)` | Add a startup diagnostic to the engine log. |

Logical names normalize ASCII case and slash direction. Physical filenames
retain their case and Unicode spelling. Registrations contain native resource
bytes, before the engine's normal decoding; they do not replace executable
code. For example, YU-RIS accepts `ysbin/yst00001.ybn`, CatSystem2 accepts
`scene.cst`, and BGI accepts the name requested by its resource manager.
BGI and ADVHD overrides also apply when a script names an explicit archive.
YU-RIS and EntisGLS materialize their overlays in an owned host-cache directory
for consumers that require filesystem paths; that directory is removed when the
session releases it.

Escude includes Lua resources in VFS reads, existence checks, source discovery
and resource lists. Use logical paths such as `script/main.c`, matching the
archive mount prefix; Lua names are UTF-8 while the engine's resource paths
remain CP932. SystemC covers VFS reads, existence checks and resource lists,
including script selection. Both route streamed replacements through their
existing resource staging instead of opening an original loose file.

EntisGLS covers CSX and resources requested through the Cotopha environment,
including NOA members. Register the logical name, for example `adventure.csx`;
the adapter also recognizes reads through `storage://game/` and absolute paths
inside the game directory. Relative reads from replaced images can still find
original archive resources. Native game detection and launch configuration
discovery remain unchanged. Overrides exclude `savedata/` and preserve existing
save precedence and native write behavior. `set_font` takes precedence over
script-requested font families for this session, retaining the requested size
and style. Closing the session restores native font selection.

BGI, YU-RIS compiled scripts, ADVHD legacy scripts, SoftPal, CatSystem2 scenes,
Escude ACPX scripts and SystemC share all five explicit byte-text encodings:

| Canonical name | Aliases (ASCII case-insensitive) |
| --- | --- |
| `CP932` | `SJIS`, `Shift-JIS`, `Shift_JIS`, `ShiftJIS` |
| `GBK` | `CP936`, `GB2312` |
| `GB18030` | — |
| `BIG5` | `CP950`, `Big-5` |
| `UTF-8` | `UTF8` |

GB18030 four-byte characters and UTF-8 multibyte characters are consumed whole.
Unknown names fail with the common list of supported values. Omitting
`set_encoding` preserves each engine's existing detection and defaults.

Native Unicode formats retain their representation: modern ADVHD scripts use
UTF-8, and EntisGLS CSX has no global byte-encoding override and explicitly
rejects `set_encoding`. BGI retains its native CP932 fallback for UTF-8.
These format rules do not silently map unsupported names to CP932.

All eight engines use the same `aether` functions and the same shared
`GameHooks` implementation. Resource names and native script
formats remain engine-specific. This API registers startup
resources; it does not expose per-read or per-line Lua callbacks.
SoftPal additionally accepts `aether/softpal-text.bin`, a text-ID replacement
bank registered through the same `add_file` API. Its contract is documented in
the SoftPal package's `aether_runtime/examples/README.md`.
If native RPCK translations are present, Lua entries override only matching
IDs. The original DAT is decoded before the Unicode dictionary is converted
to the explicit Lua encoding (CP936 when omitted); Lua text-bank entries use that final encoding.

Lua has base, string, table, math and UTF-8 libraries, including `string.unpack`
and integer bit operations. It has no `io`, `os`, `package`, `debug`, filesystem
loaders or native-module loading. Reads are confined to the game directory,
including symlink resolution. Limits are 1 MiB of Lua source, 256 MiB per
resource/read or Lua heap, 512 MiB of registered resources, 65,536 files, and
100 million Lua instructions. The script finishes before the engine uses its
immutable resource table; no Lua callback runs on rendering/audio threads.

To validate a script without launching the game:

```sh
cmake --build <build-directory> --target aether_lua_probe
<build-directory>/bridge/game_hooks/aether_lua_probe <game-directory> bgi
```

Private engine packages carry example loaders for installed translation packs.
Only the Lua loader belongs in source control; game resources, extracted files,
fonts and save data do not.
