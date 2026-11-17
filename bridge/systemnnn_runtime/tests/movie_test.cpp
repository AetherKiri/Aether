// Standalone integration test. Generate fixtures with run_movie_test.sh.
#include "systemnnn_movie.h"
#include "emberfall/render.hpp"
#include <algorithm>
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace fs = std::filesystem;
using aether::systemnnn::MoviePlayer;
using aether::systemnnn::resolve_movie;

static void require(bool value, const std::string& message) {
    if (!value) throw std::runtime_error(message);
}
static void save(const fs::path& path, const std::string& text) {
    std::ofstream out(path, std::ios::binary);
    out.write(text.data(), static_cast<std::streamsize>(text.size()));
    require(bool(out), "Cannot write fixture");
}
template<class Action> static void rejects(Action action) {
    bool rejected = false;
    try { action(); } catch (const std::exception&) { rejected = true; }
    require(rejected, "Expected rejection");
}
int main(int argc, char** argv) {
    try {
        require(argc == 2, "Usage: movie_test fixture_directory");
        const fs::path fixtures = argv[1];
        std::string error;
        MoviePlayer player;
        // Tiny/odd-width valid frames exercise SIMD stores, packed row copies,
        // end padding and destructor on repeated decoder lifetimes.
        for (const auto& dimensions : {std::pair<int, int>{2, 2}, {3, 3}, {22, 3}, {64, 2}}) {
            const auto name = "tiny-" + std::to_string(dimensions.first) + "x" + std::to_string(dimensions.second) + ".y4m";
            for (int attempt = 0; attempt < 32; ++attempt) {
                MoviePlayer tiny;
                require(tiny.open(fixtures / name, error), error);
                tiny.tick(0);
                require(tiny.frame() && tiny.frame()->width == static_cast<unsigned>(dimensions.first)
                    && tiny.frame()->height == static_cast<unsigned>(dimensions.second), "Tiny frame dimensions");
                require(tiny.frame()->rgb.size() == static_cast<std::size_t>(dimensions.first * dimensions.second * 3), "Tiny packed RGB shape");
                for (auto channel : tiny.frame()->rgb) require(channel >= 70 && channel <= 80, "Tiny YUV conversion color");
                tiny.tick(200);
                tiny.close();
            }
        }
        require(!player.active() && !player.ended() && !player.frame(), "Initial state");
        require(!player.open(fixtures / "missing.mp4", error) && !error.empty(), "Missing file error");
        require(!player.active() && !player.ended(), "Failed open is not EOF");
        require(!player.open("https://example.invalid/movie.mp4", error), "No network URLs");
        require(player.open(fixtures / "av.mp4", error), error);
        require(player.active() && !player.ended() && error.empty(), "Opened state");
        for (int i = 0; i < 20 && !player.frame(); ++i) player.tick(0);
        require(player.frame() && player.frame()->width == 96 && player.frame()->height == 64
            && player.frame()->rgb.size() == 96 * 64 * 3, "RGB8 frame");
        auto first = player.frame()->rgb;
        player.tick(40);
        require(player.frame()->rgb == first, "Video must wait for its PTS");
        player.pause(true);
        player.tick(3000);
        require(!player.ended() && player.frame()->rgb == first, "Pause freezes clock/video");
        std::vector<std::int16_t> pcm(882, 123);
        player.pull(pcm.data(), 441);
        require(std::all_of(pcm.begin(), pcm.end(), [](auto v) { return v == 0; }), "Paused PCM is silence");
        player.pause(false);
        player.pull(pcm.data(), 441);
        require(std::any_of(pcm.begin(), pcm.end(), [](auto v) { return v != 0; }), "44100 PCM produced");
        for (std::size_t i = 0; i < pcm.size(); i += 2) require(pcm[i] == pcm[i + 1], "Mono converted to stereo");
        player.tick(60);
        require(player.frame()->rgb != first, "Second video frame is paced");
        for (int i = 0; i < 200 && !player.ended() && player.error().empty(); ++i) {
            player.pull(pcm.data(), 441);
            player.tick(10);
        }
        require(player.error().empty() && player.ended(), "A/V must drain: " + player.error());
        require(player.active() && player.frame(), "Last frame remains available at EOF");
        player.close();
        require(!player.active() && !player.frame() && player.error().empty(), "Close releases state");
        require(player.open(fixtures / "silent.mkv", error), error);
        player.pull(pcm.data(), 441);
        require(std::all_of(pcm.begin(), pcm.end(), [](auto v) { return v == 0; }), "Silent movie PCM");
        for (int i = 0; i < 150 && !player.ended(); ++i) player.tick(10);
        require(player.error().empty() && player.ended(), "Silent movie completion");
        auto last = player.frame()->rgb;
        require(player.open(fixtures / "silent.mkv", error), error);
        player.tick(5000);
        for (int i = 0; i < 100 && !player.ended(); ++i) player.tick(0);
        require(player.ended() && player.frame()->rgb == last, "Clock jump preserves final video frame");
        require(player.open(fixtures / "av.mp4", error), error);
        for (int i = 0; i < 150 && !player.ended(); ++i) player.tick(10);
        require(player.ended() && player.error().empty(), "No audio sink still completes");
        require(player.open(fixtures / "delayed.mkv", error), error);
        std::vector<std::int16_t> delayed(4410 * 2);
        player.pull(delayed.data(), 4410);
        require(std::all_of(delayed.begin(), delayed.end(), [](auto v) { return v == 0; }), "Audio starts at its PTS");
        player.tick(300);
        player.pull(pcm.data(), 441);
        require(std::any_of(pcm.begin(), pcm.end(), [](auto v) { return v != 0; }), "Delayed audio resumes at 300ms");
        player.close();

        if (fs::exists(fixtures / "reference.pcm")) {
            std::ifstream reference_file(fixtures / "reference.pcm", std::ios::binary);
            std::vector<std::int16_t> reference(static_cast<std::size_t>(fs::file_size(fixtures / "reference.pcm")) / 2);
            reference_file.read(reinterpret_cast<char*>(reference.data()), static_cast<std::streamsize>(reference.size() * 2));
            require(player.open(fixtures / "av.mp4", error), error);
            std::vector<std::int16_t> actual;
            for (int i = 0; i < 150 && !player.ended(); ++i) {
                player.pull(pcm.data(), 441);
                actual.insert(actual.end(), pcm.begin(), pcm.end());
                player.tick(10);
            }
            require(actual.size() >= reference.size(), "PCM tail must be drained completely");
            require(std::equal(reference.begin(), reference.end(), actual.begin()), "PCM exactly matches FFmpeg resampling including tail");
        }
        if (fs::exists(fixtures / "corrupt.mkv")) {
            const bool opened = player.open(fixtures / "corrupt.mkv", error);
            if (opened) {
                for (int i = 0; i < 200 && player.error().empty() && !player.ended(); ++i) player.tick(10);
                require(!player.error().empty() && player.active() && !player.ended(), "Decode failure freezes active playback rather than becoming EOF");
            } else require(!error.empty() && !player.ended(), "Open corruption error");
        }
        player.close();

        const auto root = fixtures / ("resolver-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
        fs::create_directories(root / "SpT");
        fs::create_directories(root / "MoViE" / "Sub");
        save(root / "MoViE" / "Sub" / "INTRO.MP4", "fixture");
        save(root / "SpT" / "MovieList.XTX", "sub\\intro.wmv,Title\r\n");
        require(resolve_movie(root, 1).filename() == "INTRO.MP4", "Case-insensitive extension fallback");
        rejects([&] { resolve_movie(root, 0); });
        rejects([&] { resolve_movie(root, 2); });
        save(root / "SpT" / "MovieList.XTX", "../escape,Title\n");
        rejects([&] { resolve_movie(root, 1); });
        save(root / "SpT" / "MovieList.XTX", "https://example.invalid/a,Title\n");
        rejects([&] { resolve_movie(root, 1); });
        save(root / "SpT" / "MovieList.XTX", "intro\n");
        rejects([&] { resolve_movie(root, 1); });
        const auto japanese = fs::u8path(u8"ソラ.Mp4"); // CP932 ソ has a backslash trail byte.
        save(root / "MoViE" / japanese, "fixture");
        save(root / "SpT" / "MovieList.XTX", std::string("\x83\x5c\x83\x89", 4) + ",Title\n");
        require(resolve_movie(root, 1).filename() == japanese, "Raw CP932 lookup preserves backslash trail bytes");
#ifndef _WIN32
        const fs::path raw_name(std::string("\x83\x5c\x83\x89", 4) + "raw.AVI");
        save(root / "MoViE" / raw_name, "fixture");
        save(root / "SpT" / "MovieList.XTX", std::string("\x83\x5c\x83\x89", 4) + "raw,Title\n");
        require(resolve_movie(root, 1).filename() == raw_name, "Raw CP932 POSIX filename");
        save(fixtures / "outside.mp4", "fixture");
        fs::create_symlink(fs::absolute(fixtures / "outside.mp4"), root / "MoViE" / "escape.mp4");
        save(root / "SpT" / "MovieList.XTX", "escape,Title\n");
        rejects([&] { resolve_movie(root, 1); });
#endif
        save(root / "SpT" / "MovieList.XTX", std::string("\xef\xbb\xbf") + u8"ソラ,Title\n");
        require(resolve_movie(root, 1).filename() == japanese, "UTF-8 BOM movie list");
        save(root / "SpT" / "MovieList.XTX", std::string("intro\0,Title", 12));
        rejects([&] { resolve_movie(root, 1); });
        fs::remove(root / "SpT" / "MovieList.XTX");
        std::string encrypted = "sub/intro,Title\n";
        for (auto& c : encrypted) c = static_cast<char>(static_cast<unsigned char>(c) ^ 0xffU);
        save(root / "SpT" / "MovieList.FXF", encrypted);
        require(resolve_movie(root, 1).filename() == "INTRO.MP4", "Encrypted movie list fallback");
        std::cout << "Movie playback/resolver integration tests passed\n";
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
