import Foundation

/// Runtime marker detection, the import gate and the provider probe.
enum GameRuntimeTests {
    static func run(root: URL) throws {
        try markerDetection(root: root)
        try hcbValidation(root: root)
        try importGate(root: root)
        providerProbe()
        print("PASS: runtime marker detection (kirikiri/onscripter/siglus/minori/rfvp), HCB validation, import gate and provider probe")
    }

    private static func write(_ names: [String], into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
    }

    private static func makeHCB(at url: URL, size: Int, descriptor: UInt32, start: UInt32) throws {
        var data = Data(repeating: 0, count: size)
        data.replaceSubrange(0..<4, with: withUnsafeBytes(of: descriptor.littleEndian) { Data($0) })
        if Int(descriptor) + 4 <= size {
            data.replaceSubrange(Int(descriptor)..<(Int(descriptor) + 4),
                                 with: withUnsafeBytes(of: start.littleEndian) { Data($0) })
        }
        try data.write(to: url)
    }

    private static func markerDetection(root: URL) throws {
        let base = root.appendingPathComponent("runtime-detect")
        try write(["data.xp3"], into: base.appendingPathComponent("xp3"))
        precondition(GameRuntimeDetector.inspect(root: base.appendingPathComponent("xp3"))
            == GameRuntimeInspection(runtime: .kirikiri, entryFile: "data.xp3", signals: ["kirikiri-xp3"]))
        try write(["startup.tjs"], into: base.appendingPathComponent("kag"))
        let kag = GameRuntimeDetector.inspect(root: base.appendingPathComponent("kag"))
        precondition(kag.runtime == .kirikiri && kag.entryFile == "startup.tjs" && kag.isRecognized)
        try write(["0.txt"], into: base.appendingPathComponent("ons"))
        let ons = GameRuntimeDetector.inspect(root: base.appendingPathComponent("ons"))
        precondition(ons.runtime == .onscripter && ons.entryFile == "0.txt")
        try write(["gameexe.ini"], into: base.appendingPathComponent("siglus"))
        let siglus = GameRuntimeDetector.inspect(root: base.appendingPathComponent("siglus"))
        precondition(siglus.runtime == .siglus && siglus.entryFile == "gameexe.ini")
        try write(["scr.paz", "sys.paz", "trinoline.exe"], into: base.appendingPathComponent("minori"))
        let minori = GameRuntimeDetector.inspect(root: base.appendingPathComponent("minori"))
        precondition(minori.runtime == .minori && minori.entryFile == "scr.paz")
        // Minori archives without a known executable fall through to unknown.
        try write(["scr.paz", "sys.paz"], into: base.appendingPathComponent("minori-partial"))
        precondition(GameRuntimeDetector.inspect(root: base.appendingPathComponent("minori-partial")).runtime == .unknown)
        try write(["notes.txt"], into: base.appendingPathComponent("unknown"))
        let unknown = GameRuntimeDetector.inspect(root: base.appendingPathComponent("unknown"))
        precondition(unknown.runtime == .unknown && !unknown.isRecognized)
        // ONScripter markers win over a stray startup.tjs (Godot's marker order).
        try write(["startup.tjs", "nscript.dat"], into: base.appendingPathComponent("mixed"))
        precondition(GameRuntimeDetector.inspect(root: base.appendingPathComponent("mixed")).runtime == .onscripter)
    }

    private static func hcbValidation(root: URL) throws {
        let folder = root.appendingPathComponent("runtime-detect/hcb")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let valid = folder.appendingPathComponent("game.hcb")
        try makeHCB(at: valid, size: 64, descriptor: 24, start: 8)
        precondition(GameRuntimeDetector.isRFVPBytecode(valid))
        let detection = GameRuntimeDetector.inspect(root: folder)
        precondition(detection.runtime == .rfvp && detection.entryFile == "game.hcb" && detection.isRecognized)
        let tiny = folder.appendingPathComponent("tiny.hcb")
        try Data(repeating: 0, count: 8).write(to: tiny)
        precondition(!GameRuntimeDetector.isRFVPBytecode(tiny))
        let badDescriptor = folder.appendingPathComponent("bad-descriptor.hcb")
        try makeHCB(at: badDescriptor, size: 64, descriptor: 4096, start: 8)
        precondition(!GameRuntimeDetector.isRFVPBytecode(badDescriptor))
        let badStart = folder.appendingPathComponent("bad-start.hcb")
        try makeHCB(at: badStart, size: 64, descriptor: 24, start: 30)
        precondition(!GameRuntimeDetector.isRFVPBytecode(badStart))
        // A folder with only an invalid hcb stays unrecognized/not importable.
        let invalidOnly = root.appendingPathComponent("runtime-detect/hcb-invalid")
        try FileManager.default.createDirectory(at: invalidOnly, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 8).write(to: invalidOnly.appendingPathComponent("broken.hcb"))
        precondition(GameRuntimeDetector.inspect(root: invalidOnly).runtime == .unknown)
    }

    private static func importGate(root: URL) throws {
        let library = GameLibrary(root: root.appendingPathComponent("runtime-import"))
        let base = root.appendingPathComponent("runtime-detect")
        let siglusImportable = try library.isGame(base.appendingPathComponent("siglus"))
        let hcbImportable = try library.isGame(base.appendingPathComponent("hcb"))
        let xp3Importable = try library.isGame(base.appendingPathComponent("xp3"))
        let unknownImportable = try library.isGame(base.appendingPathComponent("unknown"))
        let invalidHCBImportable = try library.isGame(base.appendingPathComponent("hcb-invalid"))
        precondition(siglusImportable, "Siglus folders are importable")
        precondition(hcbImportable, "validated HCB folders are importable")
        precondition(xp3Importable)
        precondition(!unknownImportable)
        precondition(!invalidHCBImportable)
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let onsImportable = try library.isGame(fixtures.appendingPathComponent("tests/fixtures/apple_host_ons_input"))
        let kagImportable = try library.isGame(fixtures.appendingPathComponent("demos/aetherkiri-kag3/data"))
        precondition(onsImportable && kagImportable)
        let ons = GameRuntimeDetector.inspect(root: fixtures.appendingPathComponent("tests/fixtures/apple_host_ons_input"))
        precondition(ons.runtime == .onscripter && ons.entryFile == "0.txt")
        let kag = GameRuntimeDetector.inspect(root: fixtures.appendingPathComponent("demos/aetherkiri-kag3/data"))
        precondition(kag.runtime == .kirikiri && !kag.entryFile.isEmpty)
    }

    private static func providerProbe() {
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let ons = fixtures.appendingPathComponent("tests/fixtures/apple_host_ons_input").path
        let kag = fixtures.appendingPathComponent("demos/aetherkiri-kag3/data").path
        // The linked ONScripter provider matches its fixture and rejects KAG.
        precondition(AetherEngineSession.probeRuntimeProvider("onscripter", path: ons) > 0,
                     "the ONScripter provider must recognize its fixture")
        precondition(AetherEngineSession.probeRuntimeProvider("onscripter", path: kag) <= 0)
        // Unknown ids and non-matching providers are reported, not crashed on.
        precondition(AetherEngineSession.probeRuntimeProvider("no-such-runtime", path: kag) < 0)
        precondition(AetherEngineSession.probeRuntimeProvider("siglus", path: kag) <= 0)
    }
}
