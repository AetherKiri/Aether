#!/usr/bin/env python3
"""Compare ordinary teardown with explicit invalidation of an original graph.

Reports the implicit residual count; it may become zero after a runtime fix.
Explicit cleanup must leave no registered texture or in-flight snapshot.
This is a resource ownership test, not game compatibility or performance QA.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import time
import argparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--multi-window', action='store_true', help='test two windows sharing a disposal callback')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    fixture = 'apple_host_texture_lifecycle_multi' if args.multi_window else 'apple_host_texture_lifecycle'
    output = args.output or root / 'out/apple_host/evidence' / time.strftime('texture-lifecycle-%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=False)
    result = {}
    for mode in ('implicit', 'explicit'):
        folder = output / mode
        folder.mkdir()
        env = os.environ.copy()
        for key in list(env):
            if key.startswith('AETHER_HOST_TEST_') or key.startswith('AETHER_HOST_CAPTURE_'):
                env.pop(key, None)
        env.update(AETHER_HOST_AUTORUN='1', AETHER_HOST_RENDERER='metal',
                   AETHER_HOST_ASYNC_SNAPSHOT='1', AETHER_HOST_PROFILE='0',
                   AETHER_HOST_BYPASS_LEGAL_GATE='1',
                   AETHER_HOST_PRESENTATION='metal', AETHER_HOST_SCHEDULING='direct',
                   AETHER_HOST_TRACE_TEXTURES='1', AETHER_HOST_EXIT_AFTER='12',
                   AETHER_HOST_LIBRARY_ROOT=str((folder / 'library').resolve()),
                   AETHER_HOST_GAME_PATH=str(root / 'tests/fixtures' / fixture))
        if mode == 'explicit':
            env['AETHER_HOST_TEST_INPUT'] = '8'
        with (folder / 'run.log').open('w') as log:
            process = subprocess.Popen([str(root / 'out/apple_host/derived/Build/Products/Debug/AetherHost.app/Contents/MacOS/AetherHost')],
                                       env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = process.wait(timeout=42)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        text = (folder / 'run.log').read_text(errors='replace')
        errors = []
        for marker in ('startup state: SUCCEEDED', 'native GPU frame', 'engine destroyed'):
            if marker not in text:
                errors.append('missing ' + marker)
        if code or 'TVPShowScriptException' in text:
            errors.append('process or script failed')
        if mode == 'explicit' and 'input key down' not in text:
            errors.append('invalidation input not sent')
        diagnostics = re.findall(r'Metal bridge .*', text)
        stats = {key: int(value) for key, value in re.findall(r'\b(textures|retired_textures|async_inflight|failures)=(\d+)', diagnostics[-1])} if diagnostics else {}
        if len(stats) != 4 or stats.get('failures') or stats.get('async_inflight'):
            errors.append('missing diagnostics or GPU failure/inflight work')
        if mode == 'explicit' and (stats.get('textures') != 0 or stats.get('retired_textures') != 0):
            errors.append('explicit invalidation left textures')
        result[mode] = {'fixture': fixture, 'exit_code': code, 'stats': stats, 'errors': errors}
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(mode, result[mode], flush=True)
    print('Evidence:', output.resolve())
    return any(case['errors'] for case in result.values())


if __name__ == '__main__':
    raise SystemExit(main())
