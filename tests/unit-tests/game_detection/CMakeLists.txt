find_package(nlohmann_json CONFIG REQUIRED)
add_executable(aether-game-detection-test game_detection.cpp launch_router.cpp)
target_compile_definitions(aether-game-detection-test PRIVATE
    AETHER_DETECTION_PROBE_CASES="${CMAKE_SOURCE_DIR}/apps/godot_app/tests/game_detection_probes.json")
target_link_libraries(aether-game-detection-test PRIVATE
    aether_launch_router engine_api nlohmann_json::nlohmann_json Catch2::Catch2WithMain)
catch_discover_tests(aether-game-detection-test)
