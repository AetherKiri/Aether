cmake_minimum_required(VERSION 3.16)
project(Tests LANGUAGES CXX)

find_package(Catch2 3 REQUIRED)

include(CTest)
include(Catch)

set(TEST_CONFIG_DIR "${CMAKE_CURRENT_BINARY_DIR}")
set(TEST_FILES_PATH ${CMAKE_CURRENT_SOURCE_DIR}/test_files)
configure_file(test_config.h.in test_config.h)

if(AETHERKIRI_INTERNAL_ENABLED AND
   COMMAND aetherinternal_add_artemis_tests)
    aetherinternal_add_artemis_tests(
        "${CMAKE_SOURCE_DIR}/bridge/krkr2_runtime/src/artemis_lua_symbol_prefix.h")
endif()

# The krkr2 engine test suites live in the engine repository (issue #241
# Phase 2); this checkout owns their wiring. The runtime-neutral transform
# hook TU is compiled directly into those standalone krkr2 tests, so pass
# its path down to them. Out-of-tree sources need an explicit binary
# directory; keep it mirroring the engine submodule location.
set(KRKR2_TEXT_TRANSFORM_SOURCE
    "${CMAKE_SOURCE_DIR}/abi/src/TextTransform.cpp")

add_subdirectory("${AETHERKIRI_KRKR_DIR}/tests/plugins"
    "${CMAKE_BINARY_DIR}/packages/AetherKrkr/tests/plugins")
add_subdirectory("${AETHERKIRI_KRKR_DIR}/tests/tjs2"
    "${CMAKE_BINARY_DIR}/packages/AetherKrkr/tests/tjs2")
add_subdirectory(unit-tests/engine_api)
if(AETHERKIRI_INTERNAL_ENABLED)
    aetherinternal_add_runtime_tests("${CMAKE_SOURCE_DIR}")
endif()
if(AETHERKIRI_ENABLE_SIGLUS)
    add_subdirectory(unit-tests/siglus_runtime)
endif()
if(TARGET aether_mages_runtime)
    add_subdirectory(unit-tests/mages_runtime)
endif()
if(TARGET aether_xsystem4_runtime)
    add_executable(aether_xsystem4_native_contract xsystem4_native/contract.cpp)
    target_compile_features(aether_xsystem4_native_contract PRIVATE cxx_std_17)
    target_include_directories(aether_xsystem4_native_contract PRIVATE "${CMAKE_SOURCE_DIR}/abi/include")
    target_link_libraries(aether_xsystem4_native_contract PRIVATE aether_xsystem4_runtime)
    add_test(NAME xsystem4-native-contract COMMAND aether_xsystem4_native_contract)
    add_executable(aether_xsystem4_scene_keeper_contract xsystem4_native/scene_keeper.c)
    target_include_directories(aether_xsystem4_scene_keeper_contract PRIVATE
        "${AETHERKIRI_XSYSTEM4_DIR}/include"
        "${AETHERKIRI_XSYSTEM4_DIR}/src/hll"
        "${AETHERKIRI_XSYSTEM4_DIR}/subprojects/libsys4/include")
    target_link_libraries(aether_xsystem4_scene_keeper_contract PRIVATE aether_xsystem4_runtime)
    add_test(NAME xsystem4-scene-keeper-contract COMMAND aether_xsystem4_scene_keeper_contract)
    find_package(SDL2 CONFIG REQUIRED)
    find_package(SDL2_image CONFIG REQUIRED)
    foreach(contract afa assets lifecycle rance_quest tga graphics)
        add_executable(aether_xsystem4_${contract}_contract xsystem4_native/${contract}.cpp)
        target_compile_features(aether_xsystem4_${contract}_contract PRIVATE cxx_std_17)
        target_include_directories(aether_xsystem4_${contract}_contract PRIVATE
            "${AETHERKIRI_XSYSTEM4_DIR}/include"
            "${AETHERKIRI_XSYSTEM4_DIR}/subprojects/libsys4/include")
        target_link_libraries(aether_xsystem4_${contract}_contract PRIVATE aether_xsystem4_runtime)
        string(REPLACE "_" "-" test_name "${contract}")
        add_test(NAME xsystem4-${test_name}-contract COMMAND aether_xsystem4_${contract}_contract)
    endforeach()
    target_include_directories(aether_xsystem4_lifecycle_contract PRIVATE
        "${CMAKE_SOURCE_DIR}/abi/include")
    set_tests_properties(xsystem4-lifecycle-contract PROPERTIES TIMEOUT 30)
    target_link_libraries(aether_xsystem4_tga_contract PRIVATE
        $<IF:$<TARGET_EXISTS:SDL2_image::SDL2_image>,SDL2_image::SDL2_image,SDL2_image::SDL2_image-static>)
    add_executable(aether_xsystem4_font_fallback_contract xsystem4_native/font_fallback.c)
    target_compile_definitions(aether_xsystem4_font_fallback_contract PRIVATE XSYSTEM4_EMBEDDED)
    if(NOT APPLE)
        target_compile_definitions(aether_xsystem4_font_fallback_contract PRIVATE USE_GLES)
    endif()
    target_include_directories(aether_xsystem4_font_fallback_contract PRIVATE
        "${AETHERKIRI_XSYSTEM4_DIR}/include"
        "${AETHERKIRI_XSYSTEM4_DIR}/subprojects/libsys4/include")
    target_link_libraries(aether_xsystem4_font_fallback_contract PRIVATE aether_xsystem4_runtime
        $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>)
    add_test(NAME xsystem4-font-fallback-contract COMMAND aether_xsystem4_font_fallback_contract)
    target_compile_definitions(aether_xsystem4_graphics_contract PRIVATE XSYSTEM4_EMBEDDED SDL_MAIN_HANDLED)
    if(NOT APPLE OR IOS)
        target_compile_definitions(aether_xsystem4_graphics_contract PRIVATE USE_GLES)
    endif()
    target_include_directories(aether_xsystem4_graphics_contract PRIVATE
        "${CMAKE_SOURCE_DIR}/bridge/xsystem4_runtime/src")
    target_link_libraries(aether_xsystem4_graphics_contract PRIVATE
        $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>)
    set_tests_properties(xsystem4-graphics-contract PROPERTIES SKIP_RETURN_CODE 77)
endif()
if(AETHERKIRI_ENABLE_ONSCRIPTER)
    add_subdirectory(unit-tests/onscripter_runtime)
endif()

if(TARGET aether_xsystem35_runtime)
    add_executable(aether_xsystem35_native_contract xsystem35_native/contract.cpp)
    target_compile_features(aether_xsystem35_native_contract PRIVATE cxx_std_17)
    target_include_directories(aether_xsystem35_native_contract PRIVATE "${CMAKE_SOURCE_DIR}/abi/include")
    target_link_libraries(aether_xsystem35_native_contract PRIVATE aether_xsystem35_runtime)
    add_test(NAME xsystem35-native-contract COMMAND aether_xsystem35_native_contract)
    set_tests_properties(xsystem35-native-contract PROPERTIES TIMEOUT 30)
endif()

if(TARGET aether_xsystem35_core)
    get_target_property(xsystem35_binary_dir aether_xsystem35_core BINARY_DIR)
    add_executable(aether_xsystem35_encoding_contract xsystem35_native/encoding.c)
    target_include_directories(aether_xsystem35_encoding_contract PRIVATE
        "${AETHERKIRI_XSYSTEM35_DIR}/src" "${xsystem35_binary_dir}/generated")
    target_link_libraries(aether_xsystem35_encoding_contract PRIVATE aether_xsystem35_core)
    add_test(NAME xsystem35-encoding-contract COMMAND aether_xsystem35_encoding_contract)

    # Compile the real dispatcher with embedded Android selection even on a
    # desktop host. Missing standalone JNI backends must fail at link time.
    add_executable(aether_xsystem35_embedded_midi_contract xsystem35_native/midi.c
        "${AETHERKIRI_XSYSTEM35_DIR}/src/midi.c")
    target_compile_definitions(aether_xsystem35_embedded_midi_contract PRIVATE
        XSYSTEM35_EMBEDDED __ANDROID__)
    target_include_directories(aether_xsystem35_embedded_midi_contract PRIVATE
        "${AETHERKIRI_XSYSTEM35_DIR}/src" "${xsystem35_binary_dir}/generated")
    add_test(NAME xsystem35-embedded-midi-contract
        COMMAND aether_xsystem35_embedded_midi_contract)
endif()

if(TARGET aether_xsystem35_core)
    find_package(SDL2 CONFIG REQUIRED)
    add_executable(aether_xsystem35_mosaic_contract xsystem35_native/mosaic.c
        "${AETHERKIRI_XSYSTEM35_DIR}/src/render_mosaic.c")
    target_include_directories(aether_xsystem35_mosaic_contract PRIVATE
        "${AETHERKIRI_XSYSTEM35_DIR}/src" "${xsystem35_binary_dir}/generated")
    target_link_libraries(aether_xsystem35_mosaic_contract PRIVATE
        $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>)
    if(UNIX AND NOT APPLE)
        target_link_libraries(aether_xsystem35_mosaic_contract PRIVATE m)
    endif()
    add_test(NAME xsystem35-mosaic-contract COMMAND aether_xsystem35_mosaic_contract)
endif()

if(TARGET aether_xsystem35_core)
    find_package(SDL2_mixer CONFIG REQUIRED)
    add_executable(aether_xsystem35_audio_contract xsystem35_native/audio.c)
    target_link_libraries(aether_xsystem35_audio_contract PRIVATE
        $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>
        $<IF:$<TARGET_EXISTS:SDL2_mixer::SDL2_mixer>,SDL2_mixer::SDL2_mixer,SDL2_mixer::SDL2_mixer-static>)
    add_test(NAME xsystem35-audio-contract COMMAND aether_xsystem35_audio_contract)
endif()

if(TARGET aether_system3_runtime)
    include("${CMAKE_CURRENT_SOURCE_DIR}/system3_native/contracts.cmake")
endif()
