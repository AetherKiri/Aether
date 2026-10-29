if(NOT EXISTS "${AETHERKIRI_ENTISGLS_DIR}/aether_runtime/CMakeLists.txt")
    message(FATAL_ERROR "Initialize packages/EntisGLS-SDL3 on its aether branch, or disable AETHERKIRI_ENABLE_ENTISGLS")
endif()
set(AETHER_ENTISGLS_HOST_ROOT "${CMAKE_SOURCE_DIR}")
add_subdirectory("${AETHERKIRI_ENTISGLS_DIR}/aether_runtime"
    "${CMAKE_CURRENT_BINARY_DIR}/runtime")
