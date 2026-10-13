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
    func testControlPadEntryConsumesTouchCtrlReleasesAndMouseMoves() throws {
        continueAfterFailure=false
        let app=XCUIApplication(bundleIdentifier:"org.github.aetherkiri.host.ios")
        app.launchEnvironment["AETHER_HOST_BYPASS_LEGAL_GATE"]="1"
        app.launchArguments=["--ios-settings-preview","--ios-demo-smoke"]
        app.launch(); defer {app.terminate()}
        let canvas=app.images["mobile.game.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:15))
        let baseline=canvas.value as? String
        let entry=app.buttons["mobile.controls.entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout:5)); entry.tap()
        let ctrl=app.buttons["mobile.controls.ctrl"].firstMatch
        XCTAssertTrue(ctrl.waitForExistence(timeout:5))
        XCTAssertEqual(canvas.value as? String,baseline,"Entry must not send a game click")
        ctrl.tap(); XCTAssertTrue(ctrl.isSelected)
        app.buttons["mobile.controls.toggle"].firstMatch.tap()
        XCTAssertFalse(ctrl.exists)
        XCTAssertEqual(canvas.value as? String,"key=2 pointer=0")
        app.buttons["mobile.controls.toggle"].firstMatch.tap()
        XCTAssertTrue(ctrl.waitForExistence(timeout:5)); XCTAssertFalse(ctrl.isSelected)
        app.buttons["mobile.controls.mode.mouse"].firstMatch.tap()
        let handle=app.staticTexts["mobile.controls.pointerPad"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout:5))
        let begin=handle.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.5))
        let end=handle.coordinate(withNormalizedOffset:CGVector(dx:0.6,dy:0.5))
        begin.press(forDuration:0.1,thenDragTo:end)
        func pointers() -> Int {
            let value=canvas.value as? String ?? ""
            return Int(value.components(separatedBy:"pointer=").last ?? "") ?? -1
        }
        let horizontal=pointers(); XCTAssertGreaterThan(horizontal,0)
        let verticalEnd=handle.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.85))
        begin.press(forDuration:0.1,thenDragTo:verticalEnd)
        let moved=pointers(); XCTAssertGreaterThan(moved,horizontal,"Vertical pointer drag must not be consumed by panel scrolling")
        app.buttons["mobile.controls.click"].firstMatch.tap()
        XCTAssertEqual(pointers(),moved+2)
        let screenshot=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); screenshot.name="control-pad-mouse"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testLargeTextControlPadRemainsScrollableAndTouchable() throws {
        continueAfterFailure=false
        let app=XCUIApplication(bundleIdentifier:"org.github.aetherkiri.host.ios")
        app.launchEnvironment["AETHER_HOST_BYPASS_LEGAL_GATE"]="1"
        app.launchArguments=["--ios-settings-preview","--ios-demo-smoke","-UIPreferredContentSizeCategoryName",UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launch(); defer {app.terminate()}
        let toggle=app.buttons["mobile.controls.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout:15)); toggle.tap()
        let canvas=app.images["mobile.game.canvas"].firstMatch
        XCTAssertTrue(canvas.label.contains(UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue),canvas.label)
        let ctrl=app.buttons["mobile.controls.ctrl"].firstMatch
        let pad=app.descendants(matching:.any)["mobile.controls.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout:5))
        for _ in 0..<10 {
            if ctrl.exists && ctrl.isHittable && pad.frame.contains(ctrl.frame) {break}
            pad.swipeUp()
        }
        XCTAssertTrue(ctrl.isHittable)
        XCTAssertGreaterThanOrEqual(ctrl.frame.height,44); XCTAssertGreaterThanOrEqual(ctrl.frame.width,44)
        ctrl.tap(); XCTAssertTrue(ctrl.isSelected,"canvas=\(canvas.value ?? "nil") frame=\(ctrl.frame) viewport=\(pad.frame)")
        let capture=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); capture.name="control-pad-large-text"; capture.lifetime = .keepAlways; add(capture)
        toggle.tap()
        XCTAssertFalse(ctrl.exists)
    }

}
