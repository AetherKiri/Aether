import Foundation
import CoreGraphics

@main
struct MediaSessionTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let movie = root.appendingPathComponent("fixtures/sample.mkv")
        let session = MediaSession()
        defer { session.close() }
        try session.open(movie, writable: root.appendingPathComponent("test-support"), cache: root.appendingPathComponent("test-cache"))
        let initial = try session.state()
        check(initial.width == 320 && initial.height == 180 && initial.has_audio != 0 && initial.has_video != 0, "streams")
        let tracks = try session.subtitleTracks()
        check(tracks.count == 1 && tracks[0].language == "zho", "embedded track")
        let ass = root.appendingPathComponent("extracted.ass")
        try session.extractSubtitle(tracks[0].stream_index, to: ass)
        let subtitles = try VideoSubtitles.load(ass)
        check(subtitles.text(at: 2).contains("你好世界"), "embedded extraction")
        try session.setVolume(0)
        try session.play()
        var first: CGImage?
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let state = try session.state()
            if let image = try session.frame(state) { first = image }
            if first != nil && state.position_ms >= 600 { break }
            Thread.sleep(forTimeInterval: 0.03)
        }
        check(first != nil && first!.width == 320, "decoded frame")
        let firstBytes = first!.dataProvider!.data! as Data
        try session.pause()
        Thread.sleep(forTimeInterval: 0.2)
        let paused = try session.state().position_ms
        Thread.sleep(forTimeInterval: 0.25)
        print("Pause clock samples:", paused, try session.state().position_ms, "status", try session.state().status)
        check(abs(try session.state().position_ms - paused) < 120, "pause clock")
        let beforeSeekSerial = try session.state().frame_serial
        try session.seek(7)
        try session.play()
        var last: CGImage?
        let seekDeadline = Date().addingTimeInterval(2)
        while Date() < seekDeadline {
            let state = try session.state()
            if let frame = try session.frame(state) { last = frame }
            if state.position_ms >= 6500 && state.frame_serial > beforeSeekSerial && last != nil { break }
            Thread.sleep(forTimeInterval: 0.03)
        }
        check(last != nil && (last!.dataProvider!.data! as Data) != firstBytes, "seek changed frame")
        try session.setRate(2)
        check(try session.state().playback_rate == 2, "rate")
        try session.seek(16)
        let endDeadline = Date().addingTimeInterval(5)
        while try session.state().status != 3 && Date() < endDeadline { Thread.sleep(forTimeInterval: 0.03) }
        check(try session.state().status == 3, "end state")
        try session.seek(0)
        try session.play()
        check(try session.state().status == 1, "replay")
        session.close(); session.close()
        let bad = root.appendingPathComponent("fixtures/bad.mp4")
        try Data("not a video".utf8).write(to: bad)
        do { try session.open(bad, writable: root.appendingPathComponent("test-support"), cache: root.appendingPathComponent("test-cache")); fatalError("bad media accepted") }
        catch { print("Expected invalid-media error:", error.localizedDescription) }
        // A failed open must leave no handles behind and permit the next video.
        try session.open(movie, writable: root.appendingPathComponent("test-support"), cache: root.appendingPathComponent("test-cache"))
        check(try session.state().has_video != 0, "reopen after failure")
        print("MediaSession PASS: decode, audio stream, embedded subtitles, pause, seek, rate, EOF/replay, repeated close, failed-open recovery")
    }
}
