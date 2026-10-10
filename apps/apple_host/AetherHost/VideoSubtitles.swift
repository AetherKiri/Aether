import Foundation

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

struct SubtitleTimeline {
    let cues: [SubtitleCue]
    private let maximumEnds: [Double]
    init(_ cues: [SubtitleCue] = []) {
        self.cues = cues.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        var maximum = 0.0
        maximumEnds = self.cues.map { maximum = max(maximum, $0.end); return maximum }
    }
    func text(at seconds: Double) -> String {
        guard seconds.isFinite else { return "" }
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= seconds { low = mid + 1 } else { high = mid }
        }
        let end = low
        low = 0; high = end
        while low < high {
            let mid = (low + high) / 2
            if maximumEnds[mid] <= seconds { low = mid + 1 } else { high = mid }
        }
        var texts: [String] = []
        for cue in cues[low..<end] where cue.end > seconds {
            if !texts.contains(cue.text) { texts.append(cue.text) }
        }
        return texts.joined(separator: "\n")
    }
}

enum VideoSubtitles {
    static func load(_ url: URL) throws -> SubtitleTimeline {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return parse(text, extension: url.pathExtension)
    }

    static func parse(_ input: String, extension ext: String) -> SubtitleTimeline {
        let text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        var cues: [SubtitleCue] = []
        func add(_ start: String, _ end: String, _ body: String, ass: Bool) {
            guard let a = time(start), let b = time(end), b > a else { return }
            var cleaned = body.replacingOccurrences(of: ass ? "\\{[^}]*\\}" : "<[^>]+>", with: "", options: .regularExpression)
            if ass { cleaned = cleaned.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ") }
            for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&amp;", "&")] {
                cleaned = cleaned.replacingOccurrences(of: entity, with: value)
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: a, end: b, text: cleaned)) }
        }
        if ["ass", "ssa"].contains(ext.lowercased()) {
            var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
            var inEvents = false
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
                guard inEvents else { continue }
                if line.lowercased().hasPrefix("format:") {
                    fields = line.dropFirst(7).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if line.lowercased().hasPrefix("dialogue:"), fields.last == "text",
                          let start = fields.firstIndex(of: "start"), let end = fields.firstIndex(of: "end") {
                    let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
                    if values.count == fields.count { add(String(values[start]), String(values[end]), String(values.last!), ass: true) }
                }
            }
        } else {
            for block in text.components(separatedBy: "\n\n") {
                let lines = block.components(separatedBy: "\n")
                let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                if first.hasPrefix("NOTE") || first == "STYLE" || first == "REGION" { continue }
                guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
                let timing = lines[index].components(separatedBy: "-->")
                guard timing.count == 2, let end = timing[1].split(whereSeparator: \.isWhitespace).first else { continue }
                add(timing[0], String(end), lines.dropFirst(index + 1).joined(separator: "\n"), ass: false)
            }
        }
        return SubtitleTimeline(cues)
    }

    private static func time(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let values = parts.compactMap(Double.init)
        guard values.count == parts.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.last! < 60, (values.count == 2 || values[1] < 60) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }
}
