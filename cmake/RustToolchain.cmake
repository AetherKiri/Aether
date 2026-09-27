# Resolve a single Rust toolchain for every runtime integration in this build.
#
# The Rust runtimes resolve cargo independently: AetherMinori and rfvp use
# find_program() (first hit on PATH) while BuildSiglusRs.cmake prefers the
# toolchain rustup reports. When a Homebrew rust shadows the rustup proxies
# on PATH the two resolutions disagree and the runtimes build against
# different rustc copies.
#
# This file unifies the configure-time cache (CARGO_EXECUTABLE / RUSTC_EXECUTABLE
# / RFVP_CARGO / RFVP_RUSTC) so every project records the same binaries. Cargo
# still resolves rustc by bare command name from PATH during the build, so the
# platform scripts (build_macos.sh / build_ios.sh / build_linux.sh /
# build_android.sh) additionally prepend the resolved toolchain's bin
# directory to PATH; that combination keeps the bundled std copies identical
# and avoids duplicate _rust_eh_personality symbols at the final link.

set(_aetherkiri_rust_bin_dir "")
find_program(_aetherkiri_rustup_executable rustup)
if(_aetherkiri_rustup_executable)
    execute_process(
        COMMAND "${_aetherkiri_rustup_executable}" which rustc
        OUTPUT_VARIABLE _aetherkiri_rustup_rustc
        ERROR_QUIET RESULT_VARIABLE _aetherkiri_rustup_result)
    string(STRIP "${_aetherkiri_rustup_rustc}" _aetherkiri_rustup_rustc)
    if(_aetherkiri_rustup_result EQUAL 0 AND EXISTS "${_aetherkiri_rustup_rustc}")
        get_filename_component(_aetherkiri_rust_bin_dir
            "${_aetherkiri_rustup_rustc}" DIRECTORY)
    endif()
endif()

if(NOT "${_aetherkiri_rust_bin_dir}" STREQUAL ""
        AND EXISTS "${_aetherkiri_rust_bin_dir}/cargo")
    if(NOT DEFINED CARGO_EXECUTABLE)
        set(CARGO_EXECUTABLE "${_aetherkiri_rust_bin_dir}/cargo" CACHE FILEPATH
            "cargo used by every Rust runtime build")
    endif()
    if(NOT DEFINED RUSTC_EXECUTABLE)
        set(RUSTC_EXECUTABLE "${_aetherkiri_rust_bin_dir}/rustc" CACHE FILEPATH
            "rustc used by every Rust runtime build")
    endif()
    if(NOT DEFINED RFVP_CARGO)
        set(RFVP_CARGO "${_aetherkiri_rust_bin_dir}/cargo" CACHE FILEPATH
            "cargo used by the rfvp runtime build")
    endif()
    if(NOT DEFINED RFVP_RUSTC)
        set(RFVP_RUSTC "${_aetherkiri_rust_bin_dir}/rustc" CACHE FILEPATH
            "rustc used by the rfvp runtime build")
    endif()
    message(STATUS
        "Rust toolchain: preferring rustup active toolchain "
        "${_aetherkiri_rust_bin_dir}")
endif()
unset(_aetherkiri_rustup_executable)
unset(_aetherkiri_rustup_rustc)
unset(_aetherkiri_rustup_result)
unset(_aetherkiri_rust_bin_dir)
