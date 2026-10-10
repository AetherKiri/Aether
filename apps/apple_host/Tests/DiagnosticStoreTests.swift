import Foundation

@main
struct DiagnosticStoreTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value) }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("aether-diagnostics-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let game = temp.appendingPathComponent("游戏")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("DO NOT EXPORT GAME SCRIPT".utf8).write(to: game.appendingPathComponent("startup.tjs"))
        try Data("DO NOT EXPORT SAVE".utf8).write(to: game.appendingPathComponent("save.sav"))
        try Data((String(repeating: "x", count: 3000) + "\nENGINE FAILURE DETAIL\n").utf8).write(to: game.appendingPathComponent("krkr2.log"))
        let root = temp.appendingPathComponent("Diagnostics")
        let store = DiagnosticStore(root: root, limit: 1024)
        try store.update(["gamePath": game.path, "state": "failed", "error": "specific startup error"], newSession: true)
        let id = store.metadata["session"]!
        for i in 0..<30 { try store.append("line \(i) " + String(repeating: "h", count: 120)) }
        for name in ["host.log", "host.previous.log"] {
            check(try Data(contentsOf: root.appendingPathComponent(name)).count <= 1024)
        }
        let restarted = DiagnosticStore(root: root, limit: 1024)
        check(restarted.metadata["session"] == id)
        let report = temp.appendingPathComponent("report.txt")
        try restarted.export(to: report, context: ["os": "test"])
        let text = try String(contentsOf: report, encoding: .utf8)
        check(text.contains("specific startup error") && text.contains("ENGINE FAILURE DETAIL"))
        check(text.contains("line 29") && text.contains("unavailable"))
        check(!text.contains("DO NOT EXPORT"))
        check(text.utf8.count < 5000)
        let secret = temp.appendingPathComponent("secret")
        try Data("SYMLINK SECRET".utf8).write(to: secret)
        try fm.createSymbolicLink(at: game.appendingPathComponent("aetherkiri-engine.log"), withDestinationURL: secret)
        try restarted.export(to: report, context: [:])
        check(!(try String(contentsOf: report, encoding: .utf8)).contains("SYMLINK SECRET"))
        do { try restarted.export(to: root.appendingPathComponent("host.log"), context: [:]); fatalError("overwrote evidence") }
        catch CocoaError.fileWriteInvalidFileName {}
        do { try restarted.export(to: game.appendingPathComponent("krkr2.log"), context: [:]); fatalError("overwrote engine log") }
        catch CocoaError.fileWriteInvalidFileName {}
        try restarted.update(["gamePath": "/next", "state": "starting"], newSession: true)
        check(restarted.metadata["error"] == nil && restarted.metadata["session"] != id)
        // Unwritable persistence fails visibly instead of silently claiming success.
        let blocked = temp.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        do { try DiagnosticStore(root: blocked).append("error"); fatalError("invalid root accepted") }
        catch {}
        print("DiagnosticStore tests PASS: rotation, restart, bounded tails, missing logs, asset exclusion, symlinks, evidence protection, session reset, write failure")
    }
}
