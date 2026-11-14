# Keep the JSON settings loader usable by standalone providers without Lua hooks.
find_package(nlohmann_json CONFIG REQUIRED)
add_library(aether_game_text_settings STATIC ../src/AetherGameTextSettings.cpp)
target_compile_features(aether_game_text_settings PUBLIC cxx_std_17)
target_include_directories(aether_game_text_settings PUBLIC ../include)
target_link_libraries(aether_game_text_settings PRIVATE nlohmann_json::nlohmann_json)
set_target_properties(aether_game_text_settings PROPERTIES POSITION_INDEPENDENT_CODE ON)
