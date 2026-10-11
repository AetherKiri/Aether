#!/usr/bin/env python3
"""Sequential onscreen or uncapped offscreen benchmarks without screenshot/input interference."""
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
    parser.add_argument('--compare-snapshots', action='store_true',
                        help='compare synchronous/async snapshots with direct scheduling')
    parser.add_argument('--reverse-order', action='store_true', help='reverse sequential comparison order')
    parser.add_argument('--offscreen', action='store_true',
                        help='run uncapped fixed-step benchmark into a 1920x1080 Metal target')
    parser.add_argument('--wait-gpu', action='store_true',
                        help='wait for each offscreen command completion (latency mode)')
    args = parser.parse_args()
    if not args.game.is_dir() or not math.isfinite(args.duration) or args.duration < 30:
        parser.error('existing game directory and duration >=30 required')
    root = Path(__file__).resolve().parent.parent
    binary = root / 'out/apple_host/derived/Build/Products/Debug/AetherHost.app/Contents/MacOS/AetherHost'
    output = args.output or root / 'out/apple_host/evidence' / time.strftime('profile-%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=False)
    result = {'scope': ('uncapped fixed-step tick to offscreen GPU completion; no drawable/scanout'
                        if args.offscreen else
                        'tick to onscreen GPU command completion; excludes scanout; no screenshot/input; sequential runs'), 'runs': {}}
    cases = [('sync', 'direct', '0'), ('async', 'direct', '1')] if args.compare_snapshots else [
        ('deferred', 'deferred', '0'), ('direct', 'direct', '0')]
    if args.reverse_order:
        cases.reverse()
    for mode, scheduling, async_snapshot in cases:
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
                   AETHER_HOST_BENCHMARK='1' if args.offscreen else '0',
                   AETHER_HOST_OUTPUT_RESOLUTION='original',
                   AETHER_HOST_SAMPLING_ALGORITHM='bicubic',
                   AETHER_HOST_BENCHMARK_WAIT_GPU='1' if args.wait_gpu else '0',
                   AETHER_HOST_DIRECT_RENDER='1' if scheduling == 'direct' else '0',
                   AETHER_HOST_SCHEDULING=scheduling, AETHER_HOST_ASYNC_SNAPSHOT=async_snapshot,
                   AETHER_HOST_GAME_PATH=str(args.game.resolve()),
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
        if args.offscreen:
            match = re.search(r'PROFILE offscreen ticks=(\d+) measured_samples=(\d+)', text)
            assert match, f'{mode}: missing offscreen benchmark summary'
            host = re.search(r'PROFILE host-work .*samples=(\d+) warmup_ticks=60 p50_ms=([\d.]+) p95_ms=([\d.]+) max_ms=([\d.]+)', text)
            assert host, f'{mode}: missing host-work profile'
            result['runs'][mode] = {
                'scheduling': scheduling, 'async_snapshot': async_snapshot == '1',
                'ticks': int(match.group(1)), 'measured_samples': int(match.group(2)),
                'p50_ms': float(host.group(2)), 'p95_ms': float(host.group(3)),
                'max_ms': float(host.group(4)), 'ticks_per_second': int(match.group(1)) / args.duration,
            }
            (output / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
            print(mode, json.dumps(result['runs'][mode]), flush=True)
            continue
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
        summary = {'scheduling': scheduling, 'async_snapshot': async_snapshot == '1',
                   'samples': len(rows), 'sampled_tick_span': ticks,
                   'eligible_ticks': eligible, 'unrepresented_ticks': max(0, eligible - len(rows)),
                   'p50_ms': values[(len(values)-1)//2], 'p95_ms': values[int((len(values)-1)*.95)],
                   'max_ms': values[-1], 'over_16_6': sum(v > 16.6 for v in values),
                   'slowest': sorted(rows, key=lambda r: float(r['tick_to_completion_ms']), reverse=True)[:5]}
        # Includes startup/warmup calls; get includes ABI routing AND runtime query.
        # Async snapshot CPU duration stops at submit, not GPU completion.
        stages = re.findall(r'native_get_calls=(\d+) native_get_total_ms=([\d.]+) native_get_max_ms=([\d.]+) native_snapshot_calls=(\d+) native_snapshot_total_ms=([\d.]+) native_snapshot_max_ms=([\d.]+)', text)
        assert stages, f'{mode}: missing native stage profiling'
        get_calls, get_total, get_max, snapshot_calls, snapshot_total, snapshot_max = stages[-1]
        assert int(get_calls) > 0 and int(snapshot_calls) > 0, mode
        summary['native_cpu_stages'] = {
            'scope': 'all calls including startup/warmup; get includes runtime query; async snapshot excludes GPU completion',
            'get_calls': int(get_calls), 'get_avg_ms': float(get_total)/int(get_calls), 'get_max_ms': float(get_max),
            'snapshot_calls': int(snapshot_calls), 'snapshot_avg_ms': float(snapshot_total)/int(snapshot_calls),
            'snapshot_max_ms': float(snapshot_max),
        }
        result['runs'][mode] = summary
        (output / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
        print(mode, json.dumps({k:v for k,v in summary.items() if k != 'slowest'}), flush=True)
    print('Evidence:', output.resolve())


if __name__ == '__main__':
    main()
