import Foundation
import CoreGraphics

@main
struct MediaControllerTests {
    @MainActor static func main() throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        let evidence = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = evidence.appendingPathComponent("controller-library")
        let movie = evidence.appendingPathComponent("fixtures/sample.mkv")
        let diagnostics = DiagnosticStore(root: root.appendingPathComponent("Diagnostics"))
        let controller = MediaController(root: root, diagnostics: diagnostics, log: { print($0) })
        defer { controller.close() }
        check(controller.open(movie), "open")
        controller.setVolume(0)
        pump(1)
        check(controller.frame != nil && controller.subtitleText.contains("你好世界"), "frame and external caption")
        controller.togglePlayback()
        pump(0.25)
        let paused = controller.position
        pump(0.25)
        check(!controller.playing && abs(controller.position - paused) < 0.12, "pause")
        controller.setRate(2)
        pump(0.2)
        check(!controller.playing && controller.rate == 2, "rate preserves pause")
        let embedded = controller.subtitles.first { $0.stream != nil }!
        controller.selectSubtitle(embedded.id)
        check(controller.subtitleText.contains("你好世界"), "embedded caption")
        controller.seek(to: 7)
        pump(0.6)
        check(!controller.playing && controller.position > 6 && controller.position < 8, "paused seek")
        check(controller.subtitleText.contains("Second caption"), "caption follows seek")
        controller.selectSubtitle("off")
        check(controller.subtitleText.isEmpty, "caption off")
        controller.selectSubtitle(embedded.id)
        controller.close()
        let saved = try MediaProgressStore(url: root.appendingPathComponent("media-progress.json")).position(for: movie, duration: 18)
        check(saved > 6 && saved < 8, "saved progress")
        let entry = try MediaProgressStore(url: root.appendingPathComponent("media-progress.json")).entries()[movie.standardizedFileURL.path]
        check(abs((entry?.duration ?? 0) - 18) < 0.1, "measured duration persisted for library progress")
        check(controller.frame == nil && controller.subtitles.isEmpty, "close releases presentation")
        check(controller.open(movie), "reopen")
        controller.setVolume(0)
        pump(0.3)
        check(controller.position >= 6 && controller.position < 9, "resume progress")
        check(controller.selectedSubtitle == embedded.id, "subtitle selection restore")
        controller.setRate(2)
        controller.seek(to: 17)
        pump(3)
        check(controller.ended && !controller.playing && controller.position == controller.duration, "end position")
        check(try MediaProgressStore(url: root.appendingPathComponent("media-progress.json")).position(for: movie, duration: 18) == 0, "ended clears resume")
        controller.togglePlayback()
        pump(0.3)
        check(controller.playing && !controller.ended && controller.position < 3 && controller.rate == 2, "replay keeps rate")
        controller.close(); controller.close()
        try MediaProgressStore(url: root.appendingPathComponent("media-progress.json")).save(5, for: movie)
        try MediaProgressStore(url: root.appendingPathComponent("media-progress.json")).remove(for: movie)
        check(try MediaProgressStore(url: root.appendingPathComponent("media-progress.json")).position(for: movie, duration: 18) == 0, "remove progress")
        check(!controller.open(evidence.appendingPathComponent("fixtures/bad.mp4")), "bad file failure")
        check(controller.failureMessage != nil && diagnostics.metadata["state"] == "failed", "failure retained")
        check(controller.open(movie), "recovery after failed open")
        controller.close()
        check(diagnostics.metadata["state"] == "stopped" && diagnostics.metadata["error"] == nil, "session reset")
        print("MediaController PASS: captions, pause/rate, paused seek, subtitle off, progress/reopen, EOF/replay, cleanup, failed-open recovery")
    }
}
