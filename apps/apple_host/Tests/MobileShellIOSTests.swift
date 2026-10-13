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
