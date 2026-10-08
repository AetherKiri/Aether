#!/usr/bin/env python3
"""Exercise libgdiplus's real CMake export section with a compiled tiny fixture.

This tests package relocation and dependency metadata, not the libgdiplus
implementation, an Android build, or mobile gameplay. Supply an ordinary
vcpkg checkout; this test does not download tools or alter its cache.
"""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(*command: str, succeeds: bool = True) -> str:
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != succeeds:
        raise RuntimeError(f'{command}: exit {result.returncode}\n{result.stdout}')
    return result.stdout


def check(cmake: str, vcpkg: Path) -> None:
    repo = Path(__file__).resolve().parents[1]
    port = repo / 'vcpkg/ports/libgdiplus'
    export = (port / 'CMakeLists.txt').read_text().split('# 合并所有依赖\n', 1)[1]
    recipe = (port / 'portfile.cmake').read_text()
    assert recipe.index('vcpkg_cmake_install()') < recipe.index('vcpkg_cmake_config_fixup()') < recipe.index('"${CURRENT_PACKAGES_DIR}/debug/share"')
    assert 'VCPKG_POLICY_SKIP_ABSOLUTE_PATHS_CHECK' not in recipe
    helper_paths = ['scripts/cmake/z_vcpkg_function_arguments.cmake', 'scripts/cmake/vcpkg_list.cmake',
                    'ports/vcpkg-cmake-config/vcpkg_cmake_config_fixup.cmake']
    for path in helper_paths:
        if not (vcpkg / path).is_file():
            raise FileNotFoundError(vcpkg / path)
    with tempfile.TemporaryDirectory(prefix='aether-libgdiplus-relocation-') as directory:
        root = Path(directory)
        original = root / 'old-release-triplet'
        packages = root / 'package'
        source = root / 'source'
        source.mkdir()
        headers = original / 'include/dependency'
        headers.mkdir(parents=True)
        (headers / 'fixture-dependency.h').write_text('int dependency_fixture(void);\n')
        (source / 'dependency.c').write_text('int dependency_fixture(void) { return 41; }\n')
        (source / 'named.c').write_text('int named_fixture(void) { return CONFIG_VALUE; }\n')
        (source / 'gdiplus.c').write_text('#include "fixture-dependency.h"\nint named_fixture(void);\nint gdiplus_fixture(void) { return dependency_fixture() + named_fixture() + 1; }\n')
        (source / 'src').mkdir()
        (source / 'src/gdiplus-fixture.h').write_text('int gdiplus_fixture(void);\n')
        (source / 'config.h.in').write_text('/* CMake export fixture */\n')
        shutil.copyfile(port / 'libgdiplus-config.cmake.in', source / 'libgdiplus-config.cmake.in')
        (source / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.28)
project(libgdiplus VERSION 5.6.1 LANGUAGES C)
add_library(dependency STATIC dependency.c)
set_target_properties(dependency PROPERTIES OUTPUT_NAME dependency_fixture)
install(TARGETS dependency ARCHIVE DESTINATION lib)
add_library(named_dependency STATIC named.c)
set_target_properties(named_dependency PROPERTIES OUTPUT_NAME named_dependency_fixture DEBUG_POSTFIX d)
target_compile_definitions(named_dependency PRIVATE "CONFIG_VALUE=$<IF:$<CONFIG:Debug>,7,13>")
install(TARGETS named_dependency ARCHIVE DESTINATION lib)
add_library(libgdiplus STATIC gdiplus.c)
set(GLIB_INCLUDE_DIRS "${DEPENDENCY_PREFIX}/include/dependency")
set(GLIB_LIBRARY_DIRS "${DEPENDENCY_PREFIX}/${DEPENDENCY_LIBDIR}")
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(GLIB_LIBRARIES named_dependency_fixtured)
else()
    set(GLIB_LIBRARIES named_dependency_fixture)
endif()
set(GDIPLUS_LIBS "${DEPENDENCY_PREFIX}/${DEPENDENCY_LIBDIR}/libdependency_fixture.a")
''' + export)
        # Build both real native archives and export exactly the production
        # port's target/interface/install section, including absolute deps.
        for configuration, suffix in [('Release', ''), ('Debug', 'debug')]:
            build = root / ('producer-' + configuration)
            run(cmake, '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE=' + configuration,
                '-DCMAKE_INSTALL_PREFIX=' + str(packages / suffix), '-DDEPENDENCY_PREFIX=' + str(original),
                '-DDEPENDENCY_LIBDIR=' + ('debug/lib' if suffix else 'lib'))
            run(cmake, '--build', str(build))
            run(cmake, '--install', str(build))
            destination = original / suffix / 'lib'
            destination.mkdir(parents=True)
            shutil.copyfile(packages / suffix / 'lib/libdependency_fixture.a', destination / 'libdependency_fixture.a')
            named_archive = 'libnamed_dependency_fixture' + ('d' if suffix else '') + '.a'
            shutil.copyfile(packages / suffix / 'lib' / named_archive, destination / named_archive)
        shutil.copytree(original / 'include/dependency', packages / 'include/dependency')
        # The config's TIFF dependency must remain resolvable after moving.
        # TIFF is an interface fixture here; the linked dependency above is a
        # real archive and exercises Debug/Release path merging.
        tiff = packages / 'share/TIFF'
        tiff.mkdir(parents=True)
        (tiff / 'TIFFConfig.cmake').write_text('set(TIFF_FOUND TRUE)\nif(NOT TARGET TIFF::TIFF)\nadd_library(TIFF::TIFF INTERFACE IMPORTED)\nendif()\n')
        consumer = root / 'consumer'
        consumer.mkdir()
        (consumer / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.28)
project(consumer LANGUAGES C)
set(CMAKE_FIND_PACKAGE_PREFER_CONFIG ON)
find_package(libgdiplus CONFIG REQUIRED)
add_executable(consumer main.c)
target_link_libraries(consumer PRIVATE libgdiplus::libgdiplus)
''')
        (consumer / 'main.c').write_text('''#include <libgdiplus/gdiplus-fixture.h>
int main(void) {
#ifdef NDEBUG
    return gdiplus_fixture() != 55;
#else
    return gdiplus_fixture() != 49;
#endif
}
''')
        shutil.rmtree(original)
        broken = run(cmake, '-S', str(consumer), '-B', str(root / 'consumer-stale'),
                     '-DCMAKE_PREFIX_PATH=' + str(packages), succeeds=False)
        assert 'includes non-existent path' in broken and str(original) in broken, broken
        fixup = root / 'fixup.cmake'
        fixup.write_text('cmake_minimum_required(VERSION 3.28)\n' +
                         '\n'.join(f'include("{vcpkg / path}")' for path in helper_paths) +
                         f'\nset(PORT libgdiplus)\nset(CURRENT_INSTALLED_DIR "{original}")\n'
                         f'set(CURRENT_PACKAGES_DIR "{packages}")\nvcpkg_cmake_config_fixup()\n')
        run(cmake, '-P', str(fixup))
        for metadata in (packages / 'share/libgdiplus').glob('*.cmake'):
            contents = metadata.read_text()
            assert str(original) not in contents and str(packages) not in contents, metadata
        relocated = root / 'new-debug-triplet'
        shutil.move(packages, relocated)
        for configuration in ['Release', 'Debug']:
            build = root / ('consumer-' + configuration)
            run(cmake, '-S', str(consumer), '-B', str(build), '-DCMAKE_BUILD_TYPE=' + configuration,
                '-DCMAKE_PREFIX_PATH=' + str(relocated))
            run(cmake, '--build', str(build))
            run(str(build / 'consumer'))
        shutil.rmtree(relocated / 'include/dependency')
        missing = run(cmake, '-S', str(consumer), '-B', str(root / 'consumer-missing'),
                      '-DCMAKE_PREFIX_PATH=' + str(relocated), succeeds=False)
        assert 'includes non-existent path' in missing and str(relocated / 'include/dependency') in missing, missing
        print('Actual CMake export/install/relocation and Release+Debug consumer compile/link/run passed; stale and missing include prefixes rejected. Compiled package fixture only; mobile gameplay unverified.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cmake', default='cmake')
    parser.add_argument('--vcpkg-root', type=Path, required=True)
    arguments = parser.parse_args()
    check(arguments.cmake, arguments.vcpkg_root.resolve())
