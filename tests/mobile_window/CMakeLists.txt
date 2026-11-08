add_executable(aether_mobile_playback_contract playback.cpp)
target_compile_features(aether_mobile_playback_contract PRIVATE cxx_std_17)
target_include_directories(aether_mobile_playback_contract PRIVATE
    "${CMAKE_SOURCE_DIR}/abi/include"
    "${CMAKE_SOURCE_DIR}/bridge/godot_extension/src")
add_test(NAME mobile-playback-contract COMMAND aether_mobile_playback_contract)

find_package(fmt CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)
find_package(Threads REQUIRED)
add_executable(aether_mobile_dispatch_contract dispatch.cpp
    "${CMAKE_SOURCE_DIR}/abi/src/engine_api_stub.cpp"
    "${CMAKE_SOURCE_DIR}/abi/src/engine_api_dispatch.cpp"
    "${CMAKE_SOURCE_DIR}/abi/src/engine_api_crash_capture.cpp"
    "${CMAKE_SOURCE_DIR}/abi/src/engine_runtime_provider.cpp"
    "${CMAKE_SOURCE_DIR}/abi/src/TextTransform.cpp")
target_compile_features(aether_mobile_dispatch_contract PRIVATE cxx_std_17)
target_include_directories(aether_mobile_dispatch_contract PRIVATE
    "${CMAKE_SOURCE_DIR}/abi/include" "${CMAKE_SOURCE_DIR}/abi/src")
target_link_libraries(aether_mobile_dispatch_contract PRIVATE fmt::fmt spdlog::spdlog Threads::Threads)
if(WIN32)
    target_link_libraries(aether_mobile_dispatch_contract PRIVATE dbghelp)
endif()
add_test(NAME mobile-dispatch-contract COMMAND aether_mobile_dispatch_contract)
