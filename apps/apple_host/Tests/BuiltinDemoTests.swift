import Foundation

/// Built-in demo install/reconcile/removal, mirrored from Godot's BuiltinDemo.
enum BuiltinDemoTests {
    static func run(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("demo-source.xp3")
        try Data(repeating: 7, count: 4096).write(to: source)
        let demo = BuiltinDemo(root: root, sourceURL: source)
        precondition(!demo.isRemoved())
        // Reconciling installs the packed demo and adds exactly one entry.
        var games = demo.reconciled([])
        precondition(games.count == 1)
        precondition(games[0].builtinId == BuiltinDemo.id && games[0].builtinVersion == BuiltinDemo.version)
        precondition(games[0].isBuiltin)
        precondition(FileManager.default.fileExists(atPath: demo.installURL.path))
        precondition(demo.isPath(demo.installDirectory.path))
        // Idempotent: re-reconciling keeps one entry and preserves play time.
        games[0].playDurationSeconds = 120
        games = demo.reconciled(games)
        precondition(games.count == 1 && games[0].playDurationSeconds == 120)
        // Removal deletes the install and is remembered.
        precondition(demo.remove())
        precondition(demo.isRemoved())
        precondition(!FileManager.default.fileExists(atPath: demo.installDirectory.path))
        precondition(demo.reconciled(games).isEmpty, "a removed demo must not be reinstalled")
        // A missing bundled source simply yields no entry rather than failing.
        let noSource = BuiltinDemo(root: root, sourceURL: nil)
        precondition(noSource.reconciled([]).isEmpty)
        print("PASS: built-in demo install, idempotent reconcile, remembered removal and missing-source handling")
    }
}
