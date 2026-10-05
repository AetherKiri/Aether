# Reuse the product ABI and the package-owned SoftPal source graph, while
# omitting every other runtime, tool and product dependency.
message(STATUS "SoftPal engine-only build: other runtimes disabled")

option(BUILD_GODOT_EXTENSION "build the Godot host for the SoftPal engine" OFF)
set(AETHERKIRI_SOFTPAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/packages/AetherSoftPal"
    CACHE PATH "path to an AetherSoftPal package checkout")
set(AETHERKIRI_INTERNAL_ENABLED OFF)
set(AETHERKIRI_ENABLE_SOFTPAL_RUNTIME ON)
set(AETHER_SOFTPAL_BUILD_TESTS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(MSVC)
    add_compile_options("$<$<COMPILE_LANGUAGE:CXX>:/EHsc>" /utf-8)
    add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/AetherKiriBinaryProtection.cmake")
if(NOT EXISTS "${AETHERKIRI_SOFTPAL_DIR}/cmake/AetherSoftPalConfig.cmake")
    message(FATAL_ERROR "Initialize packages/AetherSoftPal or set AETHERKIRI_SOFTPAL_DIR")
endif()
set(AetherSoftPal_DIR "${AETHERKIRI_SOFTPAL_DIR}/cmake")
find_package(AetherSoftPal CONFIG REQUIRED NO_DEFAULT_PATH)
if(NOT AETHERSOFTPAL_PACKAGE_API_VERSION EQUAL 1 OR
   NOT COMMAND aethersoftpal_extend_engine_api)
    message(FATAL_ERROR "AetherSoftPal package API is incompatible")
endif()

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/abi")
aethersoftpal_extend_engine_api(engine_api)
find_package(spdlog CONFIG REQUIRED)
target_link_libraries(engine_api PRIVATE spdlog::spdlog)
target_compile_definitions(engine_api PRIVATE AETHERKIRI_ENGINE_WITH_SOFTPAL=1)
if(WIN32)
    target_link_libraries(engine_api PRIVATE user32 gdi32)
endif()

if(BUILD_GODOT_EXTENSION)
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/bridge/godot_extension")
endif()
