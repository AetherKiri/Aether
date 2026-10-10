import Foundation

@main
struct GameArchiveTests {
    static func main() throws {
        let evidence = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aether-archive-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let repo = GameLibrary(root: temp.appendingPathComponent("library"))
        func fixture(_ name: String) -> URL { evidence.appendingPathComponent(name + ".zip") }
        func check(_ condition: Bool, line: UInt = #line) { precondition(condition, "Check failed at line \(line)") }
        let first = try repo.importArchive(fixture("wrapped"), existing: [])
        check(first.imported.title == "wrapped" && first.imported.sourcePath == fixture("wrapped").path)
        check(try repo.load() == first.games)
        check(try String(contentsOf: repo.gameURL(first.imported).appendingPathComponent("startup.tjs"), encoding: .utf8) == "fixture script")
        let original = try Data(contentsOf: fixture("wrapped"))
        try Data("save".utf8).write(to: repo.gameURL(first.imported).appendingPathComponent("save.dat"))
        let repeated = try repo.importArchive(fixture("wrapped"), existing: first.games)
        check(repeated.imported.id == first.imported.id && repeated.games.count == 1)
        check(FileManager.default.fileExists(atPath: repo.gameURL(first.imported).appendingPathComponent("save.dat").path))
        check(try Data(contentsOf: fixture("wrapped")) == original)
        for name in ["flat", "zip64", "unicode"] {
            let result = try repo.importArchive(fixture(name), existing: try repo.load())
            check(FileManager.default.fileExists(atPath: repo.gameURL(result.imported).appendingPathComponent("0.txt").path))
        }
        let stagesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("aether-zip-") })
        let before = try Data(contentsOf: repo.root.appendingPathComponent("library.json"))
        for name in ["traversal", "absolute", "symlink", "case-collision", "parent-collision", "corrupt", "crc", "ambiguous", "empty", "unknown", "notzip", "encrypted"] {
            do { _ = try repo.importArchive(fixture(name), existing: try repo.load()); fatalError("accepted \(name)") } catch {}
            check(try Data(contentsOf: repo.root.appendingPathComponent("library.json")) == before)
        }
        for limits in [GameArchive.Limits(entries: 1, bytes: 1000), GameArchive.Limits(entries: 100, bytes: 2)] {
            do { try GameArchive.extract(fixture("wrapped"), to: temp.appendingPathComponent(UUID().uuidString), limits: limits); fatalError("limit ignored") }
            catch GameArchive.Failure.tooLarge {}
        }
        let blocked = GameLibrary(root: temp.appendingPathComponent("blocked"))
        try FileManager.default.createDirectory(at: blocked.root.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        do { _ = try blocked.importArchive(fixture("wrapped"), existing: []); fatalError("write failure ignored") } catch {}
        check(try FileManager.default.contentsOfDirectory(atPath: blocked.root.appendingPathComponent("Games").path).isEmpty)
        check(try Data(contentsOf: fixture("wrapped")) == original)
        check(Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("aether-zip-") }) == stagesBefore)
        print("PASS: flat/wrapped/Unicode/ZIP64 import, dedup/save/source preservation, unsafe paths/links/collisions/encryption/CRC rejection, ambiguity, limits, manifest rollback")
    }
}
