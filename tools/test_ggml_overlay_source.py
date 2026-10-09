#!/usr/bin/env python3
"""Compile the pinned ggml source, apply the real port patches, and consume its CMake API.

Supply an existing official v0.11.1 source archive. This check performs no
downloads, modifies no vcpkg cache, and does not test Android or gameplay.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


def run(*command: str, cwd: Path | None = None) -> None:
    environment = dict(os.environ, SOURCE_DATE_EPOCH='1')
    result = subprocess.run(command, cwd=cwd, env=environment, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{command}: exit {result.returncode}\n{result.stdout}')


def validate_archive(archive: Path, recipe: str) -> str:
    expected = re.search(r'\bSHA512\s+([a-f0-9]{128})\b', recipe)
    if not expected:
        raise ValueError('The production recipe must specify SHA512')
    actual = hashlib.sha512(archive.read_bytes()).hexdigest()
    if actual != expected.group(1):
        raise ValueError(f'Source archive SHA512 differs: {actual}')
    return actual


def check(archive: Path, cmake: str) -> None:
    port = Path(__file__).resolve().parents[1] / 'vcpkg/ports/ggml'
    manifest = json.loads((port / 'vcpkg.json').read_text())
    recipe = (port / 'portfile.cmake').read_text()
    assert manifest['version'] == '0.11.1'
    assert 'include("${VCPKG_ROOT_DIR}/ports/ggml/portfile.cmake")' not in recipe
    checksum = validate_archive(archive, recipe)
    patches = re.search(r'\bPATCHES\s+(.*?)\n\)', recipe, re.DOTALL)
    if not patches:
        raise ValueError('The production recipe must list its source patches')
    names = patches.group(1).split()
    with tempfile.TemporaryDirectory(prefix='aether-ggml-source-') as directory:
        root = Path(directory)
        with tarfile.open(archive) as source_archive:
            members = source_archive.getmembers()
            for member in members:
                path = PurePosixPath(member.name)
                if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()):
                    raise ValueError(f'Unsafe source archive member: {member.name}')
                if not path.parts or path.parts[0] != 'ggml-0.11.1':
                    raise ValueError(f'Unexpected source root: {member.name}')
            source_archive.extractall(root, members=members, filter='data')
        source = root / 'ggml-0.11.1'
        for name in names:
            patch = port / name
            if patch.parent != port or not patch.is_file():
                raise ValueError(f'Invalid or missing port patch: {name}')
            run('patch', '-p1', '--batch', '--forward', '-i', str(patch), cwd=source)
        build = root / 'build'
        prefix = root / 'installed'
        run(cmake, '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
            '-DCMAKE_INSTALL_PREFIX=' + str(prefix), '-DBUILD_SHARED_LIBS=OFF',
            '-DGGML_STATIC=ON', '-DGGML_CCACHE=OFF', '-DGGML_BUILD_NUMBER=1',
            '-DGGML_BUILD_TESTS=OFF', '-DGGML_BUILD_EXAMPLES=OFF', '-DGGML_HIP=OFF',
            '-DGGML_SYCL=OFF', '-DGGML_BLAS=OFF', '-DGGML_CUDA=OFF', '-DGGML_METAL=OFF',
            '-DGGML_OPENCL=OFF', '-DGGML_OPENMP=OFF', '-DGGML_VULKAN=OFF')
        run(cmake, '--build', str(build), '--parallel', '2')
        run(cmake, '--install', str(build))
        consumer = root / 'consumer'
        consumer.mkdir()
        (consumer / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.14)
project(ggml_consumer LANGUAGES CXX)
find_package(ggml CONFIG REQUIRED)
add_executable(ggml_smoke smoke.cpp)
target_link_libraries(ggml_smoke PRIVATE ggml::ggml)
''')
        # The application/llama-cpp host is C++; its static ggml implementation
        # includes C++ objects and needs the normal C++ executable link driver.
        (consumer / 'smoke.cpp').write_text('''#include <ggml.h>
int main(void) {
    struct ggml_init_params params = {4 * 1024 * 1024, 0, false};
    struct ggml_context *context = ggml_init(params);
    if (!context) return 1;
    struct ggml_tensor *tensor = ggml_new_tensor_1d(context, GGML_TYPE_F32, 4);
    int result = (!tensor || ggml_nelements(tensor) != 4 || ggml_nbytes(tensor) != 16);
    ggml_free(context);
    return result;
}
''')
        consumer_build = root / 'consumer-build'
        run(cmake, '-S', str(consumer), '-B', str(consumer_build),
            '-DCMAKE_PREFIX_PATH=' + str(prefix))
        run(cmake, '--build', str(consumer_build), '--parallel', '2')
        run(str(consumer_build / 'ggml_smoke'))
        # A single changed source byte must be rejected before extraction or compilation.
        changed = root / 'changed-source.tar.gz'
        changed.write_bytes(archive.read_bytes() + b'corruption')
        try:
            validate_archive(changed, recipe)
        except ValueError:
            pass
        else:
            raise AssertionError('Changed source archive was accepted')
    print(f'ggml 0.11.1 SHA512 verified: {checksum}')
    print(f'{len(names)} official patches applied; real host build/install and ggml::ggml API link/run passed; changed-byte rejection passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--cmake', default='cmake')
    arguments = parser.parse_args()
    check(arguments.archive.resolve(), arguments.cmake)
