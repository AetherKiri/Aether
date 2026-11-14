# This narrow build can run without configuring the full engine or .NET host.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    cmake_minimum_required(VERSION 3.28)
    project(n2system_provider_contract LANGUAGES CXX)
    enable_testing()
    get_filename_component(AETHERKIRI_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
    set(AETHERKIRI_N2SYSTEM_DIR "${AETHERKIRI_SOURCE_DIR}/packages/AetherN2System")
else()
    set(AETHERKIRI_SOURCE_DIR "${CMAKE_SOURCE_DIR}")
endif()
find_package(nlohmann_json CONFIG REQUIRED)
find_package(Threads REQUIRED)
# The test double validates the provider's C ABI calls and thread ownership;
# production always loads the actual NativeAOT image from its own package.
add_library(n2system-contract-host SHARED host_spy.cpp)
set_target_properties(n2system-contract-host PROPERTIES PREFIX "" OUTPUT_NAME aether_n2system
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/n2system-runtime/$<0:>"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/n2system-runtime/$<0:>")
target_compile_features(n2system-contract-host PRIVATE cxx_std_17)
target_include_directories(n2system-contract-host PRIVATE "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/include")
add_executable(n2system-runtime-provider provider.cpp
    "${AETHERKIRI_SOURCE_DIR}/bridge/n2system_runtime/src/n2system_runtime_provider.cpp")
set_target_properties(n2system-runtime-provider PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/$<0:>")
target_compile_features(n2system-runtime-provider PRIVATE cxx_std_17)
target_include_directories(n2system-runtime-provider PRIVATE
    "${AETHERKIRI_SOURCE_DIR}/bridge/n2system_runtime/include"
    "${AETHERKIRI_SOURCE_DIR}/bridge/n2system_runtime/src"
    "${AETHERKIRI_SOURCE_DIR}/abi/include"
    "${AETHERKIRI_N2SYSTEM_DIR}/aether_runtime/include")
target_link_libraries(n2system-runtime-provider PRIVATE nlohmann_json::nlohmann_json Threads::Threads ${CMAKE_DL_LIBS})
add_dependencies(n2system-runtime-provider n2system-contract-host)
add_test(NAME n2system-runtime-provider COMMAND n2system-runtime-provider)
