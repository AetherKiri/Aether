#include "embedded.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

int main(int argc, char **argv) {
    if(argc != 4)
        return 2;
    namespace fs = std::filesystem;
    const auto prefix = fs::temp_directory_path() /
        ("aether-system3-scenario-" + std::string(argv[2]) + "-" +
         std::to_string(
             std::chrono::steady_clock::now().time_since_epoch().count()));
    // Parallel processes can observe the same clock tick. Reserve the fixture
    // directory atomically so they cannot overwrite each other's game files.
    fs::path root;
    for(unsigned attempt = 0;; ++attempt) {
        root = prefix.string() + "-" + std::to_string(attempt);
        if(fs::create_directory(root))
            break;
    }
    fs::create_directories(root / "game");
    fs::create_directories(root / "saves");
    std::cerr << "Scenario fixture: " << root << '\n';
    for(const auto &file : fs::directory_iterator(argv[1]))
        if(file.path().extension() == ".DAT")
            fs::copy_file(file.path(), root / "game" / file.path().filename());
    std::ofstream(root / "game/system3.ini")
        << "[config]\ngame=" << argv[2] << "\nencoding=utf8\n";
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    system3_host host{};
    host.user = &deadline;
    host.checkpoint = [](void *p) {
        return int(std::chrono::steady_clock::now() >
                   *static_cast<std::chrono::steady_clock::time_point *>(p));
    };
    host.log = [](void *, int, const char *text) { std::cerr << text << '\n'; };
    const int result =
        system3_host_run(&host, (root / "game").c_str(),
                         (root / "saves").c_str(), argv[3], "auto", true);
    fs::remove_all(root);
    return result;
}
