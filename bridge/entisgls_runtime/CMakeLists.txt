if(NOT EXISTS "${AETHERKIRI_ENTISGLS_DIR}/aether_runtime/CMakeLists.txt")
    message(FATAL_ERROR "Initialize packages/AetherEntisGLS on its aether branch, or disable AETHERKIRI_ENABLE_ENTISGLS")
endif()
if(IOS AND NOT TARGET z)
    # Map upstream's bare z link items to the shared vcpkg archive rather
    # than also pulling in the SDK's system zlib.
    add_library(z ALIAS ZLIB::ZLIB)
endif()
set(AETHER_ENTISGLS_HOST_ROOT "${CMAKE_SOURCE_DIR}")
add_subdirectory("${AETHERKIRI_ENTISGLS_DIR}/aether_runtime"
    "${CMAKE_CURRENT_BINARY_DIR}/runtime")

# Keep diagnostics in the port code, but treat the original SDK and the
# generated SDK headers as external headers at the embedding boundary.
foreach(entis_target study_sdl_platform legacy_foundation)
    get_target_property(entis_includes ${entis_target} INTERFACE_INCLUDE_DIRECTORIES)
    foreach(entis_include IN LISTS entis_includes)
        if(entis_include MATCHES "/(EntisGLS/[^/]+/Include|legacy_generated/[^/]+/Include|sdk-sdl/[Ii]nclude)(/|$)")
            set_property(TARGET ${entis_target} APPEND PROPERTY
                INTERFACE_SYSTEM_INCLUDE_DIRECTORIES "${entis_include}")
            if(entis_target STREQUAL "legacy_foundation")
                target_include_directories(${entis_target} SYSTEM PRIVATE "${entis_include}")
            endif()
        endif()
    endforeach()
endforeach()

# The iOS Entis renderer uses the SDK's OpenGL ES backend.
if(IOS)
    target_compile_definitions(study_sdl_platform INTERFACE GLES_SILENCE_DEPRECATION)
endif()
