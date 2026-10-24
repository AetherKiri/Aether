cmake_minimum_required(VERSION 3.28)
project(AetherXsystem35NativeProbe LANGUAGES C CXX)
get_filename_component(AETHER_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(AETHERKIRI_XSYSTEM35_DIR "${AETHER_ROOT}/packages/xsystem35")
add_subdirectory("${AETHER_ROOT}/bridge/xsystem35_runtime" "${CMAKE_CURRENT_BINARY_DIR}/runtime")
find_package(SDL2_image CONFIG REQUIRED)
find_package(nlohmann_json CONFIG REQUIRED)
add_executable(aether_xsystem35_native_probe probe.cpp)
target_compile_features(aether_xsystem35_native_probe PRIVATE cxx_std_17)
target_include_directories(aether_xsystem35_native_probe PRIVATE "${AETHER_ROOT}/abi/include" "${AETHERKIRI_XSYSTEM35_DIR}/src")
target_link_libraries(aether_xsystem35_native_probe PRIVATE aether_xsystem35_runtime nlohmann_json::nlohmann_json
    $<IF:$<TARGET_EXISTS:SDL2_image::SDL2_image>,SDL2_image::SDL2_image,SDL2_image::SDL2_image-static>)
enable_testing()

if(TARGET aether_xsystem35_runtime)
    add_executable(aether_xsystem35_native_contract contract.cpp)
    target_compile_features(aether_xsystem35_native_contract PRIVATE cxx_std_17)
    target_include_directories(aether_xsystem35_native_contract PRIVATE "${AETHER_ROOT}/abi/include")
    target_link_libraries(aether_xsystem35_native_contract PRIVATE aether_xsystem35_runtime)
    add_test(NAME xsystem35-native-contract COMMAND aether_xsystem35_native_contract)
    set_tests_properties(xsystem35-native-contract PROPERTIES TIMEOUT 30)
endif()

if(TARGET aether_xsystem35_core)
    get_target_property(xsystem35_binary_dir aether_xsystem35_core BINARY_DIR)
    add_executable(aether_xsystem35_encoding_contract encoding.c)
    target_include_directories(aether_xsystem35_encoding_contract PRIVATE
        "${AETHERKIRI_XSYSTEM35_DIR}/src" "${xsystem35_binary_dir}/generated")
    target_link_libraries(aether_xsystem35_encoding_contract PRIVATE aether_xsystem35_core)
    add_test(NAME xsystem35-encoding-contract COMMAND aether_xsystem35_encoding_contract)
endif()

if(TARGET aether_xsystem35_core)
    find_package(SDL2 CONFIG REQUIRED)
    add_executable(aether_xsystem35_mosaic_contract mosaic.c
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
    add_executable(aether_xsystem35_audio_contract audio.c)
    target_link_libraries(aether_xsystem35_audio_contract PRIVATE
        $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>
        $<IF:$<TARGET_EXISTS:SDL2_mixer::SDL2_mixer>,SDL2_mixer::SDL2_mixer,SDL2_mixer::SDL2_mixer-static>)
    add_test(NAME xsystem35-audio-contract COMMAND aether_xsystem35_audio_contract)
endif()
