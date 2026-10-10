#!/usr/bin/env python3
"""Verify Apple host local-translation settings, option mapping and ABI probe.

The settings/option layer is host-side and always testable. The engine-side
provider is optional: this tool records whether the current core links the
private local-model transformer (engine_is_text_translation_available) instead
of failing when it is absent.
"""
import argparse
import ctypes
import json
from pathlib import Path
import subprocess


def probe_engine(root):
    library = root / 'out/macos/debug/abi/libengine_api.dylib'
    if not library.is_file():
        return {'library': str(library), 'status': 'missing'}
    try:
        engine = ctypes.CDLL(str(library))
        engine.engine_is_text_translation_available.restype = ctypes.c_uint32
        engine.engine_get_text_translation_state.restype = ctypes.c_uint32
        available = int(engine.engine_is_text_translation_available())
        state = int(engine.engine_get_text_translation_state())
    except OSError as error:  # pragma: no cover - environment dependent
        return {'library': str(library), 'status': 'error', 'error': str(error)}
    return {
        'library': str(library),
        'status': 'ok',
        'text_translation_available': available,
        'text_translation_state': state,
        'note': ('private translation provider linked'
                 if available else
                 'private translation provider not linked; the host section stays hidden '
                 'unless AETHER_HOST_DEBUG_TRANSLATION=1 forces it for host testing'),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path,
                        default=Path('out/apple_host/evidence/m3-translation'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = root / 'apps/apple_host'
    binary = output / 'TranslationSettingsTests'
    subprocess.run([
        'xcrun', 'swiftc',
        str(source / 'AetherHost/ShellStrings.swift'),
        str(source / 'AetherHost/TranslationSettings.swift'),
        str(source / 'Tests/TranslationSettingsTests.swift'),
        '-o', str(binary),
    ], check=True)
    with (output / 'TranslationSettingsTests.log').open('w') as log:
        completed = subprocess.run([str(binary)], stdout=log, stderr=subprocess.STDOUT,
                                   timeout=60)
    engine = probe_engine(root)
    (output / 'result.json').write_text(json.dumps({
        'scope': 'host-side settings/option mapping plus engine availability probe; '
                 'model download, inference quality and timing are out of scope',
        'suite_exit_code': completed.returncode,
        'engine': engine,
    }, indent=2) + '\n')
    if completed.returncode:
        raise SystemExit(f'FAIL TranslationSettingsTests; see {output / "TranslationSettingsTests.log"}')
    print('PASS TranslationSettingsTests', flush=True)
    print(f"engine: available={engine.get('text_translation_available')} "
          f"state={engine.get('text_translation_state')}", flush=True)
    print(f'Evidence: {output}')


if __name__ == '__main__':
    main()
