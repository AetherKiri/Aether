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

# iOS consumes the host core statically; macOS keeps its dylib interface.
if(IOS)
    add_library(aether_apple_host_core STATIC ${AETHERKIRI_APPLE_HOST_SOURCES})
else()
    add_library(aether_apple_host_core SHARED ${AETHERKIRI_APPLE_HOST_SOURCES})
endif()

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

option(AETHERKIRI_APPLE_HOST_IOS_PROBE "build internal UIKit iOS migration probe" OFF)
if(IOS AND AETHERKIRI_APPLE_HOST_IOS_PROBE)
    enable_language(OBJCXX)
    set(_probe_dir "${CMAKE_SOURCE_DIR}/apps/apple_host/IOSProbe")
    set(_hostkit "${CMAKE_SOURCE_DIR}/apps/apple_host/HostKit")
    set(_probe_resources
        "${CMAKE_SOURCE_DIR}/apps/godot_app/builtin_demos/aetherkiri-kag3/data.xp3"
        "${CMAKE_SOURCE_DIR}/apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf")
    add_executable(AetherHostIOSProbe MACOSX_BUNDLE
        "${_probe_dir}/main.mm" "${_hostkit}/EngineSession.mm" "${_hostkit}/MetalBridge.mm"
        "${CMAKE_SOURCE_DIR}/apps/apple_host/IOSHost/MobileSessionDriver.mm"
        "${CMAKE_SOURCE_DIR}/apps/apple_host/IOSHost/MobileGameCanvas.mm"
        "$<$<CONFIG:Debug>:${CMAKE_SOURCE_DIR}/apps/apple_host/Tests/MobileSessionDriverIntegration.mm>"
        ${_probe_resources})
    set_source_files_properties(${_probe_resources} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    target_compile_features(AetherHostIOSProbe PRIVATE cxx_std_17)
    target_compile_options(AetherHostIOSProbe PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    target_include_directories(AetherHostIOSProbe PRIVATE "${_hostkit}" "${CMAKE_SOURCE_DIR}/apps/apple_host/IOSHost" "${CMAKE_SOURCE_DIR}/abi/include")
    target_link_libraries(AetherHostIOSProbe PRIVATE aether_apple_host_core engine_api
        "-framework UIKit" "-framework Foundation" "-framework QuartzCore"
        "-framework Metal" "-framework MetalKit" "-framework CoreGraphics"
        "-framework CoreVideo" "-framework CoreMedia" "-framework VideoToolbox"
        "-framework AVFoundation" "-framework AudioToolbox" "-framework Accelerate"
        "-framework ImageIO" "-framework CoreText" "-framework Security" "-framework GameController"
        "-framework CoreHaptics")
    set_property(TARGET AetherHostIOSProbe PROPERTY LINK_LIBRARY_OVERRIDE_krkr2plugin WHOLE_ARCHIVE)
    set_target_properties(AetherHostIOSProbe PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${_probe_dir}/Info.plist.in"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
endif()
