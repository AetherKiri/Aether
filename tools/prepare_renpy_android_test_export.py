#!/usr/bin/env python3
"""Prepare a disposable Debug Godot export with a coinstallable test package ID."""

import argparse
import configparser
import json
import re
import shutil
from pathlib import Path


def read_android_preset(path: Path, name: str) -> tuple[configparser.ConfigParser, str, dict]:
    config = configparser.ConfigParser(interpolation=None)
    config.optionxform = str
    with path.open() as stream:
        config.read_file(stream)
    sections = [section for section in config.sections()
                if re.fullmatch(r'preset\.\d+', section)
                and json.loads(config[section].get('name', '""')) == name]
    if len(sections) != 1:
        raise ValueError(f'Expected exactly one export preset named {name}')
    section = sections[0]
    if json.loads(config[section].get('platform', '""')) != 'Android':
        raise ValueError(f'{name} is not an Android export preset')
    options = config[section + '.options']
    expected = {
        'package': json.loads(options['package/unique_name']),
        'version_code': options.getint('version/code'),
        'version_name': json.loads(options['version/name']),
        'min_sdk': options.getint('gradle_build/min_sdk'),
    }
    return config, section + '.options', expected


def prepare(source: Path, destination: Path, preset: str, package: str) -> dict:
    if preset not in ('Android Debug', 'Android Emulator Debug'):
        raise ValueError('A coinstallable test package is supported only by Android Debug presets')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+', package):
        raise ValueError('Invalid Android test package ID')
    source = source.resolve()
    destination = destination.resolve()
    if destination == source or source in destination.parents:
        raise ValueError('Test export must use a separate directory outside the source project')
    if destination.exists() and any(destination.iterdir()):
        raise ValueError('Test export destination must be new or empty')
    config, section, expected = read_android_preset(source / 'export_presets.cfg', preset)
    if package == expected['package']:
        raise ValueError('Test package must differ from the product package')

    def ignored(directory: str, names: list[str]) -> list[str]:
        path = Path(directory)
        if path == source:
            return [name for name in names if name in ('.godot', '.git')]
        if path == source / 'android/build':
            return [name for name in names if name in ('.gradle', 'build')]
        return []

    # Copy files, rather than hard-linking mutable presets/build inputs back to
    # the production checkout. Android resources and its staged raw assets stay
    # available, while generated editor/Gradle output is regenerated separately.
    shutil.copytree(source, destination, dirs_exist_ok=True, ignore=ignored)
    config[section]['package/unique_name'] = json.dumps(package)
    config[section]['package/name'] = json.dumps('Aether RenPy Test')
    with (destination / 'export_presets.cfg').open('w') as stream:
        config.write(stream)
    return {'source_project': str(source), 'test_project': str(destination),
            'preset': preset, 'product_package': expected['package'], 'test_package': package}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-project', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--preset-name', required=True)
    parser.add_argument('--package-id', required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source_project, args.destination, args.preset_name, args.package_id)))
