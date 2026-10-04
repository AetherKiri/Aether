cmake_minimum_required(VERSION 3.28)
project(aether_exhibit_runtime LANGUAGES CXX)

get_filename_component(AETHERKIRI_EXHIBIT_PROJECT_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

add_library(aether_exhibit_runtime STATIC src/exhibit_runtime_provider.cpp)
target_compile_features(aether_exhibit_runtime PUBLIC cxx_std_17)
set_target_properties(aether_exhibit_runtime PROPERTIES
    POSITION_INDEPENDENT_CODE ON)
target_include_directories(aether_exhibit_runtime PUBLIC
    include
    "${AETHERKIRI_EXHIBIT_PROJECT_ROOT}/abi/include")

# The provider adapts the pure-C++ core to the engine_runtime_provider_v1_t
# ABI, so the core target must already exist when this directory is added.
if(NOT TARGET aether_exhibit_core)
    message(FATAL_ERROR
        "aether_exhibit_runtime requires the aether_exhibit_core target. "
        "Configure with -DAETHERKIRI_ENABLE_EXHIBIT=ON so the root "
        "CMakeLists adds packages/AetherExhibit before bridge/exhibit_runtime.")
endif()
target_link_libraries(aether_exhibit_runtime PUBLIC aether_exhibit_core)

if(MSVC)
    target_compile_options(aether_exhibit_runtime PRIVATE /W4 /utf-8)
else()
    target_compile_options(aether_exhibit_runtime PRIVATE -Wall -Wextra)
endif()

# Provider-level tests arrive with the decoder components; the core keeps its
# own ctest suite under packages/AetherExhibit and builds standalone.
