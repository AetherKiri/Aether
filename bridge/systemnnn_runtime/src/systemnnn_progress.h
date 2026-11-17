#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace emberfall::scene { class GameSession; }

namespace aether::systemnnn {

struct ProgressOptions {
    // Empty uses GameSession::pc_system_save_format(). Otherwise one of
    // sysfile.sav, sysfile2.sav, sysfile3.sav or its t-prefixed trial name.
    std::string system_filename;
};

// Call with the provider game mutex held. Originals in root/sav are imported
// only when the corresponding private file is absent and are never modified
// when writable is nonempty. Damaged files are retained and reported.
// Names/replacements retain original game bytes. Java-compatible Emberfall
// sidecars retain progress not representable in older PC archive versions.
// Explicit limits: no invented storage for parameters/theme absent FLAG2; legacy
// textual read identities are preserved but unresolved; an unbound raw message
// cursor is preserved on disk because RuntimeContext has no raw restore setter.
// Transient mode/skip/preview and chart selection seeds are not global PC fields.
std::vector<std::string> load_progress(emberfall::scene::GameSession& game,
    const std::filesystem::path& root, const std::filesystem::path& writable,
    const ProgressOptions& options = {});
std::vector<std::string> save_progress(emberfall::scene::GameSession& game,
    const std::filesystem::path& root, const std::filesystem::path& writable,
    const ProgressOptions& options = {});

} // namespace aether::systemnnn
