import Foundation
import XCTest

// Drive the already installed Godot app through the actual Simulator UI.
// The host exchanges commands only through this test runner's own Documents
// directory; game checkpoints and provider frames are independently observed.
final class RenPyGameplayTests: XCTestCase {
    func testCloudGameplay() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let runID = try XCTUnwrap(environment["AETHER_RENPY_RUN_ID"])
        let bundleID = try XCTUnwrap(environment["AETHER_RENPY_APP_BUNDLE_ID"])
        let timeout = Double(environment["AETHER_RENPY_TEST_TIMEOUT"] ?? "600") ?? 600
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let root = documents.appendingPathComponent("aether-renpy-ui-" + runID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = XCUIApplication(bundleIdentifier: bundleID)
        if app.state != .runningForeground {
            app.launch()
        }
        XCTAssertEqual(app.state, .runningForeground, "The installed app must launch on the Simulator")
        try write(["run_id": runID, "bundle_id": bundleID, "ready": true], to: root.appendingPathComponent("ready.json"))
        let deadline = Date().addingTimeInterval(timeout)
        var previousSequence = 0
        while Date() < deadline {
            let commandURL = root.appendingPathComponent("command.json")
            guard let data = try? Data(contentsOf: commandURL),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  command["run_id"] as? String == runID,
                  let sequence = command["seq"] as? Int,
                  sequence > previousSequence else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            previousSequence = sequence
            let operation = command["op"] as? String ?? ""
            var acknowledgment: [String: Any] = ["run_id": runID, "seq": sequence, "op": operation]
            do {
                switch operation {
                case "tap":
                    XCTAssertEqual(app.state, .runningForeground)
                    let x = try XCTUnwrap(command["x"] as? Double)
                    let y = try XCTUnwrap(command["y"] as? Double)
                    XCTAssertTrue((0...1).contains(x) && (0...1).contains(y))
                    app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
                case "keyboard":
                    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "A real system software keyboard must be visible")
                    acknowledgment["keyboard_visible"] = app.keyboards.firstMatch.exists
                case "type":
                    XCTAssertTrue(app.keyboards.firstMatch.exists)
                    app.typeText(try XCTUnwrap(command["text"] as? String))
                case "home":
                    XCUIDevice.shared.press(.home)
                    let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        app.state == .runningBackground || app.state == .runningBackgroundSuspended
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 15), .completed)
                case "activate":
                    app.activate()
                    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
                case "foreground":
                    XCTAssertEqual(app.state, .runningForeground)
                case "finish":
                    acknowledgment["success"] = true
                    try write(acknowledgment, to: root.appendingPathComponent("ack.json"))
                    return
                default:
                    throw NSError(domain: "AetherRenPyUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown UI operation: " + operation])
                }
                let screenshot = XCUIScreen.main.screenshot()
                try screenshot.pngRepresentation.write(to: root.appendingPathComponent(String(sequence) + ".png"), options: .atomic)
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "RenPy " + operation + " " + String(sequence)
                attachment.lifetime = .keepAlways
                add(attachment)
                acknowledgment["success"] = true
                acknowledgment["app_state"] = app.state.rawValue
                try write(acknowledgment, to: root.appendingPathComponent("ack.json"))
            } catch {
                acknowledgment["success"] = false
                acknowledgment["error"] = String(describing: error)
                try? write(acknowledgment, to: root.appendingPathComponent("ack.json"))
                throw error
            }
        }
        XCTFail("Cloud gameplay command deadline expired without complete gameplay evidence")
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}
