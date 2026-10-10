#!/usr/bin/env python3
"""Verify Apple host game text input/IME plumbing and prepare an edit fixture.

The fixture is a copy of the in-repo KAG3 demo whose first.ks jumps straight to
the demo's own "calculation question" section, which focuses a KiriKiri [edit]
control. That makes the focused-text-layer path reachable in a few interactions
instead of walking the whole introduction.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def prepare_fixture(root, output):
    source = root / 'demos/aetherkiri-kag3'
    game = output / 'game'
    if game.exists():
        shutil.rmtree(game)
    shutil.copytree(source, game, ignore=shutil.ignore_patterns('savedata', '*.log'))
    scenario = game / 'data/scenario/first.ks'
    text = scenario.read_text(encoding='utf-8-sig')
    marker = '*syokai_start|'
    if marker not in text:
        raise SystemExit('demo first.ks layout changed; update the fixture patch')
    if '@jump target=*about_kag8' not in text:
        # Keep the macro definitions; the quiz section needs start_select/end_select.
        jump = '@jump target=*about_kag8\n; IMETEST: enter the edit-control section directly\n'
        text = text.replace(marker, jump + marker, 1)
        scenario.write_text('\ufeff' + text, encoding='utf-8')
    return game


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path,
                        default=Path('out/apple_host/evidence/m3-ime'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = root / 'apps/apple_host'
    binary = output / 'GameTextInputTests'
    subprocess.run([
        'xcrun', 'swiftc',
        str(source / 'AetherHost/InputMapping.swift'),
        str(source / 'AetherHost/GameTextInput.swift'),
        str(source / 'Tests/GameTextInputTests.swift'),
        '-o', str(binary),
    ], check=True)
    with (output / 'GameTextInputTests.log').open('w') as log:
        completed = subprocess.run([str(binary)], stdout=log, stderr=subprocess.STDOUT, timeout=60)
    game = prepare_fixture(root, output)
    (output / 'result.json').write_text(json.dumps({
        'scope': 'state parsing, IME activation decision, preedit dedupe, command map and '
                 'caret geometry; real composition needs a system input method',
        'suite_exit_code': completed.returncode,
        'fixture': {'path': str(game / 'data'), 'derived_from': 'demos/aetherkiri-kag3',
                    'patch': 'first.ks jumps to *about_kag8 (edit-control section)'},
    }, indent=2) + '\n')
    if completed.returncode:
        raise SystemExit(f'FAIL GameTextInputTests; see {output / "GameTextInputTests.log"}')
    print('PASS GameTextInputTests', flush=True)
    print(f'Edit fixture: {game / "data"}', flush=True)
    print('UI validation: launch AetherHost.app without AUTORUN, import that folder, play, and')
    print('reach the calculation question; the focused [edit] control activates composed input.')
    print(f'Evidence: {output}')


if __name__ == '__main__':
    main()
