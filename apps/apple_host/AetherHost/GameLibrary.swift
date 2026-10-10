import Foundation

struct LibraryGame: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let directory: String
    let sourcePath: String
    let importedAt: Date
    var lastPlayedAt: Date?
    var displayTitle: String {
        title.lowercased() == "data" ? URL(fileURLWithPath: sourcePath).deletingLastPathComponent().lastPathComponent : title
    }
}

// All imported content is copied; engine sidecars and saves stay in the copy.
// A staged copy becomes visible only after the manifest is atomically persisted.
struct GameLibrary {
    let root: URL
    private var gamesRoot: URL { root.appendingPathComponent("Games", isDirectory: true) }
    private var manifest: URL { root.appendingPathComponent("library.json") }

    enum Failure: LocalizedError {
        case unsupported, unsafeSource, symbolicLink, invalidManifest
        var errorDescription: String? {
            switch self {
            case .unsupported: return "No supported game entry was found. Select the folder containing startup.tjs, XP3 archives or an ONS script."
            case .unsafeSource: return "The selected folder contains the managed library. Select a game folder outside the library."
            case .symbolicLink: return "This folder contains symbolic links. Import a folder containing the actual game files."
            case .invalidManifest: return "The saved library index is invalid. It has been preserved."
            }
        }
    }

    func gameURL(_ game: LibraryGame) -> URL {
        gamesRoot.appendingPathComponent(game.directory, isDirectory: true)
    }

    func load() throws -> [LibraryGame] {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let games = try JSONDecoder().decode([LibraryGame].self, from: Data(contentsOf: manifest))
        // Directory names are generated UUIDs; never trust paths from disk.
        guard Set(games.map(\.id)).count == games.count,
              games.allSatisfy({ $0.directory == $0.id.uuidString }) else {
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

    private func isGame(_ folder: URL) throws -> Bool {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        let entries = Set(["startup.tjs", "startup.ks", "0.txt", "00.txt", "nscr_sec.dat", "nscript.___", "nscript.dat", "onscript.nt2", "onscript.nt3"])
        return try files.contains {
            let name = $0.lastPathComponent.lowercased()
            guard entries.contains(name) || name.hasSuffix(".xp3") else { return false }
            return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
    }

    func importDirectory(_ selected: URL, existing: [LibraryGame]) throws -> (games: [LibraryGame], imported: LibraryGame) {
        let fm = FileManager.default
        let source = selected.standardizedFileURL.resolvingSymlinksInPath()
        if let duplicate = existing.first(where: {
            $0.sourcePath == source.path || gameURL($0).standardizedFileURL.path == source.path
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
        let title = source.lastPathComponent.lowercased() == "data"
            ? source.deletingLastPathComponent().lastPathComponent : source.lastPathComponent
        let game = LibraryGame(id: id, title: title,
                               directory: id.uuidString, sourcePath: source.path,
                               importedAt: Date(), lastPlayedAt: nil)
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
