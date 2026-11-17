cmake_minimum_required(VERSION 3.28)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(AetherSystemNNNContract LANGUAGES C CXX)
    include(CTest)
endif()
get_filename_component(AETHER_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(AETHERKIRI_SYSTEMNNN_DIR "${AETHER_ROOT}/packages/SystemNNN-Emberfall" CACHE PATH "Runtime source")
if(NOT TARGET engine_api)
    if(NOT COMMAND aetherkiri_limit_runtime_exports)
        function(aetherkiri_limit_runtime_exports target kind)
        endfunction()
    endif()
    add_subdirectory("${AETHER_ROOT}/abi" abi)
endif()
if(NOT TARGET aether_systemnnn_runtime)
    add_subdirectory("${AETHER_ROOT}/bridge/systemnnn_runtime" runtime)
endif()
add_executable(systemnnn-provider-contract provider.cpp)
target_link_libraries(systemnnn-provider-contract PRIVATE aether_systemnnn_runtime)
target_compile_definitions(systemnnn-provider-contract PRIVATE EMBERFALL_ROOT="${AETHERKIRI_SYSTEMNNN_DIR}")
add_test(NAME systemnnn-provider-contract COMMAND systemnnn-provider-contract)
set_tests_properties(systemnnn-provider-contract PROPERTIES ENVIRONMENT "ALSOFT_DRIVERS=null")
add_executable(systemnnn-text-contract "${AETHER_ROOT}/bridge/systemnnn_runtime/tests/systemnnn_text_test.cpp")
target_include_directories(systemnnn-text-contract PRIVATE "${AETHER_ROOT}/bridge/systemnnn_runtime/src")
target_link_libraries(systemnnn-text-contract PRIVATE aether_systemnnn_runtime emberfall-render)
add_test(NAME systemnnn-text-contract COMMAND systemnnn-text-contract "${AETHER_ROOT}/apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf")

add_executable(systemnnn-startup-contract startup.cpp)
target_include_directories(systemnnn-startup-contract PRIVATE "${AETHER_ROOT}/bridge/systemnnn_runtime/src")
target_compile_definitions(systemnnn-startup-contract PRIVATE EMBERFALL_ROOT="${AETHERKIRI_SYSTEMNNN_DIR}")
target_link_libraries(systemnnn-startup-contract PRIVATE aether_systemnnn_runtime emberfall-scene)
add_test(NAME systemnnn-startup-contract COMMAND systemnnn-startup-contract)

add_executable(systemnnn-progress-contract
    "${AETHER_ROOT}/bridge/systemnnn_runtime/tests/systemnnn_progress_tests.cpp")
# This fixture includes progress.cpp to inspect codec details independently.
target_link_libraries(systemnnn-progress-contract PRIVATE emberfall-scene)
add_test(NAME systemnnn-progress-contract COMMAND systemnnn-progress-contract)

add_executable(systemnnn-audio-contract audio.cpp
    "${AETHER_ROOT}/bridge/systemnnn_runtime/src/systemnnn_audio.cpp")
target_include_directories(systemnnn-audio-contract PRIVATE "${AETHER_ROOT}/bridge/systemnnn_runtime/src")
find_package(OpenAL REQUIRED)
find_package(Threads REQUIRED)
target_link_libraries(systemnnn-audio-contract PRIVATE OpenAL::OpenAL Threads::Threads)
add_test(NAME systemnnn-audio-contract COMMAND systemnnn-audio-contract)
set_tests_properties(systemnnn-audio-contract PROPERTIES ENVIRONMENT "ALSOFT_DRIVERS=null" TIMEOUT 15)

add_executable(systemnnn-presenter-contract "${AETHER_ROOT}/tests/systemnnn_presenter_test.cpp")
target_include_directories(systemnnn-presenter-contract PRIVATE "${AETHER_ROOT}/bridge/systemnnn_runtime/src")
target_link_libraries(systemnnn-presenter-contract PRIVATE aether_systemnnn_runtime emberfall-scene)
add_test(NAME systemnnn-presenter-contract COMMAND systemnnn-presenter-contract
    "${AETHER_ROOT}/apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf")

add_executable(systemnnn-native-panel-contract
    "${AETHER_ROOT}/bridge/systemnnn_runtime/tests/systemnnn_native_panel_test.cpp")
target_include_directories(systemnnn-native-panel-contract PRIVATE "${AETHER_ROOT}/bridge/systemnnn_runtime/src")
add_test(NAME systemnnn-native-panel-contract COMMAND systemnnn-native-panel-contract)

foreach(contract provider text startup progress audio presenter native-panel)
    set(target "systemnnn-${contract}-contract")
    target_compile_features(${target} PRIVATE cxx_std_17)
    # Keep assert-based and explicit checks active in every Release build.
    if(MSVC)
        target_compile_options(${target} PRIVATE /UNDEBUG /utf-8)
    else()
        target_compile_options(${target} PRIVATE -UNDEBUG)
    endif()
    set_tests_properties(${target} PROPERTIES TIMEOUT 120)
    if(WIN32 AND (contract STREQUAL "provider" OR contract STREQUAL "text" OR contract STREQUAL "startup" OR contract STREQUAL "presenter"))
        add_custom_command(TARGET ${target} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "$<TARGET_FILE:engine_api>" "$<TARGET_FILE_DIR:${target}>")
    endif()
endforeach()
set_tests_properties(systemnnn-audio-contract PROPERTIES TIMEOUT 15)

find_package(Python3 COMPONENTS Interpreter QUIET)
find_package(Java COMPONENTS Runtime Development QUIET)
if(Python3_Interpreter_FOUND AND Java_FOUND)
    add_test(NAME systemnnn-progress-java-contract
        COMMAND "${Python3_EXECUTABLE}" "${AETHER_ROOT}/bridge/systemnnn_runtime/tests/check_progress_java.py"
            "${AETHERKIRI_SYSTEMNNN_DIR}" "$<TARGET_FILE:systemnnn-progress-contract>")
    set_tests_properties(systemnnn-progress-java-contract PROPERTIES TIMEOUT 120)
endif()
