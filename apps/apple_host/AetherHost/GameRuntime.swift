import Foundation

/// Runtime families the shared engine can drive, mirroring Godot's
/// `GameMetadata` constants plus the Minori profile markers used by the library.
enum GameRuntime: String, CaseIterable, Identifiable {
    case kirikiri, onscripter, siglus, minori, rfvp, unknown

    var id: String { rawValue }
    var textKey: String { "runtime_" + rawValue }

    /// Provider id used with `engine_probe_runtime_provider` (nil = legacy path).
    var providerId: String? {
        switch self {
        case .kirikiri, .onscripter, .siglus, .minori: return rawValue
        case .rfvp: return "rfvp"
        case .unknown: return nil
        }
    }
}

/// Result of inspecting a game folder. `entryFile` is informational: the shared
/// engine ignores `startup_script` on `engine_open_game`, so the detail page
/// reports what was detected instead of offering an override that does nothing.
struct GameRuntimeInspection: Equatable {
    let runtime: GameRuntime
    let entryFile: String
    let signals: [String]

    var isRecognized: Bool { runtime != .unknown }
}

/// Mirrors the Godot `GameMetadata.inspect()` marker checks for the runtimes
/// this host links (kirikiri/onscripter/siglus/minori) and detects validated
/// RFVP `.hcb` bytecode so such a folder can at least be reported.
enum GameRuntimeDetector {
    static let kirikiriStartups = ["startup.tjs", "startup.ks"]
    static let onscripterEntries: Set<String> = ["0.txt", "00.txt", "nscr_sec.dat", "nscript.___", "nscript.dat"]
    static let siglusMarkers = ["gameexe.ini", "gameexe.dat", "scene.pck"]
    static let minoriArchives: Set<String> = ["scr.paz", "sys.paz"]
    static let minoriExecutables: Set<String> = ["sppl1.exe", "sppl1_cn.exe", "trinoline.exe", "trinoline_chs.exe"]
    /// Godot's `.hcb` header sanity range.
    static let hcbRange = 17...(64 * 1024 * 1024)

    static func inspect(root: URL, fileManager: FileManager = .default) -> GameRuntimeInspection {
        guard let files = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return GameRuntimeInspection(runtime: .unknown, entryFile: "", signals: ["unreadable"])
        }
        let regular = files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let names = Set(regular.map { $0.lastPathComponent.lowercased() })

        // RFVP: validated HCB bytecode wins (Godot's first check).
        if let hcb = regular.filter({ $0.pathExtension.lowercased() == "hcb" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first(where: { isRFVPBytecode($0) }) {
            return GameRuntimeInspection(runtime: .rfvp, entryFile: hcb.lastPathComponent, signals: ["fvp-hcb"])
        }
        // ONScripter markers (0.txt/00.txt/nscr_sec.dat/nscript.*/onscript.nt*).
        if !names.isDisjoint(with: onscripterEntries) || names.contains(where: { $0.hasPrefix("onscript.nt") }) {
            let entry = onscripterEntries.sorted().first(where: { names.contains($0) })
                ?? names.filter { $0.hasPrefix("onscript.nt") }.sorted().first ?? ""
            return GameRuntimeInspection(runtime: .onscripter, entryFile: entry, signals: ["onscript-marker"])
        }
        // Minori profile markers (scr.paz + sys.paz + known executable).
        if names.isSuperset(of: minoriArchives), !names.isDisjoint(with: minoriExecutables) {
            return GameRuntimeInspection(runtime: .minori, entryFile: "scr.paz", signals: ["minori-paz"])
        }
        // Siglus markers (gameexe.ini/gameexe.dat/scene.pck).
        if let marker = siglusMarkers.first(where: { names.contains($0) }) {
            return GameRuntimeInspection(runtime: .siglus, entryFile: marker, signals: ["siglus-marker"])
        }
        // KiriKiri: XP3 auto-mount, else an explicit startup script.
        if let xp3 = regular.filter({ $0.pathExtension.lowercased() == "xp3" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            return GameRuntimeInspection(runtime: .kirikiri, entryFile: xp3.lastPathComponent, signals: ["kirikiri-xp3"])
        }
        if let startup = kirikiriStartups.first(where: { names.contains($0) }) {
            return GameRuntimeInspection(runtime: .kirikiri, entryFile: startup, signals: ["kirikiri-startup"])
        }
        return GameRuntimeInspection(runtime: .unknown, entryFile: "", signals: ["unrecognized"])
    }

    /// Light port of Godot `_hcb_launch_file()`: little-endian descriptor and
    /// start offsets must be inside the file with room for the header fields.
    static func isRFVPBytecode(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), (try? handle.seekToEnd()) != nil else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), hcbRange.contains(Int(size)) else { return false }
        guard (try? handle.seek(toOffset: 0)) != nil,
              let descriptorData = try? handle.read(upToCount: 4), descriptorData.count == 4,
              let startData: Data = {
                  let descriptor = descriptorData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                  guard (try? handle.seek(toOffset: UInt64(descriptor))) != nil else { return nil }
                  return try? handle.read(upToCount: 4)
              }(), startData.count == 4 else { return false }
        let descriptor = descriptorData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let start = startData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return descriptor >= 4 && UInt64(descriptor) <= size - 13 && start >= 4 && start < descriptor
    }
}
