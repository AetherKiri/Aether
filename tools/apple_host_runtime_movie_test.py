#!/usr/bin/env python3
"""Verify runtime movie routing with generated AVI and a borrowed real engine handle."""
import argparse
import json
from pathlib import Path
import os
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('out/apple_host/evidence/m3-runtime-movie'))
    parser.add_argument('--run-host', action='store_true', help='also verify the built Debug host game/movie integration')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    fixtures = output / 'fixtures'
    fixtures.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('ffmpeg is required to generate a local AVI fixture')
    for name, duration in [('movie.avi',3),('ui-movie.avi',12)]:
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f','lavfi','-i',
                        f'testsrc2=size=320x180:rate=24:duration={duration}', '-c:v','mpeg4','-q:v','5',
                        str(fixtures / name)],check=True)
    game = output / 'game'
    game.mkdir(exist_ok=True)
    shutil.copyfile(root / 'tests/fixtures/apple_host_controls/startup.tjs', game / 'startup.tjs')
    source = root / 'apps/apple_host'
    files = [str(source / 'AetherHost' / name) for name in ('MediaSession.swift','RuntimeMovieController.swift')]
    linking = ['-import-objc-header',str(root / 'abi/include/engine_api.h'),
               '-L',str(root / 'out/macos/debug/abi'),'-lengine_api',
               '-Xlinker','-needed_library','-Xlinker',str(root / 'out/macos/debug/bridge/apple_host/libaether_apple_host_core.dylib')]
    for directory in ['out/macos/debug/abi','out/macos/debug/bridge/apple_host']:
        linking += ['-Xlinker','-rpath','-Xlinker',str(root / directory)]
    test = output / 'runtime-movie-tests'
    subprocess.run(['xcrun','swiftc',*files,str(source / 'Tests/RuntimeMovieTests.swift'),*linking,'-o',str(test)],check=True)
    with (output / 'tests.log').open('w') as log:
        result = subprocess.run([str(test),str(output)],stdout=log,stderr=subprocess.STDOUT,timeout=30)
    (output / 'result.json').write_text(json.dumps({'suite':'RuntimeMovieTests','exit_code':result.returncode,
        'scope':'real decoder/borrowed engine; responses use test callback, not actual Minori VM'},indent=2)+'\n')
    if result.returncode:
        raise SystemExit(f'FAIL; see {output / "tests.log"}')
    print('PASS RuntimeMovieTests', flush=True)
    host = root / 'out/apple_host/derived/Build/Products/Debug/AetherHost.app/Contents/MacOS/AetherHost'
    if args.run_host:
        cases = [('complete',False,None,7),('skip',True,'4:32,4.1:32',6),('close',True,None,4)]
        results = {}
        for name, skippable, keys, duration in cases:
            folder = output / name
            folder.mkdir(exist_ok=True)
            env = os.environ.copy()
            env.update(AETHER_HOST_AUTORUN='1', AETHER_HOST_GAME_PATH=str(game),
                       AETHER_HOST_LIBRARY_ROOT=str(folder / 'library'),
                       AETHER_HOST_DEFAULT_FONT=str(root / 'apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf'),
                       AETHER_HOST_RENDERER='software', AETHER_HOST_EXIT_AFTER=str(duration),
                       AETHER_HOST_TEST_RUNTIME_MOVIE=f'{fixtures / "movie.avi"}\t320\t180\t80\t60\t{int(skippable)}')
            for key in ['AETHER_HOST_TEST_INPUT','AETHER_HOST_TEST_KEYS','AETHER_HOST_CAPTURE_AFTER']:
                env.pop(key,None)
            if keys:
                env['AETHER_HOST_TEST_KEYS'] = keys
            with (folder / 'run.log').open('w') as log:
                result = subprocess.run([str(host)],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=20)
            lines = (folder / 'run.log').read_text()
            acknowledgments = [line.split('TEST MOVIE ACK: ',1)[1] for line in lines.splitlines()
                               if line.startswith('[host] TEST MOVIE ACK: ')]
            expected = {'complete':['result=complete'],'skip':['result=skipped'],'close':[]}[name]
            ok = result.returncode == 0 and acknowledgments == expected and 'engine destroyed' in lines
            results[name] = {'passed':ok,'exit_code':result.returncode,'acknowledgments':acknowledgments}
            (output / 'host-result.json').write_text(json.dumps(results,indent=2)+'\n')
            if not ok:
                raise SystemExit(f'FAIL host {name}; see {folder / "run.log"}')
            print(f'PASS host {name}',flush=True)
    print(f'Host UI validation: use {host} with AETHER_HOST_AUTORUN=1, AETHER_HOST_GAME_PATH={game},')
    print('AETHER_HOST_TEST_RUNTIME_MOVIE=<six tab-separated fields> and an isolated AETHER_HOST_LIBRARY_ROOT.')
    print('Movie ACK is a DEBUG-only test callback; this does not verify the actual Minori VM.')


if __name__ == '__main__':
    main()
