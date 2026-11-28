#pragma once
#include <string>

namespace aether::xsystem {
// Runs on a worker thread. Results are JSON: {ok, error, detail, mods}.
// Only files recorded in the game-local manifest may be restored or removed.
std::string mod_operation(const std::string &game_root,
                          const std::string &operation,
                          const std::string &argument = {});
}
