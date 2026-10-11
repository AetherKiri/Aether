# Headless end-to-end test for the MAGES. provider: boots the embedded
# impacto host library against a marker game directory and asserts the
# rendered frames carry the MO8 design resolution.
set(MAGES_TEST_DATA "${AETHERKIRI_MAGES_DIR}")
if(NOT EXISTS "${MAGES_TEST_DATA}/lib/libimpacto_host.so")
    message(STATUS
        "AetherMAGES host package not found; mages runtime tests skipped")
    return()
endif()

add_executable(mages-runtime-provider
    provider.cpp)
target_compile_features(mages-runtime-provider PRIVATE cxx_std_17)
target_include_directories(mages-runtime-provider PRIVATE
    ${CMAKE_SOURCE_DIR}/abi/include
    ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(mages-runtime-provider PRIVATE
    AETHERKIRI_MAGES_TEST_DATA_DIR="${MAGES_TEST_DATA}")
target_link_libraries(mages-runtime-provider PRIVATE
    Catch2::Catch2WithMain
    aether_mages_runtime
    engine_api)
catch_discover_tests(mages-runtime-provider
    DL_PATHS
        "${CMAKE_BINARY_DIR}/vcpkg_installed/${VCPKG_TARGET_TRIPLET}/lib"
        "${AETHERKIRI_MAGES_DIR}/lib")
