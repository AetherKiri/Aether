find_package(SDL2 CONFIG REQUIRED)
get_filename_component(system3_test_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
add_executable(aether_system3_native_contract "${CMAKE_CURRENT_LIST_DIR}/contract.cpp")
target_compile_features(aether_system3_native_contract PRIVATE cxx_std_17)
target_include_directories(aether_system3_native_contract PRIVATE
    "${system3_test_root}/abi/include" "${AETHERKIRI_SYSTEM3_DIR}/src")
target_link_libraries(aether_system3_native_contract PRIVATE aether_system3_runtime)
target_compile_definitions(aether_system3_native_contract PRIVATE
    SYSTEM3_EMBEDDED
    SYSTEM3_TEST_FONT="${AETHERKIRI_SYSTEM3_DIR}/resources/fonts/MTLc3m.ttf")
add_test(NAME system3-native-contract COMMAND aether_system3_native_contract)
set_tests_properties(system3-native-contract PROPERTIES TIMEOUT 30 ENVIRONMENT "SDL_AUDIODRIVER=dummy")

add_executable(aether_system3_encoding_contract "${CMAKE_CURRENT_LIST_DIR}/encoding.cpp")
target_compile_features(aether_system3_encoding_contract PRIVATE cxx_std_17)
target_include_directories(aether_system3_encoding_contract PRIVATE "${AETHERKIRI_SYSTEM3_DIR}/src")
target_compile_definitions(aether_system3_encoding_contract PRIVATE SYSTEM3_EMBEDDED)
target_link_libraries(aether_system3_encoding_contract PRIVATE aether_system3_core)
add_test(NAME system3-encoding-contract COMMAND aether_system3_encoding_contract)

# Exercise upstream's compiled arithmetic/branch/stack fixtures through the
# embedded lifecycle for all four interpreter variants, without game assets.
add_executable(aether_system3_scenario_contract "${CMAKE_CURRENT_LIST_DIR}/scenario.cpp")
target_compile_features(aether_system3_scenario_contract PRIVATE cxx_std_17)
target_include_directories(aether_system3_scenario_contract PRIVATE "${AETHERKIRI_SYSTEM3_DIR}/src")
target_link_libraries(aether_system3_scenario_contract PRIVATE aether_system3_core
    $<IF:$<TARGET_EXISTS:SDL2::SDL2>,SDL2::SDL2,SDL2::SDL2-static>)
foreach(variant system1 system2 system3 gakuen_king)
    if(variant STREQUAL "gakuen_king")
        set(game_id gakuen_king)
    else()
        set(game_id "${variant}_generic")
    endif()
    add_test(NAME "system3-scenario-${variant}" COMMAND aether_system3_scenario_contract
        "${AETHERKIRI_SYSTEM3_DIR}/test/scenario/${variant}" "${game_id}"
        "${AETHERKIRI_SYSTEM3_DIR}/resources/fonts/MTLc3m.ttf")
    set_tests_properties("system3-scenario-${variant}" PROPERTIES
        TIMEOUT 10 ENVIRONMENT "SDL_AUDIODRIVER=dummy"
        FAIL_REGULAR_EXPRESSION "\\[FAIL\\]"
        PASS_REGULAR_EXPRESSION "(^|[^0-9])0 tests failed")
endforeach()
