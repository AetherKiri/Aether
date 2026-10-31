# ggml enables -march=native unless it detects a reproducible/cross build.
# When producing x86_64 on an Apple Silicon host, clang expands that flag to
# apple-m1 and rejects it for the x86 target. Scope the reproducible-build hint
# to ggml so the rest of the dependency graph keeps its existing ABI.
set(_aether_had_source_date_epoch FALSE)
if(DEFINED ENV{SOURCE_DATE_EPOCH})
    set(_aether_had_source_date_epoch TRUE)
    set(_aether_source_date_epoch "$ENV{SOURCE_DATE_EPOCH}")
endif()
set(ENV{SOURCE_DATE_EPOCH} "1")

# Keep the upstream recipe and patches aligned with our 0.11.1 manifest.
# The llama-cpp override in vcpkg.json must stay compatible with this overlay;
# upgrade the pair together rather than updating llama-cpp through the baseline.
# Source: microsoft/vcpkg at 9e593bb18ea69cc5095e012465dcd675a822ed0d.
# A fresh vcpkg checkout may contain a newer recipe with a different hash.
include("${CMAKE_CURRENT_LIST_DIR}/upstream-portfile.cmake")

if(_aether_had_source_date_epoch)
    set(ENV{SOURCE_DATE_EPOCH} "${_aether_source_date_epoch}")
else()
    unset(ENV{SOURCE_DATE_EPOCH})
endif()
