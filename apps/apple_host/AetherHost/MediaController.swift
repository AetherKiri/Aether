import AppKit
import SwiftUI

struct MediaSubtitleOption: Identifiable {
    let id: String
    let label: String
    let file: URL?
    let stream: Int32?
}

@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var frame: CGImage?
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var playing = false
    @Published private(set) var ended = false
    @Published private(set) var seekable = false
    @Published private(set) var rate = 1.0
    @Published private(set) var volume = 1.0
    @Published private(set) var subtitleText = ""
    @Published private(set) var subtitles: [MediaSubtitleOption] = []
    @Published private(set) var selectedSubtitle = "off"
    @Published var failureMessage: String?
    @Published var subtitleError: String?
    private let session = MediaSession()
    private let root: URL
    private let diagnostics: DiagnosticStore
    private let log: (String) -> Void
    private let progress: MediaProgressStore
    private var file: URL?
    private var timer: Timer?
    private var timeline = SubtitleTimeline()
    private var extractionDirectory: URL?
    private var lastSaved = 0.0
    private var previousStatus: UInt32?

    init(root: URL, diagnostics: DiagnosticStore, log: @escaping (String) -> Void) {
        self.root = root; self.diagnostics = diagnostics; self.log = log
        progress = MediaProgressStore(url: root.appendingPathComponent("media-progress.json"))
    }
    private func record(_ values: [String: String], newSession: Bool = false) {
        do { try diagnostics.update(values, newSession: newSession) }
        catch { log("media diagnostics write failed: \(error.localizedDescription)") }
    }
    @discardableResult
    func open(_ url: URL) -> Bool {
        close()
        failureMessage = nil; subtitleError = nil
        file = url; position = 0; duration = 0; rate = 1; volume = 1; ended = false
        previousStatus = nil; lastSaved = ProcessInfo.processInfo.systemUptime
        record(["kind": "video", "mediaPath": url.path, "state": "opening"], newSession: true)
        log("media_open: \(url.path)")
        do {
            let cache = root.appendingPathComponent("MediaCache", isDirectory: true)
            try session.open(url, writable: root, cache: cache)
            let state = try session.state()
            guard state.has_video != 0 else { throw NSError(domain: "AetherMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file has no video stream."]) }
            duration = max(0, Double(state.duration_ms) / 1000)
            seekable = state.seekable != 0
            let tracks = try session.subtitleTracks()
            subtitles = ["srt", "vtt", "ass", "ssa"].compactMap { ext in
                let path = url.deletingPathExtension().appendingPathExtension(ext)
                return FileManager.default.fileExists(atPath: path.path)
                    ? MediaSubtitleOption(id: path.path, label: path.lastPathComponent, file: path, stream: nil) : nil
            }
            subtitles += tracks.map {
                MediaSubtitleOption(id: "embedded:\($0.stream_index)",
                                    label: "\($0.title.isEmpty ? $0.language : $0.title) [\($0.codec) #\($0.stream_index)]",
                                    file: nil, stream: $0.stream_index)
            }
            extractionDirectory = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            if let choice = subtitles.first(where: { $0.file != nil })
                ?? subtitles.first(where: { option in tracks.contains { $0.default && $0.stream_index == option.stream } }) {
                selectSubtitle(choice.id)
            }
            if seekable {
                do {
                    let resume = try progress.position(for: url, duration: duration)
                    if resume > 0 { try session.seek(resume); position = resume; log("media resume at \(resume)s") }
                } catch { log("media progress restore failed: \(error.localizedDescription)") }
            }
            try session.play()
            record(["state": "playing", "duration": String(duration), "hasAudio": String(state.has_audio != 0)])
            refresh()
            guard failureMessage == nil else { close(); return false }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            return true
        } catch {
            fail(error)
            close()
            return false
        }
    }
    private func fail(_ error: Error) {
        timer?.invalidate(); timer = nil
        failureMessage = error.localizedDescription
        record(["state": "failed", "error": error.localizedDescription])
        log("media failed: \(error.localizedDescription)")
    }
    func refresh() {
        guard file != nil, failureMessage == nil else { return }
        do {
            let state = try session.state()
            position = max(0, Double(state.position_ms) / 1000)
            duration = max(0, Double(state.duration_ms) / 1000)
            seekable = state.seekable != 0
            playing = state.status == 1
            ended = state.status == 3
            if ended { position = duration }
            if let image = try session.frame(state) { frame = image }
            subtitleText = ended ? "" : timeline.text(at: position)
            if previousStatus != state.status {
                previousStatus = state.status
                record(["state": ended ? "ended" : playing ? "playing" : "paused", "position": String(position)])
                log("media state=\(state.status) position=\(String(format: "%.2f", position)) frame=\(state.width)x\(state.height)")
                if ended { saveProgress() }
            }
            if ProcessInfo.processInfo.systemUptime - lastSaved >= 5 { saveProgress() }
        } catch { fail(error) }
    }
    func togglePlayback() {
        guard file != nil else { return }
        do {
            if playing { try session.pause() }
            else {
                if ended { try session.seek(0) }
                try session.play()
                try session.setRate(rate)
            }
            refresh(); saveProgress()
        } catch { fail(error) }
    }
    func seek(to seconds: Double) {
        guard seekable else { return }
        do {
            let wasPlaying = playing
            try session.seek(max(0, min(duration, seconds)))
            // Seeking away from EOF clears the ended latch when playback resumes.
            if ended { try session.play(); if !wasPlaying { try session.pause() } }
            refresh(); saveProgress()
            log("media seek -> \(String(format: "%.2f", position))s")
        } catch { fail(error) }
    }
    func setRate(_ value: Double) {
        do {
            let wasPlaying = playing
            try session.setRate(value)
            if !wasPlaying { try session.pause() }
            rate = value
            refresh()
            log("media rate=\(value)")
        }
        catch { fail(error) }
    }
    func setVolume(_ value: Double) {
        do { try session.setVolume(value); volume = value }
        catch { fail(error) }
    }
    func selectSubtitle(_ id: String) {
        selectedSubtitle = id; timeline = SubtitleTimeline(); subtitleText = ""
        guard id != "off", let option = subtitles.first(where: { $0.id == id }) else { return }
        do {
            let url: URL
            if let path = option.file { url = path }
            else if let index = option.stream, let directory = extractionDirectory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                url = directory.appendingPathComponent("\(index).ass")
                try session.extractSubtitle(index, to: url)
            } else { return }
            timeline = try VideoSubtitles.load(url)
            subtitleText = timeline.text(at: position)
            log("media subtitle selected: \(id), cues=\(timeline.cues.count)")
        } catch {
            selectedSubtitle = "off"
            subtitleError = error.localizedDescription
            log("media subtitle failed: \(error.localizedDescription)")
        }
    }
    private func saveProgress() {
        guard let file else { return }
        lastSaved = ProcessInfo.processInfo.systemUptime
        do { try progress.save(ended ? 0 : position, for: file) }
        catch { log("media progress save failed: \(error.localizedDescription)") }
    }
    func close() {
        timer?.invalidate(); timer = nil
        if file != nil {
            if failureMessage == nil { saveProgress() }
            record(["state": failureMessage == nil ? "stopped" : "failed",
                    "closed": ISO8601DateFormatter().string(from: Date()), "position": String(position)])
            log("media closed")
        }
        session.close()
        if let directory = extractionDirectory { try? FileManager.default.removeItem(at: directory) }
        extractionDirectory = nil; file = nil; frame = nil; playing = false
        timeline = SubtitleTimeline(); subtitles = []; selectedSubtitle = "off"; subtitleText = ""
    }
}
