cmake_minimum_required(VERSION 3.19)
project(aether_renpy_runtime LANGUAGES CXX)

if(NOT (WIN32 OR APPLE OR LINUX))
    message(FATAL_ERROR
        "The embedded Ren'Py SDK provider requires a desktop subprocess host")
endif()
if(IOS OR ANDROID OR WEB OR EMSCRIPTEN)
    message(FATAL_ERROR
        "The embedded Ren'Py SDK provider is not available on this platform")
endif()
if(NOT AETHERKIRI_RENPY_SDK_ROOT OR
   NOT IS_DIRECTORY "${AETHERKIRI_RENPY_SDK_ROOT}")
    message(FATAL_ERROR
        "AETHERKIRI_ENABLE_RENPY requires AETHERKIRI_RENPY_SDK_ROOT to point "
        "to an official Ren'Py SDK directory")
endif()

add_library(aether_renpy_runtime STATIC src/renpy_runtime_provider.cpp)
target_compile_features(aether_renpy_runtime PUBLIC cxx_std_17)
set_target_properties(aether_renpy_runtime PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_definitions(aether_renpy_runtime PRIVATE
    AETHERKIRI_RENPY_SDK_ROOT="${AETHERKIRI_RENPY_SDK_ROOT}"
    AETHERKIRI_RENPY_OVERLAY_SOURCE="${CMAKE_CURRENT_SOURCE_DIR}/python/aether_renpy_overlay.py")
target_include_directories(aether_renpy_runtime PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../abi/include")
if(NOT TARGET engine_api)
    message(FATAL_ERROR "Ren'Py provider requires the engine_api target")
endif()
target_link_libraries(aether_renpy_runtime PRIVATE engine_api)
if(UNIX)
    target_link_libraries(aether_renpy_runtime PRIVATE pthread)
endif()

if(ENABLE_TESTS)
    enable_testing()
    add_executable(renpy-provider-test tests/provider.cpp)
    target_compile_definitions(renpy-provider-test PRIVATE
        AETHERKIRI_RENPY_TEST_SDK_ROOT="${AETHERKIRI_RENPY_SDK_ROOT}")
    target_link_libraries(renpy-provider-test PRIVATE aether_renpy_runtime)
    add_test(NAME renpy-provider COMMAND renpy-provider-test)

    add_executable(renpy-input-mapping-test tests/input_mapping.cpp)
    target_link_libraries(renpy-input-mapping-test PRIVATE aether_renpy_runtime)
    add_test(NAME renpy-input-mapping COMMAND renpy-input-mapping-test)
endif()
