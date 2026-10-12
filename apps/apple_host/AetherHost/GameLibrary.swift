import Foundation

struct LibraryGame: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    let directory: String
    let sourcePath: String
    let importedAt: Date
    var lastPlayedAt: Date?
    // Running game time, accumulated per session. Missing in legacy indexes.
    var playDurationSeconds: Int = 0
    // Missing in legacy indexes: nil means a managed copy.
    var externalPath: String? = nil
    // Covers are stored as game://relative/path when they live inside the
    // game root, otherwise as an absolute path. Legacy indexes decode nil.
    var coverPath: String? = nil
    // A manual clear must survive the next automatic cover scan.
    var coverSuppressed: Bool = false
    var displayTitle: String { title }
    var isExternal: Bool { externalPath != nil }
}

extension LibraryGame {
    enum CodingKeys: String, CodingKey {
        case id, title, directory, sourcePath, importedAt, lastPlayedAt, playDurationSeconds,
             externalPath, coverPath, coverSuppressed
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        directory = try values.decode(String.self, forKey: .directory)
        sourcePath = try values.decode(String.self, forKey: .sourcePath)
        importedAt = try values.decode(Date.self, forKey: .importedAt)
        lastPlayedAt = try values.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        playDurationSeconds = max(0, try values.decodeIfPresent(Int.self, forKey: .playDurationSeconds) ?? 0)
        externalPath = try values.decodeIfPresent(String.self, forKey: .externalPath)
        coverPath = try values.decodeIfPresent(String.self, forKey: .coverPath)
        coverSuppressed = try values.decodeIfPresent(Bool.self, forKey: .coverSuppressed) ?? false
    }
}

// Default imports are copied. Explicit external references use the source directly.
// A staged copy becomes visible only after the manifest is atomically persisted.
struct GameLibrary {
    let root: URL
    private var gamesRoot: URL { root.appendingPathComponent("Games", isDirectory: true) }
    private var manifest: URL { root.appendingPathComponent("library.json") }

    enum Failure: LocalizedError {
        case unsupported, unsafeSource, symbolicLink, invalidManifest, invalidTitle
        var errorDescription: String? {
            switch self {
            case .invalidTitle: return "Enter a title of 1–200 characters without control characters."
            case .unsupported: return "No supported game entry was found. Select the folder containing startup.tjs, XP3 archives an ONS script, or supported Minori PAZ files."
            case .unsafeSource: return "The selected folder contains the managed library. Select a game folder outside the library."
            case .symbolicLink: return "This folder contains symbolic links. Import a folder containing the actual game files."
            case .invalidManifest: return "The saved library index is invalid. It has been preserved."
            }
        }
    }

    func gameURL(_ game: LibraryGame) -> URL {
        if let path = game.externalPath { return URL(fileURLWithPath: path, isDirectory: true) }
        return gamesRoot.appendingPathComponent(game.directory, isDirectory: true)
    }

    func coverURL(_ game: LibraryGame) -> URL? {
        guard let stored = game.coverPath, !stored.isEmpty else { return nil }
        if stored.hasPrefix("game://") {
            let relative = String(stored.dropFirst("game://".count))
            guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0") else { return nil }
            let root = gameURL(game).standardizedFileURL.resolvingSymlinksInPath()
            let candidate = root.appendingPathComponent(relative, isDirectory: false)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }
            return candidate
        }
        guard stored.hasPrefix("/"), !stored.contains("\0") else { return nil }
        return URL(fileURLWithPath: stored, isDirectory: false)
    }

    func discoverDefaultCoverPath(for game: LibraryGame) -> String? {
        let root = gameURL(game)
        let directories = [root, root.appendingPathComponent("data", isDirectory: true),
                           root.appendingPathComponent("assets", isDirectory: true),
                           root.appendingPathComponent("image", isDirectory: true),
                           root.appendingPathComponent("images", isDirectory: true)]
        let stems = ["cover", "cover_image", "coverimage", "封面", "封面图", "封面圖片", "background", "bg"]
        let extensions = Set(["png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff"])
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                            includingPropertiesForKeys: [.isRegularFileKey],
                                                                            options: [.skipsHiddenFiles]) else { continue }
            let sorted = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for file in sorted {
                guard file.pathExtension.isEmpty == false,
                      extensions.contains(file.pathExtension.lowercased()),
                      stems.contains(file.deletingPathExtension().lastPathComponent.lowercased()) ||
                      stems.contains(file.deletingPathExtension().lastPathComponent) else { continue }
                let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(resolved.path.dropFirst(rootPath.count + 1))
                return "game://" + relative
            }
        }
        return nil
    }

    func backfillDefaultCovers(_ existing: [LibraryGame]) throws -> [LibraryGame] {
        var updated = existing
        var changed = false
        for index in updated.indices where updated[index].coverPath == nil && !updated[index].coverSuppressed {
            if let discovered = discoverDefaultCoverPath(for: updated[index]) {
                updated[index].coverPath = discovered
                changed = true
            }
        }
        if changed { try save(updated) }
        return updated
    }

    func setCover(_ id: UUID, url: URL, existing: [LibraryGame]) throws -> [LibraryGame] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.invalidManifest }
        var updated = existing
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw Failure.invalidManifest }
        let root = gameURL(updated[index]).standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if resolved.path.hasPrefix(root + "/") {
            updated[index].coverPath = "game://" + String(resolved.path.dropFirst(root.count + 1))
        } else {
            updated[index].coverPath = resolved.path
        }
        updated[index].coverSuppressed = false
        try save(updated)
        return updated
    }

    func clearCover(_ id: UUID, existing: [LibraryGame]) throws -> [LibraryGame] {
        var updated = existing
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw Failure.invalidManifest }
        updated[index].coverPath = nil
        updated[index].coverSuppressed = true
        try save(updated)
        return updated
    }

    /// Adds running time to one entry. Mirrors Godot `_add_play_duration`:
    /// non-positive contributions are ignored and a single session can add at
    /// most one day, so a suspended clock cannot inflate the statistics.
    func addPlayDuration(_ seconds: Int, to id: UUID, existing: [LibraryGame]) throws -> [LibraryGame] {
        guard seconds > 0 else { return existing }
        var updated = existing
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw Failure.invalidManifest }
        updated[index].playDurationSeconds += min(seconds, PlayStats.maximumSessionSeconds)
        try save(updated)
        return updated
    }

    func load() throws -> [LibraryGame] {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let games = try JSONDecoder().decode([LibraryGame].self, from: Data(contentsOf: manifest))
        // Directory names are generated UUIDs; never trust paths from disk.
        guard Set(games.map(\.id)).count == games.count,
              games.allSatisfy({ $0.directory == $0.id.uuidString && ($0.externalPath.map { $0.hasPrefix("/") && !$0.contains("\0") } ?? true) }) else {
            throw Failure.invalidManifest
        }
        return games
    }

    func save(_ games: [LibraryGame]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(games).write(to: manifest, options: .atomic)
    }

    func rename(_ id: UUID, title: String, existing: [LibraryGame]) throws -> [LibraryGame] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidTitle }
        var updated = existing
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw Failure.invalidManifest }
        updated[index].title = title
        try save(updated)
        return updated
    }

    // Remove only the index entry. Both managed saves and external originals remain.
    func remove(_ id: UUID, existing: [LibraryGame]) throws -> [LibraryGame] {
        guard existing.contains(where: { $0.id == id }) else { throw Failure.invalidManifest }
        let updated = existing.filter { $0.id != id }
        try save(updated)
        return updated
    }

    func isGame(_ folder: URL) throws -> Bool {
        // Keep the read error visible for unreadable folders, then use the same
        // marker detection as the detail page so import and display agree.
        _ = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        return GameRuntimeDetector.inspect(root: folder).isRecognized
    }

    func importArchive(_ selected: URL, existing: [LibraryGame]) throws -> (games: [LibraryGame], imported: LibraryGame) {
        let source = selected.standardizedFileURL.resolvingSymlinksInPath()
        guard source.pathExtension.lowercased() == "zip" else { throw GameArchive.Failure.invalid }
        if let duplicate = existing.first(where: { !$0.isExternal && $0.sourcePath == source.path }),
           FileManager.default.fileExists(atPath: gameURL(duplicate).path) { return (existing, duplicate) }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("aether-zip-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try GameArchive.extract(source, to: stage)
        var candidates: [URL] = []
        func discover(_ folder: URL, depth: Int) throws {
            if try isGame(folder) { candidates.append(folder); return }
            guard depth < 8 else { return }
            for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
                if child.lastPathComponent == "__MACOSX" { continue }
                if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try discover(child, depth: depth + 1) }
            }
        }
        try discover(stage, depth: 0)
        guard candidates.count == 1 else {
            if candidates.isEmpty { throw Failure.unsupported }
            throw GameArchive.Failure.ambiguous
        }
        return try importDirectory(candidates[0], existing: existing, sourceIdentity: source,
                                   archiveTitle: source.deletingPathExtension().lastPathComponent)
    }

    func importDirectory(_ selected: URL, existing: [LibraryGame], external: Bool = false, sourceIdentity: URL? = nil, archiveTitle: String? = nil) throws -> (games: [LibraryGame], imported: LibraryGame) {
        let fm = FileManager.default
        let source = selected.standardizedFileURL.resolvingSymlinksInPath()
        if let duplicate = existing.first(where: {
            $0.isExternal == external && ($0.sourcePath == source.path || gameURL($0).standardizedFileURL.resolvingSymlinksInPath().path == source.path)
        }), fm.fileExists(atPath: gameURL(duplicate).path) {
            return (existing, duplicate)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard canonicalRoot != source.path, !canonicalRoot.hasPrefix(source.path.hasSuffix("/") ? source.path : source.path + "/") else {
            throw Failure.unsafeSource
        }
        var entry = source
        if try !isGame(entry) {
            entry = source.appendingPathComponent("data", isDirectory: true)
            guard fm.fileExists(atPath: entry.path), try isGame(entry) else { throw Failure.unsupported }
        }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard try entry.resourceValues(forKeys: Set(keys)).isSymbolicLink != true else { throw Failure.symbolicLink }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: entry, includingPropertiesForKeys: keys,
                                             errorHandler: { _, error in enumerationError = error; return false }) else {
            throw Failure.unsupported
        }
        for case let item as URL in enumerator {
            if try item.resourceValues(forKeys: Set(keys)).isSymbolicLink == true { throw Failure.symbolicLink }
        }
        if let enumerationError { throw enumerationError }
        try fm.createDirectory(at: gamesRoot, withIntermediateDirectories: true)
        let id = UUID()
        let title = archiveTitle ?? (source.lastPathComponent.lowercased() == "data"
            ? source.deletingLastPathComponent().lastPathComponent : source.lastPathComponent)
        var game = LibraryGame(id: id, title: title,
                               directory: id.uuidString, sourcePath: (sourceIdentity ?? source).path,
                               importedAt: Date(), lastPlayedAt: nil)
        if external {
            game.externalPath = entry.path
            let updated = existing + [game]
            try save(updated)
            return (updated, game)
        }
        let stage = gamesRoot.appendingPathComponent(".import-" + id.uuidString)
        let destination = gameURL(game)
        var moved = false
        do {
            try fm.copyItem(at: entry, to: stage)
            try fm.moveItem(at: stage, to: destination)
            moved = true
            let updated = existing + [game]
            try save(updated)
            return (updated, game)
        } catch {
            // These paths are generated for this transaction, never user input.
            try? fm.removeItem(at: moved ? destination : stage)
            throw error
        }
    }
}
