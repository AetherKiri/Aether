# Headless end-to-end test for the MAGES. provider: boots the embedded
# impacto host library (compiled from the AetherMAGES submodule by this
# build) against a marker game directory and asserts the rendered frames
# carry the MO8 design resolution.
if(NOT TARGET aether_mages_runtime)
    return()
endif()

add_executable(mages-runtime-provider
    provider.cpp)
target_compile_features(mages-runtime-provider PRIVATE cxx_std_17)
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
