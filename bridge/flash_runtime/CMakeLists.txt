cmake_minimum_required(VERSION 3.28)

find_program(CARGO_EXECUTABLE cargo REQUIRED)
find_program(RUSTC_EXECUTABLE rustc REQUIRED)
find_package(Java 17 COMPONENTS Runtime REQUIRED)
include("${CMAKE_SOURCE_DIR}/bridge/siglus_runtime/cmake/BuildSiglusRs.cmake")
aetherkiri_deduce_rust_target(FLASH_RUST_TARGET)
if(NOT FLASH_RUST_TARGET)
    message(FATAL_ERROR "Flash: no Rust target for this platform")
endif()

get_filename_component(_flash_rust_bin "${RUSTC_EXECUTABLE}" DIRECTORY)
get_filename_component(_flash_java_bin "${Java_JAVA_EXECUTABLE}" DIRECTORY)
set(_flash_env "RUSTC=${RUSTC_EXECUTABLE}"
    --modify "PATH=path_list_prepend:${_flash_java_bin}"
    --modify "PATH=path_list_prepend:${_flash_rust_bin}"
    "CARGO_TARGET_DIR=${CMAKE_CURRENT_BINARY_DIR}/cargo")
if(ANDROID)
    string(REPLACE "-" "_" _flash_triple "${FLASH_RUST_TARGET}")
    string(TOUPPER "${_flash_triple}" _flash_target_env)
    get_filename_component(_flash_ndk_bin "${CMAKE_C_COMPILER}" DIRECTORY)
    set(_flash_cc_triple "${FLASH_RUST_TARGET}")
    if(_flash_cc_triple STREQUAL "armv7-linux-androideabi")
        set(_flash_cc_triple "armv7a-linux-androideabi")
    endif()
    list(APPEND _flash_env
        "CC_${_flash_triple}=${_flash_ndk_bin}/${_flash_cc_triple}26-clang"
        "CXX_${_flash_triple}=${_flash_ndk_bin}/${_flash_cc_triple}26-clang++"
        "AR_${_flash_triple}=${_flash_ndk_bin}/llvm-ar"
        "CARGO_TARGET_${_flash_target_env}_LINKER=${_flash_ndk_bin}/${_flash_cc_triple}26-clang")
endif()
set(_flash_profile debug)
set(_flash_flags "")
if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(_flash_profile release)
    set(_flash_flags --release)
endif()
set(_flash_archive "${CMAKE_CURRENT_BINARY_DIR}/cargo/${FLASH_RUST_TARGET}/${_flash_profile}/libaether_flash.a")
if(WIN32)
    set(_flash_archive "${CMAKE_CURRENT_BINARY_DIR}/cargo/${FLASH_RUST_TARGET}/${_flash_profile}/aether_flash.lib")
endif()
add_custom_target(aether_flash_build
    COMMAND "${CMAKE_COMMAND}" -E env ${_flash_env}
        "${CARGO_EXECUTABLE}" build --locked --manifest-path
        "${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml" --target "${FLASH_RUST_TARGET}" ${_flash_flags}
    BYPRODUCTS "${_flash_archive}" VERBATIM)
add_library(aether_flash_native STATIC IMPORTED GLOBAL)
set_target_properties(aether_flash_native PROPERTIES IMPORTED_LOCATION "${_flash_archive}")
add_dependencies(aether_flash_native aether_flash_build)
if(APPLE)
    set_property(TARGET aether_flash_native PROPERTY INTERFACE_LINK_LIBRARIES
        "-framework Foundation;-framework Metal;-framework QuartzCore;-framework CoreGraphics;-framework Security")
elseif(ANDROID)
    set_property(TARGET aether_flash_native PROPERTY INTERFACE_LINK_LIBRARIES "log;android;dl;m")
elseif(UNIX)
    set_property(TARGET aether_flash_native PROPERTY INTERFACE_LINK_LIBRARIES "dl;pthread;m")
endif()
