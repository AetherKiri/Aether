# Provider detection, GPU ABI and host lifecycle coverage. Godot execution is
# exercised separately by godot_gpu_smoke.gd with actual game resources.
if(NOT TARGET aether_mages_runtime)
    return()
endif()

add_executable(mages-runtime-provider
    provider.cpp)
target_compile_features(mages-runtime-provider PRIVATE cxx_std_17)
target_compile_definitions(mages-runtime-provider PRIVATE
    AETHERKIRI_MAGES_TEST_DATA_DIR="${CMAKE_BINARY_DIR}/bridge/mages_runtime/mages-data")
target_include_directories(mages-runtime-provider PRIVATE
    ${CMAKE_SOURCE_DIR}/abi/include
    ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(mages-runtime-provider PRIVATE
    Catch2::Catch2WithMain
    aether_mages_runtime
    engine_api)
catch_discover_tests(mages-runtime-provider
    DL_PATHS
        "${CMAKE_BINARY_DIR}/vcpkg_installed/${VCPKG_TARGET_TRIPLET}/lib")
