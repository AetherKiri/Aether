add_library(aether_native_host STATIC src/runtime_session.cpp)
target_compile_features(aether_native_host PUBLIC cxx_std_17)
target_include_directories(aether_native_host PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(aether_native_host PUBLIC engine_api aether_game_detection)

if(TARGET aether_onscripter_runtime)
    target_compile_definitions(aether_native_host PRIVATE AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
    target_link_libraries(aether_native_host PRIVATE aether_onscripter_runtime)
endif()
