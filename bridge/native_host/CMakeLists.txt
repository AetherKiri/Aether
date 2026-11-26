add_library(aether_launch_router STATIC src/launch_router.cpp)
target_compile_features(aether_launch_router PUBLIC cxx_std_17)
target_include_directories(aether_launch_router PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(aether_launch_router PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../game_detection/src")
target_link_libraries(aether_launch_router PUBLIC aether_game_detection PRIVATE engine_api)

if(NOT BUILD_NATIVE_HOST AND NOT AETHERKIRI_ONS_NATIVE_HOST_FOR_GODOT)
    return()
endif()

add_library(aether_native_host STATIC src/runtime_session.cpp)
target_compile_features(aether_native_host PUBLIC cxx_std_17)
target_include_directories(aether_native_host PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(aether_native_host PUBLIC engine_api aether_launch_router)

if(TARGET aether_onscripter_runtime)
    target_compile_definitions(aether_native_host PRIVATE AETHER_NATIVE_HOST_WITH_ONSCRIPTER)
    target_link_libraries(aether_native_host PRIVATE aether_onscripter_runtime)
endif()
