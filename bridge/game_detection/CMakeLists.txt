find_package(nlohmann_json CONFIG REQUIRED)

add_library(aether_game_detection STATIC src/game_detection.cpp src/disk_files.cpp)
target_compile_features(aether_game_detection PUBLIC cxx_std_17)
target_include_directories(aether_game_detection PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(aether_game_detection PRIVATE engine_api nlohmann_json::nlohmann_json)
