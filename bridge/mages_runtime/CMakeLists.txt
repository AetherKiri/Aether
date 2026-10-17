cmake_minimum_required(VERSION 3.28)

project(aether_mages_runtime LANGUAGES C CXX)

# The MAGES. runtime is embedded exactly like the other runtime packages:
# the AetherMAGES submodule (the impacto engine plus its host bridge) is
# compiled by this build into the platform's host library, and the
# engine data tree is staged into the build tree for the provider to boot
# from. There is no separately prebuilt host package.
#
#   packages/AetherMAGES/            impacto sources (IMPACTO_BUILD_HOST=ON)
#   ${CMAKE_BINARY_DIR}/mages-data/  gamedefinitions.lua, profiles/,
#                                    resources/, shaders/
set(MAGES_HOST_SOURCE "${AETHERKIRI_MAGES_DIR}")
if(NOT EXISTS "${MAGES_HOST_SOURCE}/src/host/impacto_host.cpp")
    message(STATUS
        "AetherMAGES submodule unavailable at ${MAGES_HOST_SOURCE}; "
        "the MAGES. runtime provider is skipped "
        "(git submodule update --init packages/AetherMAGES)")
    return()
endif()

find_package(OpenAL CONFIG REQUIRED)

# Build the embedded impacto host library from the submodule. The option
# values are set before add_subdirectory so impacto's own CMakeLists picks
# them up: host GPU commands + FIFO audio with no install rules
# (this build stages the library and the data tree itself).
set(IMPACTO_BUILD_HOST ON)
set(IMPACTO_EMBEDDED ON)
# Build the vendored LibAtrac9 decoder as a static archive so it links into
# the impacto library (static or a desktop shared image) instead of shipping
# a separate libatrac9.so/.dylib the host packaging would have to stage.
set(LIBATRAC9_BUILD_SHARED OFF)
add_subdirectory("${MAGES_HOST_SOURCE}" "${CMAKE_BINARY_DIR}/aethermages-impacto")

# LibAtrac9 enables IPO (LTO) when the toolchain supports it. Bitcode members
# would survive into the merged iOS extension archive where llvm-objcopy (the
# host's SDL2 symbol isolation pass) rejects them as invalid object files. The decoder
# is small; disabling LTO has no measurable cost.
if(TARGET atrac9)
    set_property(TARGET atrac9 PROPERTY INTERPROCEDURAL_OPTIMIZATION FALSE)
endif()

# Stage the engine data tree impacto boots from (the host bridge chdirs into
# the data dir, so shaders/ must sit next to gamedefinitions.lua; in the
# impacto repository they live under src/shaders). copy_directory_if_different
# keeps this incremental across builds and submodule bumps.
set(MAGES_DATA_DIR "${CMAKE_CURRENT_BINARY_DIR}/mages-data")
find_package(Python3 REQUIRED COMPONENTS Interpreter)
file(GLOB_RECURSE MAGES_DATA_FILES CONFIGURE_DEPENDS
    "${MAGES_HOST_SOURCE}/profiles/*"
    "${MAGES_HOST_SOURCE}/resources/*"
    "${MAGES_HOST_SOURCE}/src/shaders/*")
set(MAGES_DATA_PACKAGE "${CMAKE_SOURCE_DIR}/apps/godot_app/mages_runtime/data.zip")
add_custom_command(OUTPUT "${MAGES_DATA_PACKAGE}"
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/tools/package_mages_data.py"
        "${MAGES_HOST_SOURCE}" "${MAGES_DATA_PACKAGE}"
    DEPENDS ${MAGES_DATA_FILES} "${MAGES_HOST_SOURCE}/gamedefinitions.lua"
        "${CMAKE_SOURCE_DIR}/tools/package_mages_data.py"
    COMMENT "Packing MAGES engine data for Godot exports"
    VERBATIM)
add_custom_target(aether_mages_stage_data ALL
    DEPENDS "${MAGES_DATA_PACKAGE}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${MAGES_HOST_SOURCE}/gamedefinitions.lua"
        "${MAGES_DATA_DIR}/gamedefinitions.lua"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory_if_different
        "${MAGES_HOST_SOURCE}/profiles" "${MAGES_DATA_DIR}/profiles"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory_if_different
        "${MAGES_HOST_SOURCE}/resources" "${MAGES_DATA_DIR}/resources"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory_if_different
        "${MAGES_HOST_SOURCE}/src/shaders" "${MAGES_DATA_DIR}/shaders"
    COMMENT "Staging AetherMAGES engine data tree"
    VERBATIM
)

add_library(aether_mages_runtime STATIC
    src/mages_runtime_provider.cpp
    src/mages_audio_output.cpp
)

target_compile_features(aether_mages_runtime PUBLIC cxx_std_17)
set_target_properties(aether_mages_runtime PROPERTIES
    POSITION_INDEPENDENT_CODE ON)

target_include_directories(aether_mages_runtime PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${MAGES_HOST_SOURCE}/src/host"
)

target_compile_definitions(aether_mages_runtime PRIVATE
    AETHERKIRI_MAGES_DATA_DIR="${MAGES_DATA_DIR}")

# The provider only calls the stable C ABI of the host library built above.
target_link_libraries(aether_mages_runtime PUBLIC
    engine_api
    impacto
)
add_dependencies(aether_mages_runtime aether_mages_stage_data)

# On macOS, impacto is built as a separate SHARED library. Stage it into the
# Godot export bin directory (same location as aether_kiri_godot.dylib) so
# the extension can load it at runtime via @rpath.
if(APPLE AND NOT IOS)
    add_custom_command(TARGET aether_mages_runtime POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
            "${CMAKE_SOURCE_DIR}/apps/godot_app/bin/macos/$<LOWER_CASE:$<CONFIG>>"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:impacto>"
            "${CMAKE_SOURCE_DIR}/apps/godot_app/bin/macos/$<LOWER_CASE:$<CONFIG>>/$<TARGET_FILE_NAME:impacto>"
        VERBATIM)
endif()

# Audio PCM consumer: drains the impacto host mixer FIFO into an OpenAL
# stream, the same cross-platform output path the siglus runtime uses.
target_link_libraries(aether_mages_runtime PRIVATE
    OpenAL::OpenAL
)

if(AETHERKIRI_INTERNAL_ENABLED AND COMMAND aetherinternal_extend_mages)
    aetherinternal_extend_mages(aether_mages_runtime)
endif()
