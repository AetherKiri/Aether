#!/usr/bin/env python3
"""Sequential onscreen benchmarks without screenshot/readback interference."""
import argparse
import csv
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('game', type=Path)
    parser.add_argument('--duration', type=float, default=60)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not args.game.is_dir() or not math.isfinite(args.duration) or args.duration < 30:
        parser.error('existing game directory and duration >=30 required')
    root = Path(__file__).resolve().parent.parent
    binary = root / 'out/apple_host/derived/Build/Products/Debug/AetherHost.app/Contents/MacOS/AetherHost'
    output = args.output or root / 'out/apple_host/evidence' / time.strftime('profile-%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=False)
    result = {'scope': 'tick to onscreen GPU command completion; excludes scanout; no screenshot/input; sequential runs', 'runs': {}}
    for mode in ('deferred', 'direct'):
        folder = output / mode
        folder.mkdir()
        env = os.environ.copy()
        # Remove inherited test actions/captures to keep this benchmark isolated.
        for name in list(env):
            if name.startswith('AETHER_HOST_TEST_'):
                env.pop(name, None)
        for name in ('AETHER_HOST_CAPTURE_AFTER', 'AETHER_HOST_PRESENTATION'):
            env.pop(name, None)
        env.update(AETHER_HOST_AUTORUN='1', AETHER_HOST_LIBRARY_ROOT=str((folder / "library").resolve()), AETHER_HOST_RENDERER='metal',
                   AETHER_HOST_PROFILE='1', AETHER_HOST_DRAWABLE_1080P='1',
                   AETHER_HOST_SCHEDULING=mode, AETHER_HOST_GAME_PATH=str(args.game.resolve()),
                   AETHER_HOST_CAPTURE_DIR=str(folder.resolve()), AETHER_HOST_EXIT_AFTER=str(args.duration),
                   # Unattended runs are occluded otherwise; the presenter skips
                   # drawable requests for occluded windows, so bring it forward.
                   AETHER_HOST_ACTIVATE='1')
        with (folder / 'run.log').open('w') as log:
            process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = process.wait(timeout=args.duration + 30)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        text = (folder / 'run.log').read_text(errors='replace')
        assert code == 0 and 'engine destroyed' in text and 'startup state: SUCCEEDED' in text, mode
        assert 'Metal presentation failed' not in text, mode
        assert 'native GPU frame' in text and re.search(r'Metal bridge .*failures=0.*native_readbacks=0', text), mode
        csv_path = folder / 'aetherhost-presentation.csv'
        assert csv_path.is_file(), (
            f'{mode}: no presentation samples; the host window never presented '
            '(occluded/hidden window). See run.log for "presentation paused".')
        with csv_path.open() as source:
            rows = list(csv.DictReader(source))
        assert len(rows) >= 60 and len({r['tick'] for r in rows}) == len(rows), mode
        assert all((r['drawable_width'], r['drawable_height']) == ('1920', '1080') for r in rows), mode
        values = sorted(float(r['tick_to_completion_ms']) for r in rows)
        assert all(math.isfinite(v) and v > 0 for v in values), mode
        ticks = max(int(r['tick']) for r in rows) - 60
        eligible = int(re.search(r'PROFILE host-work .*samples=(\d+)', text).group(1))
        summary = {'samples': len(rows), 'sampled_tick_span': ticks,
                   'eligible_ticks': eligible, 'unrepresented_ticks': max(0, eligible - len(rows)),
                   'p50_ms': values[(len(values)-1)//2], 'p95_ms': values[int((len(values)-1)*.95)],
                   'max_ms': values[-1], 'over_16_6': sum(v > 16.6 for v in values),
                   'slowest': sorted(rows, key=lambda r: float(r['tick_to_completion_ms']), reverse=True)[:5]}
        result['runs'][mode] = summary
        (output / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
        print(mode, json.dumps({k:v for k,v in summary.items() if k != 'slowest'}), flush=True)
    print('Evidence:', output.resolve())


if __name__ == '__main__':
    main()
