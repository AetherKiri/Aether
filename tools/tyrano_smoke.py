#!/usr/bin/env python3
"""Prepare an isolated original scenario using an external TyranoScript checkout.

The upstream engine/assets are copied only into ignored local test output. They
are not distributed with Aether. The generated Godot project has separate user
data, so testing never changes the user's library, preferences, or game saves.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import struct
import uuid


def pack_asar(game, destination):
    """Pack the disposable fixture; upstream assets remain in ignored output."""
    tree = {"files": {}}
    members = []
    offset = 0
    for path in sorted(game.rglob("*")):
        if path.is_symlink():
            if path == game / "data/outside.txt":
                continue  # The packed fixture must never include the external marker.
            raise ValueError(f"Unexpected fixture symlink: {path}")
        if not path.is_file():
            continue
        parts = path.relative_to(game).parts
        node = tree
        for part in parts[:-1]:
            node = node["files"].setdefault(part, {"files": {}})
        size = path.stat().st_size
        node["files"][parts[-1]] = {"size": size, "offset": str(offset)}
        members.append(path)
        offset += size
    header = json.dumps(tree, ensure_ascii=False, separators=(",", ":")).encode()
    padding = (-len(header)) % 4
    destination.parent.mkdir(parents=True)
    with destination.open("xb") as archive:
        archive.write(struct.pack("<4I", 4, len(header) + padding + 8, len(header) + padding + 4, len(header)))
        archive.write(header + b"\0" * padding)
        for path in members:
            with path.open("rb") as source:
                shutil.copyfileobj(source, archive)


def run(command, log, env, timeout=180):
    with log.open("w") as output:
        result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    text = log.read_text(errors="replace")
    if result.returncode or re.search(r"SCRIPT ERROR:|^ERROR:", text, re.MULTILINE):
        raise RuntimeError(f"Check failed (exit {result.returncode}): {log}\n" + "\n".join(text.splitlines()[-40:]))
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-root", type=Path, required=True)
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--asar", action="store_true", help="Launch a packed Electron fixture through ASAR preparation")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    engine = args.engine_root.resolve()
    if not (engine / "tyrano/plugins/kag/kag.js").is_file():
        parser.error("--engine-root must point to an unpacked TyranoScript distribution/check-out")
    token = uuid.uuid4().hex[:12]
    output = (args.output or repo / "out/diagnostics/tyrano" / f"smoke-{token}").resolve()
    output.mkdir(parents=True, exist_ok=True)
    game = output / "game"
    if game.exists():
        parser.error("Use a fresh output directory; existing games are never overwritten")
    shutil.copytree(engine, game, ignore=shutil.ignore_patterns(".git", ".vscode", "release"))
    shutil.copyfile(repo / "tests/fixtures/tyrano_host/first.ks", game / "data/scenario/first.ks")
    config = game / "data/system/Config.tjs"
    text = config.read_text(encoding="utf-8-sig")
    for key, value in {"System.title":'"Aether TyranoScript 验证"', "projectID":"aether_tyrano_probe",
                       "scWidth":"960", "scHeight":"540", "chSpeed":"0", "configSave":"file",
                       "configThumbnail":"false", "debugMenu.visible":"false"}.items():
        pattern = rf"(?m)^;{re.escape(key)}\s*=.*$"
        text, count = re.subn(pattern, f";{key} = {value};", text)
        if count != 1:
            raise RuntimeError(f"Unsupported fixture Config.tjs: {key}")
    config.write_text(text)
    (output / "outside.txt").write_text("This original test marker must not be exposed to the game.")
    (game / "data/outside.txt").symlink_to(output / "outside.txt")
    if args.asar:
        packed_game = output / "electron"
        pack_asar(game, packed_game / "resources/app.asar")
        game = packed_game
    project = output / "project"
    project.mkdir()
    source = repo / "apps/godot_app"
    for name in ["scripts", "tests", "assets", "bin", "legal", "builtin_demos", "aether_kiri.gdextension"]:
        (project / name).symlink_to(source / name, target_is_directory=(source / name).is_dir())
    (project / "project.godot").write_text(f'''config_version=5
[application]
config/name="Aether TyranoScript Smoke {token}"
config/use_custom_user_dir=true
config/custom_user_dir_name="AetherTests/Tyrano/{token}"
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
    (cache / "extension_list.cfg").write_text('res://aether_kiri.gdextension\n')
    godot = (args.godot or Path(os.environ.get("GODOT_BIN", repo / ".devtools/godot-4.7.2/Godot.app/Contents/MacOS/Godot"))).resolve()
    env = dict(os.environ, AETHERKIRI_TEST_TYRANO=str(game))
    result = {"game":str(game), "project":str(project), "godot":str(godot), "asar":args.asar, "checks":{}}
    (output / "paths.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    if args.prepare_only:
        return
    run([str(godot), "--headless", "--path", str(project), "--editor", "--import", "--quit"], output / "import.log", env)
    for name in ["tyrano_library", "tyrano_asar", "video_library_folders", "video_library_ui", "video_import_permissions", "flash_library"]:
        text = run([str(godot), "--headless", "--path", str(project), "--script", f"res://tests/{name}_test.gd"], output / f"{name}.log", env)
        marker = name.upper() + "_OK"
        if marker not in text:
            raise RuntimeError(f"Missing {marker}")
        result["checks"][name] = "passed"
        print(marker, flush=True)
    text = run([str(godot), "--path", str(project), "--script", "res://tests/tyrano_player_smoke.gd"], output / "player.log", env)
    if "TYRANO_PLAYER_SMOKE_OK" not in text:
        raise RuntimeError("Native player did not report success")
    result["checks"]["tyrano_player"] = "passed"
    (output / "result.json").write_text(json.dumps(result, indent=2))
    print("TYRANO_PLAYER_SMOKE_OK", flush=True)


if __name__ == "__main__":
    main()
