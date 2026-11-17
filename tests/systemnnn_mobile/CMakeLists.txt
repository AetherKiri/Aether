cmake_minimum_required(VERSION 3.28)
project(AetherSystemNNNMobile LANGUAGES C CXX)
if(VCPKG_TARGET_TRIPLET MATCHES "android" AND NOT ANDROID)
    message(FATAL_ERROR "Android dependencies require -DCMAKE_SYSTEM_NAME=Android for the adapter compiler")
endif()
if(VCPKG_TARGET_TRIPLET MATCHES "ios" AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "iOS dependencies require -DCMAKE_SYSTEM_NAME=iOS for the adapter compiler")
endif()

# A focused compile/link gate. It intentionally avoids the product manifest,
# Godot, signing, and executing cross-compiled contract binaries on the host.
get_filename_component(AETHER_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(AETHERKIRI_SYSTEMNNN_DIR "${AETHER_ROOT}/packages/SystemNNN-Emberfall" CACHE PATH "Runtime source")
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
function(aetherkiri_limit_runtime_exports target kind)
endfunction()
add_subdirectory("${AETHER_ROOT}/abi" abi)
# Preserve static OpenAL backend dependencies from its package target. This also
# prevents Apple framework discovery from selecting the system OpenAL instead.
find_package(OpenAL CONFIG QUIET)
add_subdirectory("${AETHER_ROOT}/bridge/systemnnn_runtime" runtime)

# Whole-archive linking below forces every adapter object into the final link.
# Registration also retains the callback table and its dependency closure.
if(ANDROID)
    add_library(systemnnn-mobile-link SHARED link.cpp)
    target_link_options(systemnnn-mobile-link PRIVATE "LINKER:--no-undefined" "LINKER:-z,max-page-size=16384")
elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    add_executable(systemnnn-mobile-link link.cpp)
    set_target_properties(systemnnn-mobile-link PROPERTIES
        MACOSX_BUNDLE FALSE
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)
else()
    # Also permits a host link check of this focused project's wiring.
    add_executable(systemnnn-mobile-link link.cpp)
endif()
target_compile_features(systemnnn-mobile-link PRIVATE cxx_std_17)
target_link_libraries(systemnnn-mobile-link PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,aether_systemnnn_runtime>")
install(TARGETS systemnnn-mobile-link engine_api aether_systemnnn_runtime
    RUNTIME DESTINATION bin LIBRARY DESTINATION lib ARCHIVE DESTINATION lib)
if(ANDROID AND CMAKE_ANDROID_STL_TYPE STREQUAL "c++_shared")
    install(FILES "${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
        DESTINATION lib)
endif()
install(FILES "${AETHER_ROOT}/bridge/systemnnn_runtime/include/systemnnn_runtime.h" DESTINATION include)
install(FILES "${AETHERKIRI_SYSTEMNNN_DIR}/LICENSE" "${AETHERKIRI_SYSTEMNNN_DIR}/THIRD_PARTY_NOTICES.md" DESTINATION licenses/SystemNNN)
