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

    func testMobileThemesKeepReadableControlText() {
        for theme in ShellTheme.allCases {
            let palette=theme.palette
            XCTAssertGreaterThanOrEqual(palette.accentText.contrast(with:palette.background),4.5)
            XCTAssertGreaterThanOrEqual(palette.accentText.contrast(with:palette.surface),4.5)
            XCTAssertGreaterThanOrEqual(palette.primary.contrast(with:palette.surface),4.5)
            XCTAssertGreaterThanOrEqual(ThemePalette.Ink(hex:0xffffff).contrast(with:palette.controlAccent),4.5)
        }
    }
    func testMobileSettingsDraftPersistenceMigrationAndFailedWrite() throws {
        try withFixture {root in
            let model=MobilePreferencesState(root:root)
            XCTAssertEqual(model.settings.host.outputResolution,"original")
            XCTAssertEqual(model.settings.host.frameEnhancementKind,"off")
            XCTAssertEqual(model.settings.interfaceScale,"comfortable")
            model.draft.host.theme="warm_dark"; model.draft.interfaceScale="compact"
            XCTAssertEqual(model.settings.host.theme,"classic"); XCTAssertTrue(model.isDirty)
            model.discard(); XCTAssertFalse(model.isDirty)
            model.draft.host.theme="warm_light"; model.draft.host.renderer="software"
            model.draft.host.pluginLoadMode="aether_all"; model.draft.host.mockEnabled=false
            XCTAssertTrue(model.save()); XCTAssertFalse(model.isDirty)
            let reopened=MobilePreferencesState(root:root)
            XCTAssertEqual(reopened.settings,model.settings)
            reopened.draft.host.theme="dark"
            reopened.quickLanguage(.japanese)
            XCTAssertEqual(reopened.settings.host.languageMode,"japanese")
            XCTAssertEqual(reopened.settings.host.theme,"warm_light")
            XCTAssertEqual(reopened.draft.host.theme,"dark"); XCTAssertTrue(reopened.isDirty)
            let saved=try Data(contentsOf:model.store.url)
            try FileManager.default.removeItem(at:model.store.url)
            try FileManager.default.createDirectory(at:model.store.url,withIntermediateDirectories:true)
            XCTAssertFalse(reopened.save()); XCTAssertTrue(reopened.isDirty)
            XCTAssertEqual(reopened.settings.host.theme,"warm_light")
            try FileManager.default.removeItem(at:model.store.url)
            try saved.write(to:model.store.url)
            // Desktop choices must not be reset to mobile defaults during migration.
            var desktop=HostSettings(); desktop.outputResolution="4k"; desktop.frameEnhancementKind="preset"
            try JSONEncoder().encode(desktop).write(to:model.store.url)
            let migrated=MobilePreferencesState(root:root)
            XCTAssertEqual(migrated.settings.host.outputResolution,"4k")
            XCTAssertEqual(migrated.settings.host.frameEnhancementKind,"preset")
            XCTAssertEqual(migrated.settings.interfaceScale,"comfortable")
            migrated.draft.host.theme="dark"; XCTAssertTrue(migrated.save())
            let encoded=try JSONSerialization.jsonObject(with:Data(contentsOf:model.store.url)) as? [String:Any]
            XCTAssertEqual(encoded?["version"] as? Int,2); XCTAssertNotNil(encoded?["host"])
            try Data("broken".utf8).write(to:model.store.url)
            let broken=MobilePreferencesState(root:root)
            XCTAssertFalse(broken.writable); XCTAssertFalse(broken.save())
            XCTAssertEqual(try Data(contentsOf:model.store.url),Data("broken".utf8))
        }
    }
    func testSavedSoftwareRendererActuallyStartsSoftwareDemo() async throws {
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous=scene.windows.first(where:{$0.isKeyWindow})
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shell=MobileShellState(supportRoot:root,gamesRoot:root.appendingPathComponent("Games"),environment:[LegalAgreement.bypassEnvironmentKey:"1"])
        let preferences=MobilePreferencesState(root:root)
        preferences.draft.host.renderer="software"; preferences.draft.host.mockEnabled=false
        XCTAssertTrue(preferences.save())
        let model=MobileGameViewModel(url:try shell.prepareDemo(),settings:preferences.settings.host)
        let controller=model.controller
        XCTAssertTrue(controller.prefersSoftwareRendering)
        XCTAssertEqual(controller.engineOptions["mock_enabled"],"0")
        let window=UIWindow(windowScene:scene); window.rootViewController=controller; window.makeKeyAndVisible()
        defer {controller.stop(); window.isHidden=true; previous?.makeKeyAndVisible(); try? FileManager.default.removeItem(at:root)}
        for _ in 0..<200 {
            if controller.softwareFrameCount() >= 3 || model.error != nil {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertNil(model.error); XCTAssertGreaterThanOrEqual(controller.softwareFrameCount(),3)
        XCTAssertEqual(controller.submittedMetalFrames(),0)
    }

    func testMobileLandscapeEnvelopeMigrationAndFuturePreservation() throws {
        try withFixture {root in
            let model=MobilePreferencesState(root:root)
            var v1=try JSONSerialization.jsonObject(with:JSONEncoder().encode(model.settings)) as! [String:Any]
            v1["version"]=1; v1.removeValue(forKey:"landscapeLocked")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:v1).write(to:model.store.url)
            let migrated=MobilePreferencesState(root:root)
            XCTAssertEqual(migrated.settings.version,2); XCTAssertFalse(migrated.settings.landscapeLocked)
            migrated.draft.landscapeLocked=true
            XCTAssertFalse(migrated.settings.landscapeLocked)
            XCTAssertTrue(migrated.save())
            XCTAssertTrue(MobilePreferencesState(root:root).settings.landscapeLocked)
            var future=migrated.settings; future.version=3
            let data=try JSONEncoder().encode(future); try data.write(to:model.store.url)
            let preserved=MobilePreferencesState(root:root)
            XCTAssertFalse(preserved.writable); XCTAssertFalse(preserved.save())
            XCTAssertEqual(try Data(contentsOf:model.store.url),data)
        }
    }
    func testOrientationDenialRetryStaleCallbacksAndOwnerIsolation() async throws {
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene)
        var requests: [UIInterfaceOrientationMask]=[]
        var callbacks: [(Error)->Void]=[]
        let policy=MobileOrientationPolicy {_, mask, failure in requests.append(mask); callbacks.append(failure)}
        var failures=0
        let first=try XCTUnwrap(policy.begin(scene:scene,locked:true) {failures += 1})
        XCTAssertEqual(requests,[.landscape]); XCTAssertEqual(policy.supportedMask(for:window),.landscape)
        XCTAssertNil(policy.begin(scene:scene,locked:true) {XCTFail("Another owner was accepted")})
        policy.retry(first) {failures += 1}
        callbacks[0](CocoaError(.featureUnsupported))
        for _ in 0..<10 {await Task.yield()}
        XCTAssertEqual(failures,0); XCTAssertEqual(policy.supportedMask(for:window),.landscape)
        callbacks[1](CocoaError(.featureUnsupported))
        for _ in 0..<10 {await Task.yield()}
        XCTAssertEqual(failures,1); XCTAssertEqual(policy.supportedMask(for:window),MobileOrientationPolicy.shellMask(scene))
        policy.end(first)
        let second=try XCTUnwrap(policy.begin(scene:scene,locked:true) {failures += 1})
        policy.end(first); callbacks[1](CocoaError(.featureUnsupported))
        for _ in 0..<10 {await Task.yield()}
        XCTAssertEqual(policy.supportedMask(for:window),.landscape); XCTAssertEqual(failures,1)
        policy.end(second); policy.end(second)
        XCTAssertEqual(policy.supportedMask(for:window),MobileOrientationPolicy.shellMask(scene))
    }
    func testOrientationUnlockedAndDisconnectRelease() async throws {
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene)
        var requests=0
        let policy=MobileOrientationPolicy {_,_,_ in requests += 1}
        let owner=MobileOrientationOwner(locked:false,policy:policy)
        owner.begin(scene:scene); owner.begin(scene:scene)
        XCTAssertEqual(requests,0)
        NotificationCenter.default.post(name:UIScene.didDisconnectNotification,object:scene)
        for _ in 0..<10 {await Task.yield()}
        XCTAssertEqual(policy.supportedMask(for:window),MobileOrientationPolicy.shellMask(scene))
        XCTAssertNotNil(policy.begin(scene:scene,locked:false) {})
        owner.end() // Its obsolete token must not release the newer owner.
        XCTAssertNil(policy.begin(scene:scene,locked:false) {})
        NotificationCenter.default.post(name:UIScene.didDisconnectNotification,object:scene)
        for _ in 0..<10 {await Task.yield()}
    }
    func testRealGeometryRequestRotatesOrReportsDenialAndUnlocksOnStop() async throws {
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previousWindow=scene.windows.first(where:{$0.isKeyWindow})
        let previousOrientation=scene.interfaceOrientation
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shell=MobileShellState(supportRoot:root,gamesRoot:root.appendingPathComponent("Games"),environment:[LegalAgreement.bypassEnvironmentKey:"1"])
        let model=MobileGameViewModel(url:try shell.prepareDemo(),settings:MobilePreferences.defaultHost,landscapeLocked:true)
        let window=UIWindow(windowScene:scene); window.rootViewController=model.controller; window.makeKeyAndVisible()
        defer {model.controller.stop(); window.isHidden=true; previousWindow?.makeKeyAndVisible(); try? FileManager.default.removeItem(at:root)}
        for _ in 0..<80 {
            if model.error != nil || model.orientationFailed || scene.interfaceOrientation.isLandscape {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.orientationFailed || scene.interfaceOrientation.isLandscape)
        if model.orientationFailed {
            XCTAssertEqual(MobileOrientationPolicy.shared.supportedMask(for:window),MobileOrientationPolicy.shellMask(scene))
        } else {
            XCTAssertEqual(MobileOrientationPolicy.shared.supportedMask(for:window),.landscape)
        }
        for _ in 0..<100 {
            if model.controller.submittedMetalFrames() >= 3 || model.error != nil {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertNil(model.error); XCTAssertGreaterThanOrEqual(model.controller.submittedMetalFrames(),3)
        print("IOS geometry outcome landscape=\(scene.interfaceOrientation.isLandscape) denied=\(model.orientationFailed)")
        model.controller.stop(); model.controller.stop()
        XCTAssertEqual(MobileOrientationPolicy.shared.supportedMask(for:window),MobileOrientationPolicy.shellMask(scene))
        for _ in 0..<80 {
            if scene.interfaceOrientation == previousOrientation {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        print("IOS geometry restored previous=\(previousOrientation.rawValue) actual=\(scene.interfaceOrientation.rawValue)")
        // Rotation is a system request; policy restoration is required even
        // when a narrow/multitasking scene refuses the preferred geometry.
    }

    func testSceneDisconnectStopsEngineAndOrientationOnce() async throws {
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous=scene.windows.first(where:{$0.isKeyWindow})
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shell=MobileShellState(supportRoot:root,gamesRoot:root.appendingPathComponent("Games"),environment:[LegalAgreement.bypassEnvironmentKey:"1"])
        let model=MobileGameViewModel(url:try shell.prepareDemo(),settings:MobilePreferences.defaultHost)
        let window=UIWindow(windowScene:scene); window.rootViewController=model.controller; window.makeKeyAndVisible()
        defer {model.controller.stop(); window.isHidden=true; previous?.makeKeyAndVisible(); try? FileManager.default.removeItem(at:root)}
        for _ in 0..<100 {
            if model.controller.submittedMetalFrames() >= 3 || model.error != nil {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertNil(model.error); XCTAssertGreaterThanOrEqual(model.controller.submittedMetalFrames(),3)
        XCTAssertNil(MobileOrientationPolicy.shared.begin(scene:scene,locked:false) {})
        NotificationCenter.default.post(name:UIScene.didDisconnectNotification,object:scene)
        for _ in 0..<10 {await Task.yield()}
        let final=model.controller.metalDiagnostics()
        XCTAssertTrue(final.contains("leases_live=0"),final)
        XCTAssertTrue(final.contains("render_generation=0"),final)
        XCTAssertTrue(final.contains("lease_failures=0"),final)
        let newOwner=try XCTUnwrap(MobileOrientationPolicy.shared.begin(scene:scene,locked:false) {})
        NotificationCenter.default.post(name:UIScene.didDisconnectNotification,object:scene)
        for _ in 0..<10 {await Task.yield()}
        model.controller.stop(); MobileOrientationPolicy.shared.end(newOwner)
        XCTAssertEqual(model.controller.submittedMetalFrames(),0)
    }

    func testMobileCanvasUsesOneAspectFitMappingForTouchAndCursor() throws {
        let canvas=AetherMobileCanvas(frame:CGRect(x:0,y:0,width:300,height:300))
        canvas.canvas=CGSize(width:640,height:480)
        XCTAssertEqual(canvas.contentRect,CGRect(x:0,y:37.5,width:300,height:225))
        XCTAssertEqual(canvas.logicalPoint(forViewPoint:CGPoint(x:150,y:150),clamp:false),CGPoint(x:320,y:240))
        XCTAssertEqual(canvas.logicalPoint(forViewPoint:CGPoint(x:150,y:10),clamp:false),CGPoint(x:-1,y:-1))
        XCTAssertEqual(canvas.logicalPoint(forViewPoint:CGPoint(x:-5,y:500),clamp:true),CGPoint(x:0,y:479))
        canvas.virtualMouse=true
        XCTAssertEqual(canvas.moveCursor(by:CGSize(width:30,height:15)),CGPoint(x:383.5,y:271.5))
        XCTAssertEqual(canvas.moveCursor(by:CGSize(width:10000,height:-10000)),CGPoint(x:639,y:0))
    }
    func testMobileControlsPairsModifiersPauseResizeAndCursorScope() async throws {
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous=scene.windows.first(where:{$0.isKeyWindow})
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shell=MobileShellState(supportRoot:root,gamesRoot:root.appendingPathComponent("Games"),environment:[LegalAgreement.bypassEnvironmentKey:"1"])
        let model=MobileGameViewModel(url:try shell.prepareDemo(),settings:MobilePreferences.defaultHost)
        var events: [[String:NSNumber]]=[]
        model.controller.hostInputObserved={events.append($0)}
        let window=UIWindow(windowScene:scene); window.rootViewController=model.controller; window.makeKeyAndVisible()
        defer {model.controller.stop(); window.isHidden=true; previous?.makeKeyAndVisible(); try? FileManager.default.removeItem(at:root)}
        for _ in 0..<100 {
            if model.controller.submittedMetalFrames() >= 3 || model.error != nil {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertNil(model.error); XCTAssertTrue(model.controller.inputAvailable)
        XCTAssertEqual(model.controlMode,.touch)
        model.toggleControls(); model.setControlHeld(true); model.setControlHeld(true)
        model.tapKey(0x20); model.tapKey(0x20)
        XCTAssertEqual(events.map {$0["type"]?.intValue},[5,5,6,5,6])
        XCTAssertEqual(events.map {$0["modifiers"]?.intValue},[4,4,4,4,4])
        model.controller.setSystemModalPresented(true)
        XCTAssertFalse(model.controlHeld); XCTAssertEqual(events.last?["key"]?.intValue,0x11)
        XCTAssertEqual(events.last?["type"]?.intValue,6); XCTAssertEqual(events.last?["modifiers"]?.intValue,0)
        let paused=events.count; model.setControlHeld(true); model.tapKey(0x20)
        XCTAssertFalse(model.controlHeld); XCTAssertEqual(events.count,paused)
        model.controller.setSystemModalPresented(false)
        model.setControlHeld(true); model.setControlMode(.mouse)
        XCTAssertFalse(model.controlHeld); XCTAssertTrue(model.controller.virtualMouseMode)
        events=[]
        model.controller.hostInputObserved={event in
            events.append(event)
            if event["type"]?.intValue == 5 {model.controller.cancelHostInput()}
        }
        model.tapKey(0x20)
        XCTAssertEqual(events.map {$0["type"]?.intValue},[5,6],"A reset during down dispatch must release exactly once")
        events=[]; model.setControlHeld(true)
        XCTAssertFalse(model.controlHeld); XCTAssertEqual(model.controller.hostInputModifiers,0)
        XCTAssertEqual(events.map {$0["type"]?.intValue},[5,6],"A reset during Ctrl down must not relatch its UI or modifier")
        model.controller.hostInputObserved={events.append($0)}
        events=[]
        let start=model.controller.virtualCursorPosition(), rect=model.controller.inputContentRect(), size=model.controller.logicalCanvasSize()
        let drag=model.beginCursorDrag(); model.moveCursor(CGSize(width:12,height:0),owner:drag)
        XCTAssertEqual(model.controller.virtualCursorPosition().x,start.x+12*size.width/rect.width,accuracy:0.001)
        model.clickCursor()
        XCTAssertEqual(events.map {$0["type"]?.intValue},[2,1,3])
        model.controller.cancelHostInput()
        let before=model.controller.virtualCursorPosition(); model.moveCursor(CGSize(width:12,height:0),owner:drag)
        XCTAssertEqual(model.controller.virtualCursorPosition(),before)
        let newer=model.beginCursorDrag()
        model.moveCursor(CGSize(width:12,height:0),owner:drag); model.endCursorDrag(drag)
        XCTAssertEqual(model.controller.virtualCursorPosition(),before)
        model.moveCursor(CGSize(width:12,height:0),owner:newer)
        XCTAssertGreaterThan(model.controller.virtualCursorPosition().x,before.x)
        model.setControlHeld(true)
        model.controller.view.bounds.size.width -= 20; model.controller.view.setNeedsLayout(); model.controller.view.layoutIfNeeded()
        XCTAssertFalse(model.controlHeld)
        model.setControlHeld(true); model.toggleControls()
        XCTAssertFalse(model.controlsVisible); XCTAssertFalse(model.controlHeld); XCTAssertFalse(model.controller.virtualMouseMode)
        model.toggleControls(); model.setControlHeld(true); model.controller.stop()
        XCTAssertFalse(model.controlHeld); XCTAssertEqual(events.last?["type"]?.intValue,6)
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
