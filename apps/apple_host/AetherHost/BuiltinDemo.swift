import Foundation

/// Godot's bundled first-run demo, mirrored from `scripts/builtin_demo.gd`.
///
/// The packed demo is copied into the library on first run; removal is
/// remembered in a small state file so it is not silently reinstalled. The
/// installed directory is referenced like an external game, so the detail page
/// and engine launch path stay identical to a user-imported game.
struct BuiltinDemo {
    static let id = "aetherkiri-kag3-demo"
    static let version = 4
    static let title = "Aether Demo"
    static let resourceName = "data"
    static let resourceExtension = "xp3"
    static let directoryName = "builtin-aetherkiri-demo"

    let root: URL
    let sourceURL: URL?

    init(root: URL, sourceURL: URL? = BuiltinDemo.bundledSource()) {
        self.root = root
        self.sourceURL = sourceURL
    }

    static func bundledSource(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: resourceExtension)
    }

    var installDirectory: URL {
        root.appendingPathComponent("builtin_games/aetherkiri-demo", isDirectory: true)
    }
    var installURL: URL { installDirectory.appendingPathComponent("data.xp3") }
    var stateURL: URL { root.appendingPathComponent("aetherkiri_builtin_demo.cfg") }

    private struct State: Codable {
        var removed = false
        var installedVersion = 0
        var installedSize = -1
    }

    func isRemoved() -> Bool { loadState().removed }

    func isGame(_ game: LibraryGame) -> Bool { game.builtinId == Self.id }
    func isPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized == installDirectory.standardizedFileURL.path
            || normalized == installURL.standardizedFileURL.path
    }

    /// Returns the install directory when the demo should be present, or nil
    /// when it was removed or the bundled resource is unavailable.
    func ensureInstalled() -> URL? {
        var state = loadState()
        if state.removed {
            try? FileManager.default.removeItem(at: installDirectory)
            return nil
        }
        guard let sourceURL else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? -1
        let current = FileManager.default.fileExists(atPath: installURL.path)
            && state.installedVersion == Self.version
            && (size < 0 || state.installedSize == size)
        if !current {
            do {
                try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: installURL.path) {
                    try FileManager.default.removeItem(at: installURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: installURL)
            } catch {
                return nil
            }
        }
        state.removed = false
        state.installedVersion = Self.version
        state.installedSize = size
        _ = saveState(state)
        return installDirectory
    }

    /// Marks the demo removed (so it is not restored) and deletes the install.
    @discardableResult
    func remove() -> Bool {
        var state = loadState()
        state.removed = true
        state.installedVersion = Self.version
        guard saveState(state) else { return false }
        try? FileManager.default.removeItem(at: installDirectory)
        return true
    }

    /// Ensures the demo entry exists exactly once, preserving the play time,
    /// cover and title of an existing entry the way Godot does.
    func reconciled(_ games: [LibraryGame]) -> [LibraryGame] {
        let existing = games.first { isGame($0) }
        let others = games.filter { !isGame($0) }
        guard let directory = ensureInstalled() else { return others }
        if let existing {
            let demo = LibraryGame(id: existing.id, title: existing.title,
                                   directory: existing.directory, sourcePath: directory.path,
                                   importedAt: existing.importedAt, lastPlayedAt: existing.lastPlayedAt,
                                   playDurationSeconds: existing.playDurationSeconds,
                                   externalPath: directory.path, coverPath: existing.coverPath,
                                   coverSuppressed: existing.coverSuppressed,
                                   builtinId: Self.id, builtinVersion: Self.version)
            return others + [demo]
        }
        let demo = LibraryGame(id: UUID(), title: Self.title, directory: Self.directoryName,
                               sourcePath: directory.path, importedAt: Date(),
                               externalPath: directory.path,
                               builtinId: Self.id, builtinVersion: Self.version)
        return others + [demo]
    }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private func saveState(_ state: State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: stateURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
