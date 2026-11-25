option(BUILD_NATIVE_HOST_SHARED "build the native host as a shared library" OFF)
if(BUILD_NATIVE_HOST_SHARED)
    add_library(aether_native_host SHARED src/runtime_session.cpp)
else()
    add_library(aether_native_host STATIC src/runtime_session.cpp)
endif()
target_compile_features(aether_native_host PUBLIC cxx_std_17)
target_include_directories(aether_native_host PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(aether_native_host PUBLIC engine_api)
if(APPLE AND BUILD_NATIVE_HOST_SHARED)
    set_target_properties(aether_native_host PROPERTIES
        BUILD_WITH_INSTALL_RPATH YES
        INSTALL_RPATH "@loader_path")
endif()

if(TARGET aether_onscripter_runtime)
    target_compile_definitions(aether_native_host PRIVATE AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
    target_link_libraries(aether_native_host PRIVATE aether_onscripter_runtime)
endif()
