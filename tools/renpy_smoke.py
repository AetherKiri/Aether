#!/usr/bin/env python3
"""Exercise the desktop Ren'Py host with an external SDK and an original fixture.

No upstream engine code or assets are copied into tracked repository files.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pickle
import re
import shutil
import subprocess
import uuid
import zipfile
import zlib


def run(command, log, env, marker=None, timeout=180):
    with log.open("w") as stream:
        result = subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    text = log.read_text(errors="replace")
    if result.returncode or re.search(r"SCRIPT ERROR:|^ERROR:", text, re.MULTILINE) or (marker and marker not in text):
        raise RuntimeError(f"Check failed (exit {result.returncode}): {log}\n" + "\n".join(text.splitlines()[-50:]))


def tree_hash(root):
    return {str(path.relative_to(root)): hashlib.file_digest(path.open("rb"), "sha256").hexdigest()
            for path in root.rglob("*") if path.is_file()}


def pack_fixture(game):
    """Write only this original fixture into the documented RPA-3.0 container."""
    files = sorted(path for path in game.rglob("*") if path.is_file() and path.suffix in {".rpyc", ".ttf"})
    archive = game / "archive.rpa"
    index = {}
    key = 0xA37E2026
    with archive.open("wb") as stream:
        stream.write(b"RPA-3.0 0000000000000000 00000000\n")
        for path in files:
            data = path.read_bytes()
            offset = stream.tell()
            stream.write(data)
            index[path.relative_to(game).as_posix()] = [(offset ^ key, len(data) ^ key, b"")]
        index_offset = stream.tell()
        stream.write(zlib.compress(pickle.dumps(index, protocol=2)))
        stream.seek(0)
        stream.write(f"RPA-3.0 {index_offset:016x} {key:08x}\n".encode("ascii"))
    for path in list(game.iterdir()):
        if path == archive:
            continue
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, help="Prepared native runtime (defaults to --sdk)")
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--packed", action="store_true", help="Compile then test a packed .rpa-only fixture")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    sdk = args.sdk.resolve()
    runtime = (args.runtime or args.sdk).resolve()
    if not (sdk / "renpy.py").is_file():
        parser.error("--sdk must point to a Ren'Py 8 SDK")
    platform = "mac-universal" if os.uname().sysname == "Darwin" else "linux-aarch64" if os.uname().machine in {"arm64", "aarch64"} else "linux-x86_64"
    python = sdk / f"lib/py3-{platform}/python"
    godot = (args.godot or Path(os.environ.get("GODOT_BIN", repo / ".devtools/godot-4.7.2/Godot.app/Contents/MacOS/Godot"))).resolve()
    token = uuid.uuid4().hex[:12]
    output = (args.output or repo / "out/diagnostics/renpy" / f"smoke-{token}").resolve()
    if output.exists():
        parser.error("Use a fresh output directory")
    output.mkdir(parents=True)
    game = output / "game"
    shutil.copytree(repo / "tests/fixtures/renpy_host", game)
    shutil.copy2(sdk / "sdk-fonts/SourceHanSansLite.ttf", game / "game/probe.ttf")
    env = dict(os.environ, AETHER_RENPY_SDK=str(runtime), AETHER_RENPY_TEST_GAME=str(game),
               AETHER_RENPY_TEST_RESULT=str(output / "player-result.json"))
    if args.packed:
        compile_env = dict(env, RENPY_PATH_TO_SAVES=str(output / "compile-data"), RENPY_LOG_BASE=str(output))
        run([str(python), str(sdk / "renpy.py"), str(game), "compile"], output / "compile.log", compile_env)
        pack_fixture(game / "game")
    before = tree_hash(game)
    project = output / "project"
    project.mkdir()
    source = repo / "apps/godot_app"
    for name in ["scripts", "tests", "assets", "bin", "legal", "builtin_demos", "renpy_runtime", "aether_kiri.gdextension"]:
        (project / name).symlink_to(source / name, target_is_directory=(source / name).is_dir())
    (project / "project.godot").write_text(f'''config_version=5
[application]
config/name="Aether Renpy Smoke {token}"
config/use_custom_user_dir=true
config/custom_user_dir_name="AetherTests/Renpy/{token}"
config/features=PackedStringArray("4.7")
config/quit_on_go_back=false
[display]
window/size/viewport_width=1280
window/size/viewport_height=720
[rendering]
renderer/rendering_method="mobile"
''')
    cache = project / ".godot"
    cache.mkdir()
    (cache / "extension_list.cfg").write_text("res://aether_kiri.gdextension\n")
    run([str(godot), "--headless", "--path", str(project), "--editor", "--import", "--quit"], output / "import.log", env)
    for name in ["renpy_library", "video_library_folders", "video_library_ui", "video_import_permissions", "flash_library"]:
        run([str(godot), "--headless", "--path", str(project), "--script", f"res://tests/{name}_test.gd"], output / f"{name}.log", env, name.upper() + "_OK")
    run([str(godot), "--path", str(project), "--script", "res://tests/renpy_player_smoke.gd"], output / "player.log", env, "RENPY_PLAYER_SMOKE_OK")
    assert tree_hash(game) == before, "The original game directory was modified"
    result = json.loads((output / "player-result.json").read_text())
    saves = list(Path(result["saves"]).glob("*.save"))
    assert saves, "No real Ren'Py save was written"
    with zipfile.ZipFile(saves[0]) as archive:
        assert "screenshot.png" in archive.namelist(), "The save has no thumbnail"
    result.update({"packed": args.packed, "original_unchanged": True, "save_thumbnail": True, "game": str(game)})
    (output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print("RENPY_SMOKE_OK")


if __name__ == "__main__":
    main()
