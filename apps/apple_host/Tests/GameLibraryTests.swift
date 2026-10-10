import Foundation

@main
struct GameLibraryTests {
    static func main() throws {
        func check(_ condition: Bool, line: UInt = #line) { precondition(condition, "Check failed at line \(line)") }
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
        let minori = temp.appendingPathComponent("Minori fixture")
        try fm.createDirectory(at: minori, withIntermediateDirectories: true)
        for name in ["scr.paz", "sys.paz", "trinoline.exe"] { try Data("fixture".utf8).write(to: minori.appendingPathComponent(name)) }
        let minoriImport = try repository.importDirectory(minori, existing: wrapped.games)
        check(fm.fileExists(atPath: repository.gameURL(minoriImport.imported).appendingPathComponent("scr.paz").path))
        try fm.removeItem(at: minori.appendingPathComponent("sys.paz"))
        do { _ = try GameLibrary(root: temp.appendingPathComponent("minori-incomplete")).importDirectory(minori, existing: []); fatalError("incomplete Minori accepted") }
        catch GameLibrary.Failure.unsupported {}
        try fm.createDirectory(at: minori.appendingPathComponent("sys.paz"), withIntermediateDirectories: true)
        do { _ = try GameLibrary(root: temp.appendingPathComponent("minori-directory")).importDirectory(minori, existing: []); fatalError("directory marker accepted") }
        catch GameLibrary.Failure.unsupported {}
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

        // Legacy records decode without the new optional externalPath field.
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(played)) as! [[String: Any]]
        check(legacy[0]["externalPath"] == nil)
        check(try JSONDecoder().decode([LibraryGame].self, from: JSONSerialization.data(withJSONObject: legacy))[0].isExternal == false)
        let renamed = try repository.rename(played[0].id, title: "  新名称 🎮  ", existing: played)
        check(renamed[0].title == "新名称 🎮" && renamed[0].lastPlayedAt == played[0].lastPlayedAt)
        check(try repository.load() == renamed)
        check(repository.gameURL(renamed[0]) == copy)
        let beforeRename = try Data(contentsOf: repository.root.appendingPathComponent("library.json"))
        for bad in [" ", String(repeating: "x", count: 201), "a\0b", "a\nb"] {
            do { _ = try repository.rename(played[0].id, title: bad, existing: renamed); fatalError("bad title accepted") }
            catch GameLibrary.Failure.invalidTitle {}
        }
        check(try Data(contentsOf: repository.root.appendingPathComponent("library.json")) == beforeRename)
        let external = try repository.importDirectory(wrapper, existing: renamed, external: true)
        check(external.imported.isExternal && repository.gameURL(external.imported).path == data.path)
        check(!fm.fileExists(atPath: repository.root.appendingPathComponent("Games").appendingPathComponent(external.imported.id.uuidString).path))
        check(try repository.load() == external.games)
        let copyFromExternal = try repository.importDirectory(data, existing: external.games)
        check(!copyFromExternal.imported.isExternal && copyFromExternal.imported.id != external.imported.id)
        check(repository.gameURL(copyFromExternal.imported).path != data.path)
        let externalRepeat = try repository.importDirectory(wrapper, existing: external.games, external: true)
        check(externalRepeat.imported.id == external.imported.id)
        let removed = try repository.remove(external.imported.id, existing: external.games)
        check(removed == renamed)
        check(try repository.load() == removed)
        check(fm.fileExists(atPath: data.appendingPathComponent("0.txt").path))
        let noGames = try repository.remove(renamed[0].id, existing: removed)
        check(noGames.isEmpty)
        check(try repository.load().isEmpty)
        check(fm.fileExists(atPath: copy.appendingPathComponent("save1.sav").path))
        let restored = try repository.importDirectory(copy, existing: noGames, external: true)
        check(fm.fileExists(atPath: repository.gameURL(restored.imported).appendingPathComponent("save1.sav").path))
        // Failed mutations leave both source files and the caller's list unchanged.
        do { _ = try blocked.remove(renamed[0].id, existing: renamed); fatalError("remove failure ignored") } catch {}
        do { _ = try blocked.rename(renamed[0].id, title: "changed", existing: renamed); fatalError("rename failure ignored") } catch {}
        check(renamed[0].title == "新名称 🎮" && fm.fileExists(atPath: copy.path))

        let id = UUID()
        let invalid = LibraryGame(id: id, title: "invalid", directory: "../outside", sourcePath: "", importedAt: Date(), lastPlayedAt: nil)
        try repository.save([invalid])
        let before = try Data(contentsOf: repository.root.appendingPathComponent("library.json"))
        do { _ = try repository.load(); fatalError("path escape accepted") }
        catch GameLibrary.Failure.invalidManifest {}
        check(try Data(contentsOf: repository.root.appendingPathComponent("library.json")) == before)
        print("PASS: managed copy, source isolation, duplicate/save preservation, reload, wrapper/Minori marker detection, symlink/recursive rejection, rollback, manifest path protection, legacy indexes, rename persistence, external references, non-destructive removal")
    }
}
