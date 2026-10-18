vcpkg_check_linkage(ONLY_STATIC_LIBRARY)

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO "godotengine/godot-cpp"
    REF "10.0.0-stable"
    SHA512 "166421c32a4600b870d2bfe0393923afaa0ac8bbe7dab0042e6eef2fbb9c4a98b1516bc3e9a301ca661f489b1a3b7886874dc51bf0ee44765c6208743e41a84a"
    HEAD_REF "master"
    PATCHES
        "packagable.patch"
)

vcpkg_find_acquire_program(PYTHON3)

if(NOT DEFINED VCPKG_BUILD_TYPE OR VCPKG_BUILD_TYPE STREQUAL "release")
    set(_godotcpp_target "template_release")
else()
    set(_godotcpp_target "template_debug")
endif()

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        "-DPython3_EXECUTABLE=${PYTHON3}"
        "-DGODOTCPP_DISABLE_EXCEPTIONS=OFF"
        "-DGODOTCPP_API_VERSION=4.7"
        "-DGODOTCPP_TARGET=${_godotcpp_target}"
        # godot-cpp's windows.cmake defaults to the static CRT (/MT) and the
        # template_debug target. The x64-windows-static-md triplet uses the
        # dynamic CRT (/MD), so disable static CPP to match, and build the
        # release template for release installs.
        "-DGODOTCPP_USE_STATIC_CPP=OFF"
)

vcpkg_cmake_install()
vcpkg_cmake_config_fixup(PACKAGE_NAME "unofficial-${PORT}")
vcpkg_copy_pdbs()

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE.md")

file(
    INSTALL "${CMAKE_CURRENT_LIST_DIR}/usage"
    DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}"
)

file(REMOVE_RECURSE
    "${CURRENT_PACKAGES_DIR}/debug/include"
    "${CURRENT_PACKAGES_DIR}/debug/share"
)
