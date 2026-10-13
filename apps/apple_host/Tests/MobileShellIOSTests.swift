import XCTest
@testable import AetherHostIOS

@MainActor
final class MobileShellIOSTests: XCTestCase {
    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try body(root)
    }
    func testDocumentsPersistSeparatelyAndDeclineDoesNotLaunch() throws {
        try withFixture { root in
            let shell=MobileShellState(supportRoot:root, gamesRoot:root.appendingPathComponent("Games"), environment:[:])
            XCTAssertEqual(shell.requiredDocument,.privacy)
            shell.decline(); XCTAssertFalse(shell.canPlay)
            XCTAssertThrowsError(try shell.prepareDemo())
            shell.reviewAgain(); XCTAssertFalse(shell.declined)
            shell.acceptDocument(); XCTAssertEqual(shell.requiredDocument,.statement)
            XCTAssertFalse(shell.canPlay)
            let reload=MobileShellState(supportRoot:root, gamesRoot:root.appendingPathComponent("Games"), environment:[:])
            XCTAssertEqual(reload.requiredDocument,.statement)
            reload.acceptDocument(); XCTAssertTrue(reload.canPlay)
        }
    }
    func testFailedWriteRetainsGate() throws {
        try withFixture { root in
            let file=root.appendingPathComponent("not-a-directory")
            try Data().write(to:file)
            let shell=MobileShellState(supportRoot:file,gamesRoot:root.appendingPathComponent("Games"),environment:[:])
            shell.acceptDocument()
            XCTAssertEqual(shell.requiredDocument,.privacy)
            XCTAssertFalse(shell.canPlay); XCTAssertNotNil(shell.error)
        }
    }
    func testCorruptRecordRequiresPrivacyAgain() throws {
        try withFixture { root in
            let shell=MobileShellState(supportRoot:root,gamesRoot:root.appendingPathComponent("Games"),environment:[:])
            try Data("corrupt".utf8).write(to:shell.legalStore.url)
            let reload=MobileShellState(supportRoot:root,gamesRoot:shell.gamesRoot,environment:[:])
            XCTAssertEqual(reload.requiredDocument,.privacy); XCTAssertFalse(reload.canPlay)
        }
    }
    func testMetalFrameLeasePresentationAndStop() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = MobileShellState(supportRoot: root, gamesRoot: root.appendingPathComponent("Games"),
            environment: [LegalAgreement.bypassEnvironmentKey: "1"])
        let controller = AetherMobileGameController(gameURL: try fixture.prepareDemo())
        var failure: String?
        controller.failed = { failure = $0 }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            controller.stop(); window.isHidden = true; previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: root)
        }
        for _ in 0..<200 {
            if controller.submittedMetalFrames() >= 10 || failure != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(failure)
        XCTAssertGreaterThanOrEqual(controller.submittedMetalFrames(), 10)
        let live = controller.metalDiagnostics()
        XCTAssertTrue(live.contains("native_readbacks=0"), live)
        XCTAssertTrue(live.contains("native_copies=0"), live)
        controller.stop()
        let final = controller.metalDiagnostics()
        XCTAssertTrue(final.contains("leases_live=0"), final)
        XCTAssertTrue(final.contains("lease_failures=0"), final)
        XCTAssertTrue(final.contains("render_generation=0"), final)
        print("IOS Metal test final " + final)
    }
    func testPresentationFailureFallsBackAndReleasesLeases() async throws {
        setenv("AETHER_IOS_FAIL_PRESENTATION", "1", 1)
        defer { unsetenv("AETHER_IOS_FAIL_PRESENTATION") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = MobileShellState(supportRoot: root, gamesRoot: root.appendingPathComponent("Games"),
            environment: [LegalAgreement.bypassEnvironmentKey: "1"])
        let controller = AetherMobileGameController(gameURL: try fixture.prepareDemo())
        var failure: String?
        var fallbackKey: String?
        controller.failed = { failure = $0 }
        controller.presentationFallback = { fallbackKey = $0 }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            controller.stop(); window.isHidden = true; previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: root)
        }
        for _ in 0..<200 {
            if controller.softwareFrameCount() >= 3 || failure != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(failure)
        XCTAssertEqual(fallbackKey,"metalPresentationFailed")
        XCTAssertGreaterThanOrEqual(controller.softwareFrameCount(), 3)
        controller.stop()
        let final = controller.metalDiagnostics()
        XCTAssertTrue(final.contains("leases_live=0"), final)
        XCTAssertTrue(final.contains("lease_failures=0"), final)
        XCTAssertTrue(final.contains("render_generation=0"), final)
        print("IOS fallback test final " + final)
    }
    func testDirectoryImportPersistenceAndRelocation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("Selected")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:try XCTUnwrap(Bundle.main.url(forResource:"data",withExtension:"xp3")),to:source.appendingPathComponent("data.xp3"))
        try Data([1]).write(to:source.appendingPathComponent("cover.png"))
        let support=root.appendingPathComponent("Support"), games=root.appendingPathComponent("Documents/Games")
        let model=MobileLibraryState(supportRoot:support,gamesRoot:games)
        await model.importURL(source)
        XCTAssertNil(model.error); XCTAssertEqual(model.games.count,1)
        let game=try XCTUnwrap(model.games.first)
        XCTAssertNil(game.externalPath); XCTAssertEqual(game.coverPath,"game://cover.png")
        model.rename(game.id,title:"Renamed")
        let reload=MobileLibraryState(supportRoot:support,gamesRoot:games)
        XCTAssertEqual(reload.games.first?.title,"Renamed")
        let relocated=root.appendingPathComponent("MovedGames")
        try FileManager.default.moveItem(at:games,to:relocated)
        let moved=MobileLibraryState(supportRoot:support,gamesRoot:relocated)
        XCTAssertTrue(FileManager.default.fileExists(atPath:moved.library.gameURL(game).appendingPathComponent("data.xp3").path))
        moved.remove(game.id); XCTAssertTrue(moved.games.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:moved.library.gameURL(game).path))
    }
    func testOnlyKiriKiriAndFailedImportsDoNotPublish() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("ONS")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data("ons".utf8).write(to:source.appendingPathComponent("0.txt"))
        let model=MobileLibraryState(supportRoot:root.appendingPathComponent("Support"),gamesRoot:root.appendingPathComponent("Games"))
        await model.importURL(source)
        XCTAssertNotNil(model.error); XCTAssertTrue(model.games.isEmpty)
        XCTAssertTrue(try model.library.load().isEmpty)
    }
    func testCancellationAndPublicationBoundary() throws {
        try withFixture {root in
            let source=root.appendingPathComponent("Source")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(repeating:42,count:1024*1024).write(to:source.appendingPathComponent("startup.tjs"))
            let storage=root.appendingPathComponent("Games")
            let library=GameLibrary(root:root.appendingPathComponent("Support"),managedGamesRoot:storage,supportedRuntimes:[.kirikiri])
            let token=MobileImportControl()
            XCTAssertThrowsError(try library.importDirectory(source,existing:[],checkCancellation:token.check,
                progress:{_,_ in _=token.cancel()},publication:token.publish))
            XCTAssertTrue(try library.load().isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:storage.path).isEmpty)
            let committed=MobileImportControl()
            try committed.publish {XCTAssertFalse(committed.cancel())}
            XCTAssertFalse(committed.cancel())
            XCTAssertThrowsError(try library.importDirectory(source,existing:[],maximumBytes:1))
        }
    }
    func testSymbolicLinksRejectedAndManifestFailureRollsBack() throws {
        try withFixture {root in
            let source=root.appendingPathComponent("Source")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
            try Data("fixture".utf8).write(to:source.appendingPathComponent("startup.tjs"))
            try FileManager.default.createSymbolicLink(at:source.appendingPathComponent("linked"),withDestinationURL:root)
            let support=root.appendingPathComponent("Support"), games=root.appendingPathComponent("Games")
            let library=GameLibrary(root:support,managedGamesRoot:games,supportedRuntimes:[.kirikiri])
            XCTAssertThrowsError(try library.importDirectory(source,existing:[],maximumBytes:100))
            try FileManager.default.removeItem(at:source.appendingPathComponent("linked"))
            try Data("preserved".utf8).write(to:support)
            XCTAssertThrowsError(try library.importDirectory(source,existing:[],maximumBytes:100))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:games.path).isEmpty)
            XCTAssertEqual(try Data(contentsOf:support),Data("preserved".utf8))
        }
    }
    func testZIPImportAndUnsafeOrDeferredArchives() async throws {
        let bundle=Bundle(for:MobileShellIOSTests.self)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=MobileLibraryState(supportRoot:root.appendingPathComponent("Support"),gamesRoot:root.appendingPathComponent("Games"))
        let valid=try XCTUnwrap(bundle.url(forResource:"mobile-kirikiri",withExtension:"zip"))
        await model.importURL(valid)
        XCTAssertNil(model.error); XCTAssertEqual(model.games.count,1)
        let first=try XCTUnwrap(model.games.first)
        let managed=model.library.gameURL(first)
        XCTAssertEqual(try String(contentsOf:managed.appendingPathComponent("assets/note.txt"),encoding:.utf8),"preserve")
        try Data("save".utf8).write(to:managed.appendingPathComponent("save.dat"))
        await model.importURL(valid)
        XCTAssertEqual(model.games.count,1); XCTAssertEqual(model.games.first?.id,first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath:managed.appendingPathComponent("save.dat").path))
        for name in ["mobile-unsafe","mobile-ons"] {
            await model.importURL(try XCTUnwrap(bundle.url(forResource:name,withExtension:"zip")))
            XCTAssertNotNil(model.error); XCTAssertEqual(model.games.count,1)
            XCTAssertEqual(try model.library.load().count,1)
        }
        let token=MobileImportControl(); XCTAssertTrue(token.cancel())
        XCTAssertThrowsError(try model.library.importArchive(valid,existing:model.games,checkCancellation:token.check))
    }
    func testAllRequiredLocalizedResourcesExist() {
        for language in ShellLanguage.allCases {
            for document in LegalDocument.allCases {
                // The app bundle carries the documents, not the test bundle.
                let body=document.settingsDocument.contents(language:language,bundle:Bundle.main)
                XCTAssertNotNil(body); XCTAssertFalse(body?.isEmpty ?? true)
            }
        }
    }
}
