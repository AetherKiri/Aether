import XCTest
import UIKit

@MainActor
final class MobileOrientationUITests: XCTestCase {
    func testPhoneLandscapeGameReturnRestoresShell() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "Phone rotation path; iPad denial/window cases are covered separately")
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication(bundleIdentifier:"org.github.aetherkiri.host.ios")
        app.launchEnvironment["AETHER_HOST_BYPASS_LEGAL_GATE"]="1"
        app.launchArguments=["--ios-settings-preview","--ios-preview-landscape","--ios-demo-smoke"]
        app.launch()
        defer {app.terminate(); XCUIDevice.shared.orientation = .portrait}
        let back=app.buttons["mobile.game.return"]
        XCTAssertTrue(back.waitForExistence(timeout:15))
        let landscape=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in app.frame.width > app.frame.height},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[landscape],timeout:8),.completed)
        let running=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); running.name="product-landscape"; running.lifetime = .keepAlways; add(running)
        back.tap()
        let confirm=app.buttons["mobile.game.confirmReturn"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout:5)); confirm.tap()
        XCTAssertTrue(app.switches["mobile.settings.landscape"].firstMatch.waitForExistence(timeout:10))
        XCTAssertEqual(app.switches["mobile.settings.landscape"].firstMatch.value as? String,"1")
        let portrait=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in app.frame.height > app.frame.width},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[portrait],timeout:8),.completed)
        XCTAssertFalse(back.exists)
        let returned=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); returned.name="product-returned-settings"; returned.lifetime = .keepAlways; add(returned)
    }
}
