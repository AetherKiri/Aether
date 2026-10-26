cmake_minimum_required(VERSION 3.28)
project(AetherXsystem4NativeProbe LANGUAGES C CXX)
find_package(SDL2 CONFIG REQUIRED)
get_filename_component(AETHER_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(VCS_TAG "aether-native")
add_subdirectory("${AETHER_ROOT}/bridge/xsystem4_runtime" "${CMAKE_CURRENT_BINARY_DIR}/runtime")
find_package(SDL2_image CONFIG REQUIRED)
add_executable(aether_xsystem4_native_probe probe.cpp)
target_compile_features(aether_xsystem4_native_probe PRIVATE cxx_std_17)
target_include_directories(aether_xsystem4_native_probe PRIVATE
    "${AETHER_ROOT}/abi/include" "${AETHER_ROOT}/packages/xsystem4/include")
target_link_libraries(aether_xsystem4_native_probe PRIVATE aether_xsystem4_runtime
    $<IF:$<TARGET_EXISTS:SDL2_image::SDL2_image>,SDL2_image::SDL2_image,SDL2_image::SDL2_image-static>)
enable_testing()
add_executable(aether_xsystem4_native_contract contract.cpp)
target_compile_features(aether_xsystem4_native_contract PRIVATE cxx_std_17)
target_include_directories(aether_xsystem4_native_contract PRIVATE "${AETHER_ROOT}/abi/include")
target_link_libraries(aether_xsystem4_native_contract PRIVATE aether_xsystem4_runtime)
add_test(NAME xsystem4-native-contract COMMAND aether_xsystem4_native_contract)
add_executable(aether_xsystem4_scene_keeper_contract scene_keeper.c)
target_include_directories(aether_xsystem4_scene_keeper_contract PRIVATE
    "${AETHER_ROOT}/packages/xsystem4/include"
    "${AETHER_ROOT}/packages/xsystem4/src/hll"
    "${AETHER_ROOT}/packages/xsystem4/subprojects/libsys4/include")
target_link_libraries(aether_xsystem4_scene_keeper_contract PRIVATE aether_xsystem4_runtime)
add_test(NAME xsystem4-scene-keeper-contract COMMAND aether_xsystem4_scene_keeper_contract)
add_executable(aether_xsystem4_afa_contract afa.cpp)
target_compile_features(aether_xsystem4_afa_contract PRIVATE cxx_std_17)
target_include_directories(aether_xsystem4_afa_contract PRIVATE
    "${AETHER_ROOT}/packages/xsystem4/subprojects/libsys4/include")
target_link_libraries(aether_xsystem4_afa_contract PRIVATE aether_xsystem4_runtime)
add_test(NAME xsystem4-afa-contract COMMAND aether_xsystem4_afa_contract)
add_executable(aether_xsystem4_assets_contract assets.cpp)
target_compile_features(aether_xsystem4_assets_contract PRIVATE cxx_std_17)
target_include_directories(aether_xsystem4_assets_contract PRIVATE
    "${AETHER_ROOT}/packages/xsystem4/include"
    "${AETHER_ROOT}/packages/xsystem4/subprojects/libsys4/include")
target_link_libraries(aether_xsystem4_assets_contract PRIVATE aether_xsystem4_runtime)
add_test(NAME xsystem4-assets-contract COMMAND aether_xsystem4_assets_contract)
add_executable(aether_xsystem4_rance_quest_contract rance_quest.cpp)
target_compile_features(aether_xsystem4_rance_quest_contract PRIVATE cxx_std_17)
target_include_directories(aether_xsystem4_rance_quest_contract PRIVATE
    "${AETHER_ROOT}/packages/xsystem4/include"
    "${AETHER_ROOT}/packages/xsystem4/subprojects/libsys4/include")
target_link_libraries(aether_xsystem4_rance_quest_contract PRIVATE aether_xsystem4_runtime)
add_test(NAME xsystem4-rance-quest-contract COMMAND aether_xsystem4_rance_quest_contract)
add_executable(aether_xsystem4_tga_contract tga.cpp)
target_compile_features(aether_xsystem4_tga_contract PRIVATE cxx_std_17)
target_include_directories(aether_xsystem4_tga_contract PRIVATE
    "${AETHER_ROOT}/packages/xsystem4/subprojects/libsys4/include")
target_link_libraries(aether_xsystem4_tga_contract PRIVATE aether_xsystem4_runtime
    $<IF:$<TARGET_EXISTS:SDL2_image::SDL2_image>,SDL2_image::SDL2_image,SDL2_image::SDL2_image-static>)
add_test(NAME xsystem4-tga-contract COMMAND aether_xsystem4_tga_contract)
add_executable(aether_xsystem4_font_fallback_contract font_fallback.c)
target_compile_definitions(aether_xsystem4_font_fallback_contract PRIVATE XSYSTEM4_EMBEDDED)
if(NOT APPLE)
    target_compile_definitions(aether_xsystem4_font_fallback_contract PRIVATE USE_GLES)
endif()
target_include_directories(aether_xsystem4_font_fallback_contract PRIVATE
    "${AETHER_ROOT}/packages/xsystem4/include"
    "${AETHER_ROOT}/packages/xsystem4/subprojects/libsys4/include")
target_link_libraries(aether_xsystem4_font_fallback_contract PRIVATE aether_xsystem4_runtime
    $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>)
add_test(NAME xsystem4-font-fallback-contract COMMAND aether_xsystem4_font_fallback_contract)
