#!/usr/bin/env python3
"""Generate local media and verify Apple host decode, controls, subtitles and resume."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = (args.output or root / 'out/apple_host/evidence' / time.strftime('media-%Y%m%d-%H%M%S')).resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixtures = output / 'fixtures'
    fixtures.mkdir()
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('ffmpeg is required to generate the local test fixture')
    subtitle = fixtures / 'sample.srt'
    subtitle.write_text('1\n00:00:00,000 --> 00:00:06,000\n外置字幕：你好世界\n\n2\n00:00:06,000 --> 00:00:12,000\nSecond caption 日本語\n\n3\n00:00:12,000 --> 00:00:18,000\nPlayback complete\n', encoding='utf-8')
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
                    '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24:duration=18',
                    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=18', '-i', str(subtitle),
                    '-map', '0:v', '-map', '1:a', '-map', '2:s', '-c:v', 'mpeg4', '-q:v', '5',
                    '-c:a', 'aac', '-c:s', 'srt', '-metadata:s:s:0', 'language=zho',
                    '-metadata:s:s:0', 'title=Embedded Chinese', '-disposition:s:0', 'default',
                    str(fixtures / 'sample.mkv')], check=True)
    source = root / 'apps/apple_host/AetherHost'
    tests = root / 'apps/apple_host/Tests'
    linking = ['-L', str(root / 'out/macos/debug/abi'), '-lengine_api',
               '-Xlinker', '-needed_library', '-Xlinker', str(root / 'out/macos/debug/bridge/apple_host/libaether_apple_host_core.dylib')]
    for path in ['out/macos/debug/abi', 'out/macos/debug/bridge/apple_host']:
        linking += ['-Xlinker', '-rpath', '-Xlinker', str(root / path)]
    suites = {
        'VideoSubtitlesTests': ['VideoSubtitles.swift', 'MediaProgressStore.swift'],
        'MediaSessionTests': ['MediaSession.swift', 'VideoSubtitles.swift'],
        'MediaControllerTests': ['MediaSession.swift', 'VideoSubtitles.swift', 'MediaProgressStore.swift', 'DiagnosticStore.swift', 'MediaController.swift'],
    }
    results = {}
    for name, files in suites.items():
        command = ['xcrun', 'swiftc']
        if name != 'VideoSubtitlesTests':
            command += ['-import-objc-header', str(root / 'abi/include/engine_api.h')]
        command += [str(source / file) for file in files] + [str(tests / (name + '.swift'))]
        if name != 'VideoSubtitlesTests':
            command += linking
        binary = output / name
        subprocess.run(command + ['-o', str(binary)], check=True)
        with (output / (name + '.log')).open('w') as log:
            completed = subprocess.run([str(binary), str(output)], stdout=log, stderr=subprocess.STDOUT, timeout=45)
        results[name] = {'exit_code': completed.returncode, 'log': name + '.log'}
        (output / 'result.json').write_text(json.dumps({'scope': 'local generated video; not a codec matrix or audible audio validation', 'suites': results}, indent=2) + '\n')
        if completed.returncode:
            raise SystemExit(f'FAIL {name}; see {output / (name + ".log")}')
        print(f'PASS {name}', flush=True)
    print(f'Evidence: {output}')


if __name__ == '__main__':
    main()
