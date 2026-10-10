import Foundation
import CoreGraphics

struct EmbeddedSubtitleTrack: Decodable {
    let stream_index: Int32
    let language: String
    let title: String
    let codec: String
    let `default`: Bool
}

// Call exclusively on the owner/main thread, matching the engine lifecycle ABI.
final class MediaSession {
    private var engine: engine_handle_t?
    private var media: engine_media_handle_t?
    private var lastSerial: UInt64?
    private var pixels = Data()

    private func check(_ result: engine_result_t, _ operation: String) throws {
        guard result != ENGINE_RESULT_OK else { return }
        let detail = engine_get_last_error(engine).map { String(cString: $0) } ?? ""
        throw NSError(domain: "AetherMedia", code: Int(result.rawValue),
                      userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "\(operation) failed (\(result.rawValue))" : detail])
    }
    func open(_ url: URL, writable: URL, cache: URL) throws {
        close()
        do {
            try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            var desc = engine_create_desc_t()
            desc.struct_size = UInt32(MemoryLayout<engine_create_desc_t>.size)
            desc.api_version = ENGINE_API_VERSION
            try writable.path.withCString { writePath in
                try cache.path.withCString { cachePath in
                    desc.writable_path_utf8 = writePath; desc.cache_path_utf8 = cachePath
                    try check(engine_create(&desc, &engine), "create media engine")
                }
            }
            try url.path.withCString { try check(engine_media_open(engine, $0, &media), "open video") }
            guard try state().has_video != 0 else {
                throw NSError(domain: "AetherMedia", code: -4, userInfo: [NSLocalizedDescriptionKey: "This file has no playable video stream."])
            }
        } catch { close(); throw error }
    }
    func play() throws { try check(engine_media_play(media), "play") }
    func pause() throws { try check(engine_media_pause(media), "pause") }
    func seek(_ seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1000 else { throw NSError(domain: "AetherMedia", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid seek position."]) }
        try check(engine_media_seek(media, Int64(seconds * 1000)), "seek")
        lastSerial = nil
    }
    func setRate(_ rate: Double) throws { try check(engine_media_set_rate(media, rate), "rate") }
    func setVolume(_ volume: Double) throws { try check(engine_media_set_volume(media, volume), "volume") }
    func state() throws -> engine_media_state_t {
        var state = engine_media_state_t()
        state.struct_size = UInt32(MemoryLayout<engine_media_state_t>.size)
        try check(engine_media_get_state(media, &state), "media state")
        return state
    }
    func frame(_ state: engine_media_state_t) throws -> CGImage? {
        guard state.frame_ready != 0, state.width > 0, state.height > 0,
              state.frame_serial != lastSerial else { return nil }
        let width = Int(state.width), height = Int(state.height)
        guard width <= 8192, height <= 8192, width * height <= 33_554_432 else { throw CocoaError(.fileReadTooLarge) }
        let size = width * height * 4
        if pixels.count != size { pixels = Data(count: size) }
        var desc = engine_frame_desc_t()
        desc.struct_size = UInt32(MemoryLayout<engine_frame_desc_t>.size)
        try pixels.withUnsafeMutableBytes { buffer in
            try check(engine_media_read_frame_rgba(media, buffer.baseAddress, buffer.count, &desc), "media frame")
        }
        guard desc.width == state.width, desc.height == state.height else { return nil }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw CocoaError(.fileReadUnknown)
        }
        lastSerial = desc.frame_serial
        return image
    }
    func subtitleTracks() throws -> [EmbeddedSubtitleTrack] {
        var bytes = [CChar](repeating: 0, count: 65536)
        var written: UInt32 = 0
        try check(engine_media_get_subtitle_tracks_json(media, &bytes, UInt32(bytes.count), &written), "subtitle tracks")
        return try JSONDecoder().decode([EmbeddedSubtitleTrack].self, from: Data(bytes: bytes, count: Int(written)))
    }
    func extractSubtitle(_ index: Int32, to url: URL) throws {
        try url.path.withCString { try check(engine_media_extract_subtitle(media, index, $0), "extract subtitle") }
    }
    func close() {
        if let media { engine_media_destroy(media) }
        media = nil
        if let engine { engine_destroy(engine) }
        engine = nil
        lastSerial = nil; pixels = Data()
    }
    deinit { close() }
}
