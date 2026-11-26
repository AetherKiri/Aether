cmake_minimum_required(VERSION 3.16)
project(TestOnscripterRuntime LANGUAGES CXX)

add_executable(onscripter-runtime-presentation presentation.cpp)
target_compile_features(onscripter-runtime-presentation PRIVATE cxx_std_17)
target_include_directories(onscripter-runtime-presentation PRIVATE
    ${CMAKE_SOURCE_DIR}/bridge/onscripter_runtime/include
)
target_link_libraries(onscripter-runtime-presentation
    PRIVATE Catch2::Catch2WithMain)

catch_discover_tests(onscripter-runtime-presentation)

add_executable(onscripter-runtime-save-storage
    save_storage.cpp
    ${CMAKE_SOURCE_DIR}/bridge/onscripter_runtime/src/onscripter_save_storage.cpp
)
target_compile_features(onscripter-runtime-save-storage PRIVATE cxx_std_17)
target_include_directories(onscripter-runtime-save-storage PRIVATE
    ${CMAKE_SOURCE_DIR}/bridge/onscripter_runtime/include
)
target_link_libraries(onscripter-runtime-save-storage
    PRIVATE Catch2::Catch2WithMain)

catch_discover_tests(onscripter-runtime-save-storage)

add_executable(onscripter-runtime-provider provider.cpp encoding.cpp)
target_compile_features(onscripter-runtime-provider PRIVATE cxx_std_17)
target_include_directories(onscripter-runtime-provider PRIVATE
    ${AETHERKIRI_ONSCRIPTERYURI_DIR}/src/onsyuri
    ${CMAKE_SOURCE_DIR}/bridge/onscripter_runtime/src
    ${CMAKE_SOURCE_DIR}/abi/include
    ${CMAKE_SOURCE_DIR}/bridge/onscripter_runtime/include
)
target_link_libraries(onscripter-runtime-provider PRIVATE
    Catch2::Catch2WithMain
    aether_onscripter_runtime
    engine_api
)

catch_discover_tests(onscripter-runtime-provider)

if(TARGET aether_native_host)
    add_executable(aether-native-host-onscripter native_host.cpp)
    target_compile_definitions(aether-native-host-onscripter PRIVATE
        AETHER_TEST_RUNTIME_FONT="${CMAKE_SOURCE_DIR}/apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf")
    if(TARGET aether_system3_runtime)
        target_compile_definitions(aether-native-host-onscripter PRIVATE AETHER_TEST_SYSTEM3)
    endif()
    target_link_libraries(aether-native-host-onscripter PRIVATE
        aether_native_host Catch2::Catch2WithMain)
    catch_discover_tests(aether-native-host-onscripter PROPERTIES
        ENVIRONMENT "SDL_AUDIODRIVER=dummy" TIMEOUT 30)
endif()
