#!/usr/bin/env python3
"""Generate local ZIP fixtures and verify native host archive import."""
import argparse
import io
from pathlib import Path
import stat
import subprocess
import tarfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('out/apple_host/evidence/m2-archive'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    def make(name, entries):
        with zipfile.ZipFile(output / (name + '.zip'), 'w', zipfile.ZIP_DEFLATED) as archive:
            for path, data in entries:
                archive.writestr(path, data)
    make('wrapped', [('Game/data/startup.tjs', 'fixture script'), ('Game/data/save/readme.txt', 'fixture')])
    make('flat', [('0.txt', '*start')])
    make('unicode', [('游戏/0.txt', '*start'), ('游戏/背景.txt', '背景')])
    with zipfile.ZipFile(output / 'zip64.zip', 'w') as archive:
        with archive.open('0.txt', 'w', force_zip64=True) as entry:
            entry.write(b'*start')
    make('traversal', [('../escaped.txt', 'bad'), ('0.txt', '*start')])
    make('absolute', [('/escaped.txt', 'bad')])
    link = zipfile.ZipInfo('link')
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    make('symlink', [(link, '../outside'), ('0.txt', '*start')])
    make('case-collision', [('0.txt', '*start'), ('A.txt', 'a'), ('a.txt', 'b')])
    make('parent-collision', [('0.txt', '*start'), ('A/first.txt', 'a'), ('a/second.txt', 'b')])
    make('ambiguous', [('one/0.txt', '*start'), ('two/startup.tjs', 'script')])
    make('unknown', [('readme.txt', 'unknown')])
    make('empty', [])
    (output / 'corrupt.zip').write_bytes(b'PK\x03\x04broken')
    with tarfile.open(output / 'notzip.zip', 'w') as archive:
        entry = tarfile.TarInfo('0.txt')
        entry.size = 6
        archive.addfile(entry, io.BytesIO(b'*start'))
    with zipfile.ZipFile(output / 'crc.zip', 'w', zipfile.ZIP_STORED) as archive:
        archive.writestr('0.txt', 'ORIGINAL')
    (output / 'crc.zip').write_bytes((output / 'crc.zip').read_bytes().replace(b'ORIGINAL', b'DAMAGED!'))
    make('encrypted', [('0.txt', '*start')])
    data = bytearray((output / 'encrypted.zip').read_bytes())
    data[6] |= 1
    central = data.index(b'PK\x01\x02')
    data[central + 8] |= 1
    (output / 'encrypted.zip').write_bytes(data)
    # Playable original test script for manual UI validation, no third-party game files.
    make('playable', [('示例/data/startup.tjs', (root / 'tests/fixtures/apple_host_controls/startup.tjs').read_bytes())])
    source = root / 'apps/apple_host'
    common = [str(source / 'AetherHost' / f) for f in ['GameLibrary.swift', 'GameArchive.swift', 'GameRuntime.swift', 'PlayStats.swift', 'GameCopy.swift']]
    for suite in ['GameArchiveTests', 'GameLibraryTests']:
        binary = output / suite
        subprocess.run(['xcrun', 'swiftc', *common, str(source / 'Tests' / (suite + '.swift')),
                        '-import-objc-header', str(source / 'HostKit/ArchiveReader.h'), '-larchive', '-o', str(binary)], check=True)
        with (output / (suite + '.log')).open('w') as log:
            subprocess.run([str(binary), str(output)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
        print('PASS ' + suite, flush=True)


if __name__ == '__main__':
    main()
