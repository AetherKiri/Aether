cmake_minimum_required(VERSION 3.28)

project(aether_mages_runtime LANGUAGES CXX)

# The MAGES. runtime is an impacto host package built from the AetherMAGES
# fork (IMPACTO_BUILD_HOST=ON cmake install):
#
#   <AETHERKIRI_MAGES_DIR>/lib/libimpacto_host.so
#   <AETHERKIRI_MAGES_DIR>/include/impacto_host.h
#   <AETHERKIRI_MAGES_DIR>/{profiles,resources,shaders,gamedefinitions.lua}
#
# Point AETHERKIRI_MAGES_DIR at that install tree (or set the
# AETHERKIRI_MAGES_DATA_DIR environment variable at runtime).
set(MAGES_HOST_ROOT "${AETHERKIRI_MAGES_DIR}")

set(MAGES_HOST_LIBRARY "${MAGES_HOST_ROOT}/lib/libimpacto_host.so")
if(NOT EXISTS "${MAGES_HOST_LIBRARY}")
    message(STATUS
        "AetherMAGES host package unavailable at ${MAGES_HOST_ROOT}; "
        "the MAGES. runtime provider is skipped")
    return()
endif()
if(NOT EXISTS "${MAGES_HOST_ROOT}/include/impacto_host.h")
    message(FATAL_ERROR
        "AetherMAGES host package at ${MAGES_HOST_ROOT} is missing "
        "include/impacto_host.h")
endif()

find_package(OpenAL CONFIG REQUIRED)

add_library(aether_mages_runtime STATIC
    src/mages_runtime_provider.cpp
    src/mages_audio_output.cpp
)

target_compile_features(aether_mages_runtime PUBLIC cxx_std_17)
set_target_properties(aether_mages_runtime PROPERTIES
    POSITION_INDEPENDENT_CODE ON)

target_include_directories(aether_mages_runtime PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${MAGES_HOST_ROOT}/include"
)

target_compile_definitions(aether_mages_runtime PRIVATE
    AETHERKIRI_MAGES_DATA_DIR="${MAGES_HOST_ROOT}")

# The provider only calls the stable C ABI of the host library.
target_link_libraries(aether_mages_runtime PUBLIC
    engine_api
    "${MAGES_HOST_LIBRARY}"
)

# Audio PCM consumer: drains the impacto host mixer FIFO into an OpenAL
# stream, the same cross-platform output path the siglus runtime uses.
target_link_libraries(aether_mages_runtime PRIVATE
    OpenAL::OpenAL
)

if(AETHERKIRI_INTERNAL_ENABLED AND COMMAND aetherinternal_extend_mages)
    aetherinternal_extend_mages(aether_mages_runtime)
endif()
