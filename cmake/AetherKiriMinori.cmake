# Keep Minori's existing override interface. Its pinned CMake 3.19 policy
# scope may remove a normal variable when it first creates this cache entry,
# so create the typed entry before supplying an automatic local default.
set(AETHERKIRI_RUST_TARGET "" CACHE STRING
    "Rust target triple for the Minori runtime (auto-detected when empty)")

function(aetherkiri_add_minori_runtime source_dir)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND NOT AETHERKIRI_RUST_TARGET)
        get_filename_component(minori_ios_sdk_name "${CMAKE_OSX_SYSROOT}" NAME)
        string(TOLOWER "${minori_ios_sdk_name}" minori_ios_sdk_name)
        if(minori_ios_sdk_name MATCHES "^iphonesimulator([0-9]+([.][0-9]+)*)?([.]sdk)?$")
            set(minori_ios_arch "${CMAKE_OSX_ARCHITECTURES}")
            if(NOT minori_ios_arch)
                set(minori_ios_arch "${CMAKE_SYSTEM_PROCESSOR}")
            endif()
            if(minori_ios_arch STREQUAL "arm64" OR minori_ios_arch STREQUAL "aarch64")
                set(AETHERKIRI_RUST_TARGET "aarch64-apple-ios-sim")
            elseif(minori_ios_arch STREQUAL "x86_64")
                set(AETHERKIRI_RUST_TARGET "x86_64-apple-ios")
            else()
                message(FATAL_ERROR
                    "Minori has no Rust target mapping for iOS Simulator architecture ${minori_ios_arch}")
            endif()
        else()
            set(AETHERKIRI_RUST_TARGET "aarch64-apple-ios")
        endif()
    endif()
    # Automatic selection stays local to this invocation. The cache remains
    # empty, so reconfiguring from device to Simulator recomputes the default.
    # Preserve the actual SDK path and all upstream Cargo/build rules.
    add_subdirectory("${source_dir}" "${CMAKE_CURRENT_BINARY_DIR}/packages/AetherMinori")
endfunction()
