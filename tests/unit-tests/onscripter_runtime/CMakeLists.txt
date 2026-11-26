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
    if(TARGET aether_xsystem35_runtime)
        target_compile_definitions(aether-native-host-onscripter PRIVATE AETHER_TEST_XSYSTEM35)
    endif()
    if(TARGET aetherkiri_wa2_runtime)
        target_compile_definitions(aether-native-host-onscripter PRIVATE AETHER_TEST_WA2)
    endif()
    if(TARGET aether_minori_runtime)
        target_compile_definitions(aether-native-host-onscripter PRIVATE AETHER_TEST_MINORI)
    endif()
    if(TARGET aether_n2system_runtime)
        find_package(Python3 REQUIRED COMPONENTS Interpreter)
        # The provider loads the NativeAOT bundle beside the consumer binary.
        # Stage it from the existing manifest on both first build and rebuild.
        cmake_policy(PUSH)
        cmake_policy(SET CMP0112 NEW)
        add_custom_target(aether_native_host_test_n2system
            COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/tools/stage_n2system_runtime.py"
                --manifest "${CMAKE_BINARY_DIR}/n2system-runtime-publish.txt"
                --destination "$<TARGET_FILE_DIR:aether-native-host-onscripter>/n2system-runtime"
            DEPENDS aether_n2system_host
            VERBATIM)
        cmake_policy(POP)
        add_dependencies(aether-native-host-onscripter aether_native_host_test_n2system)
        target_compile_definitions(aether-native-host-onscripter PRIVATE
            AETHER_TEST_N2SYSTEM
            AETHER_TEST_N2SYSTEM_GAME="${CMAKE_SOURCE_DIR}/tests/fixtures/n2system_smoke")
    endif()
    target_link_libraries(aether-native-host-onscripter PRIVATE
        aether_native_host Catch2::Catch2WithMain)
    catch_discover_tests(aether-native-host-onscripter PROPERTIES
        ENVIRONMENT "SDL_AUDIODRIVER=dummy;ALSOFT_DRIVERS=null" TIMEOUT 30)
endif()
