import Combine
import CoreGraphics
import Foundation

struct RuntimeMovieRequest {
    let url: URL
    let rectangle: CGRect
    let skippable: Bool
    init(_ argument: String) throws {
        let fields = argument.components(separatedBy: "\t")
        guard fields.count == 6, fields[0].hasPrefix("/"), !fields[0].contains("\0"),
              let width = Int32(fields[1]), let height = Int32(fields[2]),
              width > 0, height > 0, width <= 16384, height <= 16384,
              let x = Int32(fields[3]), let y = Int32(fields[4]), ["0", "1"].contains(fields[5]) else {
            throw NSError(domain: "AetherRuntimeMovie", code: -1, userInfo: [NSLocalizedDescriptionKey: "Malformed minori_movie request."])
        }
        url = URL(fileURLWithPath: fields[0])
        rectangle = CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
        skippable = fields[5] == "1"
    }
    func displayRectangle(canvas: CGSize, viewport: CGSize) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(viewport.width / canvas.width, viewport.height / canvas.height)
        return CGRect(x: (viewport.width - canvas.width * scale) / 2 + rectangle.minX * scale,
                      y: (viewport.height - canvas.height * scale) / 2 + rectangle.minY * scale,
                      width: rectangle.width * scale, height: rectangle.height * scale)
    }
}

// A skip press must not leak its release or auto-repeat into the resumed script.
struct RuntimeMovieInputState {
    private var buttons: Set<Int32> = []
    private var keys: Set<Int32> = []
    mutating func consumePointer(type: UInt32, button: Int32, movieActive: Bool) -> Bool {
        if type == UInt32(ENGINE_INPUT_EVENT_POINTER_UP.rawValue), buttons.remove(button) != nil { return true }
        if !buttons.isEmpty, type == UInt32(ENGINE_INPUT_EVENT_POINTER_MOVE.rawValue) { return true }
        if movieActive {
            if type == UInt32(ENGINE_INPUT_EVENT_POINTER_DOWN.rawValue) { buttons.insert(button) }
            return true
        }
        return false
    }
    mutating func consumeKey(pressed: Bool, key: Int32, movieActive: Bool) -> Bool {
        if !pressed, keys.remove(key) != nil { return true }
        if pressed, keys.contains(key) { return true }
        if movieActive {
            if pressed { keys.insert(key) }
            return true
        }
        return false
    }
    mutating func reset() { buttons.removeAll(); keys.removeAll() }
}

// Owned by the game controller. A borrowed engine must outlive this media session.
@MainActor
final class RuntimeMovieController: ObservableObject {
    @Published private(set) var request: RuntimeMovieRequest?
    @Published private(set) var frame: CGImage?
    private let media = MediaSession()
    private var active = false
    var isActive: Bool { active }
    var submit: (String) throws -> Void = { _ in }
    var activityChanged: (Bool) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    var failure: (String) -> Void = { _ in }

    func open(_ argument: String, engine: engine_handle_t) {
        guard !active else { log("overlapping minori_movie request ignored"); return }
        do {
            let request = try RuntimeMovieRequest(argument)
            // Install state before open: all failures receive one error response.
            active = true; self.request = request; activityChanged(true)
            try media.open(request.url, borrowing: engine)
            try media.play()
            log("runtime movie started (skippable=\(request.skippable))")
        } catch {
            active = true
            finish("result=error&message=media_playback_failed", error: error.localizedDescription)
        }
    }
    func update() {
        guard active else { return }
        do {
            let state = try media.state()
            if state.status == UInt32(ENGINE_MEDIA_STATUS_ERROR.rawValue) {
                finish("result=error&message=media_playback_failed", error: "Runtime movie playback failed.")
            } else if state.status == UInt32(ENGINE_MEDIA_STATUS_ENDED.rawValue) {
                finish("result=complete")
            } else if let frame = try media.frame(state) { self.frame = frame }
        } catch { finish("result=error&message=media_playback_failed", error: error.localizedDescription) }
    }
    func skip() {
        guard active, request?.skippable == true else { return }
        finish("result=skipped")
    }
    private func finish(_ response: String, error: String? = nil) {
        guard active else { return }
        // The provider deletes its cache on completion. Release decoder/file first.
        active = false; media.close(); frame = nil; request = nil
        var message = error
        do { try submit(response); log("runtime movie response sent: \(response)") }
        catch { log("runtime movie response rejected: \(error.localizedDescription)"); message = message ?? error.localizedDescription }
        activityChanged(false)
        if let message { log("runtime movie failed: \(message)"); failure(message) }
    }
    func reset() {
        active = false; media.close(); frame = nil; request = nil
        // A closing game is not a movie completion; never reply to the next session.
        activityChanged(false)
    }
}
