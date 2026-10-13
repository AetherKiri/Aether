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
