import Foundation

@main
struct VideoSubtitlesTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value) }
        let srt = VideoSubtitles.parse("\u{FEFF}1\r\n00:00:01,000 --> 00:00:04,000\r\n<b>中文</b> &amp; 日本語\r\n\r\n2\r\n00:00:02,000 --> 00:00:03,000\r\nOverlap\r\n", extension: "srt")
        check(srt.text(at: 0).isEmpty)
        check(srt.text(at: 2) == "中文 & 日本語\nOverlap")
        check(srt.text(at: 3) == "中文 & 日本語")
        check(srt.text(at: 4).isEmpty)
        check(srt.text(at: 1.5) == "中文 & 日本語")
        let ass = VideoSubtitles.parse("""
        [Script Info]
        Title: test
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\\b1}中文\\N日本語, comma
        Dialogue: 0,0:00:01.00,0:00:06.00,Default,,0,0,0,,Long
        Dialogue: 0,0:00:03.00,0:00:05.00,Default,,0,0,0,,Overlap
        """, extension: "ass")
        check(ass.text(at: 3.5) == "Long\n中文\n日本語, comma\nOverlap")
        check(ass.text(at: 5.5) == "Long")
        check(ass.text(at: 1.5) == "Long")
        let vtt = VideoSubtitles.parse("""
        WEBVTT

        NOTE do not show
        00:00.000 --> 00:03.000
        hidden

        cue-name
        00:01.000 --> 00:02.500 align:start
        <v Alice>Hello &lt;world&gt;

        90:00.000 --> 90:01.000
        Long video
        """, extension: "vtt")
        check(vtt.text(at: 1) == "Hello <world>")
        check(vtt.text(at: 5400) == "Long video")
        let invalid = VideoSubtitles.parse("1\n00:xx:00 --> 00:00:03\nBad\n\n2\n00:00:04 --> 00:00:02\nBackwards\n\n3\n00:00:60 --> 00:01:05\nBad seconds", extension: "srt")
        check(invalid.cues.isEmpty)
        let duplicates = SubtitleTimeline([SubtitleCue(start: 0, end: 5, text: "A"), SubtitleCue(start: 0, end: 5, text: "A")])
        check(duplicates.text(at: 2) == "A" && duplicates.text(at: .nan).isEmpty)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aether-media-progress-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = MediaProgressStore(url: temp.appendingPathComponent("progress.json"))
        let file = temp.appendingPathComponent("video.mkv")
        try store.save(5.5, for: file)
        check(try store.position(for: file, duration: 18) == 5.5)
        check(try store.position(for: file, duration: 5) == 0)
        try store.save(0, for: file)
        check(try store.position(for: file, duration: 18) == 0)
        // Corrupt history is preserved rather than silently overwriting it.
        try Data("invalid json".utf8).write(to: store.url)
        do { try store.save(3, for: file); fatalError("corrupt history overwritten") } catch {}
        check(try String(contentsOf: store.url, encoding: .utf8) == "invalid json")
        print("Subtitles/progress PASS: Unicode, markup, overlaps, backward seek, cue boundaries, ASS commas, VTT notes/settings, malformed times, deduplication, restore/end reset, corrupt history")
    }
}
