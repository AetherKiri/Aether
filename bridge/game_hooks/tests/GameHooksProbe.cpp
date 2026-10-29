#include "AetherGameHooks.h"
#include <iostream>

int main(int argc, char** argv) {
    if(argc != 3) { std::cerr << "usage: aether_lua_probe GAME_DIRECTORY ENGINE\n"; return 2; }
    try {
        aether::hooks::GameHooks hooks;
        hooks.Load(std::filesystem::u8path(argv[1]), argv[2]);
        size_t bytes = 0;
        for(const auto& entry : hooks.Files()) bytes += entry.second.size();
        std::cout << "active=" << hooks.Active() << " engine=" << argv[2]
                  << " encoding=" << hooks.Encoding() << " files=" << hooks.Files().size()
                  << " bytes=" << bytes << '\n';
        for(const auto& message : hooks.Messages()) std::cout << message << '\n';
        return hooks.Active() ? 0 : 1;
    } catch(const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
