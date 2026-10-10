import Foundation

struct LibraryGame: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    let directory: String
    let sourcePath: String
    let importedAt: Date
    var lastPlayedAt: Date?
    // Missing in legacy indexes: nil means a managed copy.
    var externalPath: String? = nil
    var displayTitle: String { title }
    var isExternal: Bool { externalPath != nil }
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
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        let entries = Set(["startup.tjs", "startup.ks", "0.txt", "00.txt", "nscr_sec.dat", "nscript.___", "nscript.dat", "onscript.nt2", "onscript.nt3"])
        let regularNames = Set(try files.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            .map { $0.lastPathComponent.lowercased() })
        // These markers match the public Minori provider's supported profiles.
        let minoriExecutables: Set<String> = ["sppl1.exe", "sppl1_cn.exe", "trinoline.exe", "trinoline_chs.exe"]
        if regularNames.isSuperset(of: ["scr.paz", "sys.paz"]), !regularNames.isDisjoint(with: minoriExecutables) { return true }
        return try files.contains {
            let name = $0.lastPathComponent.lowercased()
            guard entries.contains(name) || name.hasSuffix(".xp3") else { return false }
            return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
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
