cmake_minimum_required(VERSION 3.19)

# Apple-native host core library (SwiftUI + Metal host).
#
# Links the engine closure (engine_api + krkr2 glue + runtimes) with the same
# "Phase 2d link flip" as bridge/godot_extension: the krkr2 glue is linked by
# the host library and installs its legacy services table at load time
# (src/host_core.cpp). engine_api / provider ABI stay untouched.
#
# Docs: doc/apple_host.md, doc/apple_host_seam_inventory.md

project(aether_apple_host_core LANGUAGES C CXX)

set(AETHERKIRI_APPLE_HOST_SOURCES
    src/host_core.cpp
)

add_library(aether_apple_host_core SHARED ${AETHERKIRI_APPLE_HOST_SOURCES})

target_compile_features(aether_apple_host_core PRIVATE cxx_std_17)

target_include_directories(aether_apple_host_core PRIVATE
    ${CMAKE_SOURCE_DIR}/abi/include
    ${CMAKE_SOURCE_DIR}/abi/src
    ${CMAKE_SOURCE_DIR}/bridge/onscripter_runtime/include
    ${CMAKE_SOURCE_DIR}/bridge/siglus_runtime/include
    ${CMAKE_SOURCE_DIR}/bridge/rfvp_runtime/include
)

if(TARGET engine_api)
    target_link_libraries(aether_apple_host_core PRIVATE engine_api)
endif()

if(TARGET aether_krkr2_runtime)
    # Mirrors the Godot extension: the krkr2 runtime glue is linked by the
    # host library, not engine_api, and installs the legacy services table.
    target_link_libraries(aether_apple_host_core PRIVATE aether_krkr2_runtime)
    target_compile_definitions(aether_apple_host_core PRIVATE
        AETHERKIRI_WITH_KRKR2=1)
endif()
if(TARGET aether_onscripter_runtime)
    target_link_libraries(aether_apple_host_core PRIVATE
        aether_onscripter_runtime)
    target_compile_definitions(aether_apple_host_core PRIVATE
        AETHERKIRI_WITH_ONSCRIPTER=1)
endif()
if(TARGET aether_siglus_runtime)
    target_link_libraries(aether_apple_host_core PRIVATE
        aether_siglus_runtime)
    target_compile_definitions(aether_apple_host_core PRIVATE
        AETHERKIRI_WITH_SIGLUS=1)
endif()
if(TARGET aether_minori_runtime)
    target_link_libraries(aether_apple_host_core PRIVATE
        aether_minori_runtime)
    target_compile_definitions(aether_apple_host_core PRIVATE
        AETHERKIRI_WITH_MINORI=1)
endif()
if(TARGET aether_rfvp_runtime)
    target_link_libraries(aether_apple_host_core PRIVATE aether_rfvp_runtime)
    target_compile_definitions(aether_apple_host_core PRIVATE
        AETHERKIRI_WITH_RFVP=1)
endif()
if(AETHERKIRI_ENABLE_SOFTPAL_RUNTIME AND
   COMMAND aethersoftpal_extend_engine_api)
    aethersoftpal_extend_engine_api(aether_apple_host_core)
    target_compile_definitions(aether_apple_host_core PRIVATE
        AETHERKIRI_WITH_SOFTPAL=1)
endif()
if(TARGET krkr2plugin)
    set_property(TARGET aether_apple_host_core PROPERTY
        LINK_LIBRARY_OVERRIDE_krkr2plugin WHOLE_ARCHIVE)
endif()

set_target_properties(aether_apple_host_core PROPERTIES
    OUTPUT_NAME "aether_apple_host_core"
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "@loader_path"
)
