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
    private func awaitCover(_ editor: MobileCoverEditor) async throws {
        for _ in 0..<400 {
            if !editor.busy { return }
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Cover task did not finish")
    }
    func testManualCoverCopiesPersistsRelocatesAndClearSurvivesReload() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data("// import fixture".utf8).write(to:source.appendingPathComponent("startup.tjs"))
        let model=MobileLibraryState(supportRoot:root.appendingPathComponent("Support"),gamesRoot:root.appendingPathComponent("Games"))
        await model.importURL(source)
        let game=try XCTUnwrap(model.games.first)
        let image=UIGraphicsImageRenderer(size:CGSize(width:20,height:30)).pngData {context in
            UIColor.red.setFill(); context.fill(CGRect(x:0,y:0,width:20,height:30))
        }
        let external=root.appendingPathComponent("selected.png")
        try image.write(to:external)
        let editor=MobileCoverEditor(model:model,gameID:game.id)
        editor.selectFile(external); try await awaitCover(editor)
        XCTAssertNil(editor.errorKey); XCTAssertTrue(editor.applied)
        let stored=try XCTUnwrap(model.games.first?.coverPath)
        XCTAssertTrue(stored.hasPrefix("library://Covers/"))
        try FileManager.default.removeItem(at:external)
        let reopened=MobileLibraryState(supportRoot:model.library.root,gamesRoot:root.appendingPathComponent("Games"))
        let url=try XCTUnwrap(reopened.coverURL(try XCTUnwrap(reopened.games.first)))
        XCTAssertNotNil(UIImage(contentsOfFile:url.path))
        let relocated=root.appendingPathComponent("MovedSupport")
        try FileManager.default.moveItem(at:model.library.root,to:relocated)
        let moved=MobileLibraryState(supportRoot:relocated,gamesRoot:root.appendingPathComponent("Games"))
        XCTAssertNotNil(UIImage(contentsOfFile:try XCTUnwrap(moved.coverURL(gameWithCover(game,stored))).path))
        let movedEditor=MobileCoverEditor(model:moved,gameID:game.id)
        let invalid=root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to:invalid)
        movedEditor.selectFile(invalid); try await awaitCover(movedEditor)
        XCTAssertEqual(moved.games.first?.coverPath,stored); XCTAssertNotNil(movedEditor.errorKey)
        let index=relocated.appendingPathComponent("library.json")
        let savedIndex=try Data(contentsOf:index)
        try FileManager.default.removeItem(at:index)
        try FileManager.default.createDirectory(at:index,withIntermediateDirectories:true)
        let covers=relocated.appendingPathComponent("Covers")
        let before=try FileManager.default.contentsOfDirectory(atPath:covers.path)
        try image.write(to:external)
        movedEditor.selectFile(external); try await awaitCover(movedEditor)
        XCTAssertEqual(moved.games.first?.coverPath,stored)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:covers.path),before)
        try FileManager.default.removeItem(at:index); try savedIndex.write(to:index)
        movedEditor.clear(); moved.reload()
        XCTAssertNil(moved.games.first?.coverPath); XCTAssertEqual(moved.games.first?.coverSuppressed,true)
        XCTAssertThrowsError(try MobileCoverImage.normalized(Data(repeating:0,count:MobileCoverImage.maximumBytes+1)))
        var escaped=game; escaped.coverPath="library://../selected.png"
        XCTAssertNil(moved.library.coverURL(escaped))
    }
    private func gameWithCover(_ game: LibraryGame,_ path: String) -> LibraryGame {
        var value=game; value.coverPath=path; return value
    }
    func testOnlineCoverExplicitTitleLateResultAndInvalidImageIsolation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("A title")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data("// fixture".utf8).write(to:source.appendingPathComponent("startup.tjs"))
        let model=MobileLibraryState(supportRoot:root.appendingPathComponent("Support"),gamesRoot:root.appendingPathComponent("Games"))
        await model.importURL(source)
        let game=try XCTUnwrap(model.games.first)
        let provider=ControlledMobileCoverSearch()
        let candidate=CoverCandidate(id:"v1",title:"Result",imageURL:URL(string:"https://example.com/image.png")!,thumbnailURL:URL(string:"https://example.com/thumb.png")!)
        let editor=MobileCoverEditor(model:model,gameID:game.id,search:provider,loader:StubMobileCoverLoader(data:Data("invalid image".utf8)))
        XCTAssertTrue(provider.titles.isEmpty)
        editor.searchOnline()
        while provider.requests.isEmpty {await Task.yield()}
        XCTAssertEqual(provider.titles,[game.displayTitle])
        editor.cancel(); editor.searchOnline()
        while provider.requests.count < 2 {await Task.yield()}
        provider.requests[0].resume(returning:[candidate])
        for _ in 0..<10 {await Task.yield()}
        XCTAssertTrue(editor.candidates.isEmpty); XCTAssertTrue(editor.busy)
        provider.requests[1].resume(returning:[candidate]); try await awaitCover(editor)
        XCTAssertEqual(editor.candidates,[candidate])
        editor.selectCandidate(candidate); try await awaitCover(editor)
        XCTAssertEqual(editor.errorKey,"coverSearchFailed"); XCTAssertNil(model.games.first?.coverPath)
        XCTAssertFalse(model.isEditingCover)
        let goodImage=UIGraphicsImageRenderer(size:CGSize(width:10,height:10)).pngData {context in
            UIColor.blue.setFill(); context.fill(CGRect(x:0,y:0,width:10,height:10))
        }
        let success=MobileCoverEditor(model:model,gameID:game.id,search:provider,loader:StubMobileCoverLoader(data:goodImage))
        success.searchOnline()
        while provider.requests.count < 3 {await Task.yield()}
        provider.requests[2].resume(returning:[candidate]); try await awaitCover(success)
        success.selectCandidate(candidate); try await awaitCover(success)
        XCTAssertTrue(success.applied); XCTAssertNil(success.errorKey)
        let prior=model.games.first?.coverPath
        editor.selectCandidate(candidate); try await awaitCover(editor)
        XCTAssertEqual(editor.errorKey,"coverSearchFailed"); XCTAssertEqual(model.games.first?.coverPath,prior)
        success.deactivate(); XCTAssertFalse(success.canEdit)
        success.searchOnline(); XCTAssertFalse(success.busy)
        let request=try VNDBCoverSearch.makeRequest(title:game.displayTitle)
        let body=try XCTUnwrap(String(data:try XCTUnwrap(request.httpBody),encoding:.utf8))
        XCTAssertFalse(body.contains(root.path))
    }

}

private final class ControlledMobileCoverSearch: CoverSearchProviding {
    var titles: [String]=[]
    var requests: [CheckedContinuation<[CoverCandidate],Error>]=[]
    func search(title: String) async throws -> [CoverCandidate] {
        titles.append(title)
        return try await withCheckedThrowingContinuation { requests.append($0) }
    }
}
private struct StubMobileCoverLoader: CoverImageLoading {
    let data: Data
    func load(_ url: URL) async throws -> Data {data}
}
