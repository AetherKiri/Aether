import Foundation

@main
struct GameLibraryTests {
    static func main() throws {
        func check(_ condition: Bool) { precondition(condition) }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("aether-library-tests-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let source = temp.appendingPathComponent("游戏 示例")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("script".utf8).write(to: source.appendingPathComponent("startup.tjs"))
        let repository = GameLibrary(root: temp.appendingPathComponent("library"))
        let imported = try repository.importDirectory(source, existing: [])
        check(imported.games.count == 1 && imported.imported.title == "游戏 示例")
        check(try repository.load() == imported.games)
        let copy = repository.gameURL(imported.imported)
        try Data("save".utf8).write(to: copy.appendingPathComponent("save1.sav"))
        check(!fm.fileExists(atPath: source.appendingPathComponent("save1.sav").path))
        let repeated = try repository.importDirectory(source, existing: imported.games)
        check(repeated.imported.id == imported.imported.id && repeated.games.count == 1)
        check(fm.fileExists(atPath: copy.appendingPathComponent("save1.sav").path))
        var played = imported.games
        played[0].lastPlayedAt = Date(timeIntervalSince1970: 42)
        try repository.save(played)
        check(try repository.load()[0].lastPlayedAt == played[0].lastPlayedAt)

        let wrapper = temp.appendingPathComponent("wrapper")
        let data = wrapper.appendingPathComponent("data")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("*start".utf8).write(to: data.appendingPathComponent("0.txt"))
        let wrapped = try repository.importDirectory(wrapper, existing: played)
        check(wrapped.imported.title == "wrapper")
        check(fm.fileExists(atPath: repository.gameURL(wrapped.imported).appendingPathComponent("0.txt").path))
        let unknown = temp.appendingPathComponent("unknown")
        try fm.createDirectory(at: unknown, withIntermediateDirectories: true)
        try fm.createDirectory(at: unknown.appendingPathComponent("startup.tjs"), withIntermediateDirectories: true)
        do { _ = try repository.importDirectory(unknown, existing: wrapped.games); fatalError("unknown accepted") }
        catch GameLibrary.Failure.unsupported {}
        do { _ = try repository.importDirectory(temp, existing: wrapped.games); fatalError("recursive source accepted") }
        catch GameLibrary.Failure.unsafeSource {}
        try fm.createSymbolicLink(at: source.appendingPathComponent("external"), withDestinationURL: data)
        let separate = GameLibrary(root: temp.appendingPathComponent("separate"))
        do { _ = try separate.importDirectory(source, existing: []); fatalError("symlink accepted") }
        catch GameLibrary.Failure.symbolicLink {}

        // Force manifest write failure after copying; no orphan library entry.
        let blocked = GameLibrary(root: temp.appendingPathComponent("blocked"))
        try fm.createDirectory(at: blocked.root.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        do { _ = try blocked.importDirectory(wrapper, existing: []); fatalError("manifest failure ignored") }
        catch { check((try fm.contentsOfDirectory(atPath: blocked.root.appendingPathComponent("Games").path)).isEmpty) }
        check(fm.fileExists(atPath: data.appendingPathComponent("0.txt").path))

        let id = UUID()
        let invalid = LibraryGame(id: id, title: "invalid", directory: "../outside", sourcePath: "", importedAt: Date(), lastPlayedAt: nil)
        try repository.save([invalid])
        let before = try Data(contentsOf: repository.root.appendingPathComponent("library.json"))
        do { _ = try repository.load(); fatalError("path escape accepted") }
        catch GameLibrary.Failure.invalidManifest {}
        check(try Data(contentsOf: repository.root.appendingPathComponent("library.json")) == before)
        print("PASS: managed copy, source isolation, duplicate/save preservation, reload, wrapper detection, symlink/recursive rejection, rollback, manifest path protection")
    }
}
