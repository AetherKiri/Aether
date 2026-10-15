cmake_minimum_required(VERSION 3.28)

project(aether_mages_runtime LANGUAGES C CXX)

# The MAGES. runtime is embedded exactly like the other runtime packages:
# the AetherMAGES submodule (the impacto engine plus its host bridge) is
# compiled by this build into the libimpacto_host shared library, and the
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
# them up: host bridge mode (offscreen GL + FIFO audio) with no install rules
# (this build stages the library and the data tree itself).
set(IMPACTO_BUILD_HOST ON)
set(IMPACTO_EMBEDDED ON)
add_subdirectory("${MAGES_HOST_SOURCE}" "${CMAKE_BINARY_DIR}/aethermages-impacto")

# On Apple platforms SDL3, ggml-metal and other vcpkg ports weak-link
# Metal/GameController/QuartzCore (WEAK_FRAMEWORK), while the Godot extension
# strong-links them (FRAMEWORK). CMake refuses to mix the two features for the
# same framework. CMAKE_LINK_LIBRARY_OVERRIDE_<library> (CMake 3.27+) forces a
# single feature on every consumer in this scope, so the final Godot extension
# links cleanly regardless of which dependency introduced the weak link.
# Propagate to the parent scope so aether_kiri_godot (created later in
# bridge/godot_extension) inherits the override.
if(APPLE)
    foreach(_fw Metal QuartzCore GameController AppKit CoreAudio AudioToolbox)
        set(CMAKE_LINK_LIBRARY_OVERRIDE_${_fw} FRAMEWORK)
        set(CMAKE_LINK_LIBRARY_OVERRIDE_${_fw} FRAMEWORK PARENT_SCOPE)
    endforeach()
endif()

# Stage the engine data tree impacto boots from (the host bridge chdirs into
# the data dir, so shaders/ must sit next to gamedefinitions.lua; in the
# impacto repository they live under src/shaders). copy_directory_if_different
# keeps this incremental across builds and submodule bumps.
set(MAGES_DATA_DIR "${CMAKE_CURRENT_BINARY_DIR}/mages-data")
add_custom_target(aether_mages_stage_data ALL
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

# Audio PCM consumer: drains the impacto host mixer FIFO into an OpenAL
# stream, the same cross-platform output path the siglus runtime uses.
target_link_libraries(aether_mages_runtime PRIVATE
    OpenAL::OpenAL
)

if(AETHERKIRI_INTERNAL_ENABLED AND COMMAND aetherinternal_extend_mages)
    aetherinternal_extend_mages(aether_mages_runtime)
endif()
