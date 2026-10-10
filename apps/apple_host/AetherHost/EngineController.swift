import AppKit
import CoreGraphics
import SwiftUI

// M0 host controller: engine lifecycle + fixed-step tick loop + software frame
// readback. GPU bridge (Metal) presentation replaces the readback in M1; keep
// this class small and move rendering into MetalPresenter at that point.
@MainActor
final class EngineController: ObservableObject {
    @Published var status = "未初始化"
    @Published var logText = ""
    @Published var frameImage: CGImage?
    @Published var frameSize: CGSize = .zero
    @Published var tickCount: UInt64 = 0

    private let session = AetherEngineSession()
    private var timer: Timer?
    private var lastStartupState: UInt32 = 0
    private var pointerEventCount = 0
    private var keyEventCount = 0
    private var appliedSurfaceSize: CGSize = .zero
    private(set) var loopRunning = false

    func log(_ line: String) {
        print("[host] \(line)")
        logText += line + "\n"
        if logText.count > 12000 {
            logText.removeFirst(logText.count - 12000)
        }
    }

    func initializeEngine() {
        do {
            let fm = FileManager.default
            let support = try fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Aether", isDirectory: true)
            let cache = try fm.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Aether", isDirectory: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)

            try session.initialize(
                writablePath: support.path, cachePath: cache.path)
            // M0 baseline: software renderer feeds engine_read_frame_rgba.
            try session.setOption("renderer", value: "software")
            // Disables engine console.log writes (engine DebugIntf path).
            // NOTE: the sidecar krkr2.log beside the game root attaches
            // unconditionally in engine_open_game; same behavior as the Godot
            // host (games live in managed copies there). Parity accepted.
            try session.setOption("console_log_file", value: "0")
            status = "引擎已创建 (api v\(session.engineAPIVersion()))"
            log("engine_create OK, renderer=software, api=\(session.engineAPIVersion())")
        } catch {
            status = "初始化失败"
            log("initialize failed: \(error.localizedDescription)")
        }
    }

    func openAndRun(gamePath: String) {
        guard !gamePath.isEmpty else {
            log("game path is empty")
            return
        }
        do {
            try session.openGame(atPath: gamePath)
            log("engine_open_game: \(gamePath)")
            status = "启动中…"
            startLoop()
        } catch {
            log("open failed: \(error.localizedDescription)")
        }
    }

    func startLoop() {
        guard !loopRunning else { return }
        loopRunning = true
        // TODO(M1): CVDisplayLink / CADisplayLink pacing; Timer is the M0 smoke.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.step()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log("tick loop started (60 Hz timer)")
    }

    func stopLoop() {
        timer?.invalidate()
        timer = nil
        loopRunning = false
        log("tick loop stopped")
    }

    private func step() {
        // Fixed step mirrors the Godot host (main.gd passes 1/60).
        session.tick(deltaMS: 16)
        tickCount += 1

        session.pollPlatformRequests { [weak self] operation, argument in
            guard let self else { return }
            if operation == "open_browser", let url = URL(string: argument) {
                NSWorkspace.shared.open(url)
            } else if operation == "text_input" {
                self.log("platform_request text_input (M0: not handled)")
            } else {
                let preview = argument.count > 96
                    ? String(argument.prefix(96)) + "…"
                    : argument
                self.log("platform_request: \(operation) \(preview)")
            }
        }

        let state = session.startupState()
        if state != lastStartupState {
            lastStartupState = state
            switch state {
            case 1:
                log("startup state: RUNNING")
            case 2:
                status = "运行中"
                log("startup state: SUCCEEDED")
            case 3:
                status = "启动失败"
                log("startup state: FAILED — check engine log output")
            default:
                break
            }
        }

        if let image = session.copyFrameImage() {
            frameImage = image
            let size = session.framePixelSize()
            if size.width > 0, size != frameSize {
                frameSize = size
                log("frame size \(Int(size.width))x\(Int(size.height))")
            }
            // Game Native surface mode: the presentation canvas AND the
            // pointer coordinate space must match the game frame. The engine
            // default surface is 1280x720, which letterboxes a 640x480 game
            // and makes frame-space input land in the wrong place.
            if size.width > 0, size != appliedSurfaceSize {
                do {
                    try session.setSurfaceSize(
                        width: UInt32(size.width), height: UInt32(size.height))
                    appliedSurfaceSize = size
                    log("surface size -> \(Int(size.width))x\(Int(size.height)) (game native)")
                } catch {
                    log("setSurfaceSize failed: \(error.localizedDescription)")
                }
            }
            if tickCount % 300 == 0 {
                log("frame presented (tick \(tickCount))")
            }
        }
    }

    // Saves the current engine frame as PNG (env AETHER_HOST_CAPTURE_AFTER).
    private func saveFrameSnapshot(tag: String) {
        guard let image = frameImage else {
            log("capture \(tag): no frame yet")
            return
        }
        let dir = ProcessInfo.processInfo.environment["AETHER_HOST_CAPTURE_DIR"]
            ?? NSTemporaryDirectory()
        let path = "\(dir)/aetherhost-frame-\(tag).png"
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            log("capture \(tag): PNG encode failed")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            log("capture saved: \(path)")
        } catch {
            log("capture \(tag) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Input forwarding (see InputMapping for translation rules)

    func sendPointer(
        type: UInt32, x: Double, y: Double, dx: Double, dy: Double,
        button: Int32, modifiers: Int32
    ) {
        pointerEventCount += 1
        if pointerEventCount <= 12 {
            log("input pointer type=\(type) at (\(Int(x)),\(Int(y))) btn=\(button) mods=\(modifiers)")
        }
        session.sendPointer(
            type: type, pointerId: 0, x: x, y: y, deltaX: dx, deltaY: dy,
            button: button, modifiers: modifiers)
    }

    func sendKey(
        pressed: Bool, keyCode: Int32, modifiers: Int32, unicode: UInt32
    ) {
        keyEventCount += 1
        if keyEventCount <= 12 {
            log("input key \(pressed ? "down" : "up") vk=0x\(String(keyCode, radix: 16)) unicode=\(unicode) mods=\(modifiers)")
        }
        session.sendKey(
            pressed: pressed, keyCode: keyCode, modifiers: modifiers,
            unicode: unicode)
    }

    func autorunIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["AETHER_HOST_AUTORUN"] == "1" else { return }
        log("AUTORUN: initializing engine")
        initializeEngine()
        let path = env["AETHER_HOST_GAME_PATH"] ?? Self.defaultGamePath
        log("AUTORUN: opening \(path)")
        openAndRun(gamePath: path)
        if let raw = env["AETHER_HOST_TEST_INPUT"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.runTestInputSequence()
            }
        }
        // Deterministic frame evidence for CI: comma-separated seconds after
        // autorun start; each saves the engine frame as PNG.
        if let raw = env["AETHER_HOST_CAPTURE_AFTER"] {
            for piece in raw.split(separator: ",") {
                guard let seconds = Double(piece.trimmingCharacters(in: .whitespaces)) else {
                    continue
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    self.saveFrameSnapshot(tag: piece.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        if let raw = env["AETHER_HOST_EXIT_AFTER"], let seconds = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                self.log("AUTORUN: exit after \(seconds)s")
                self.shutdown()
                NSApp.terminate(nil)
            }
        }
    }

    // Deterministic smoke input: move -> click -> Return through the same
    // send* entry points the AppKit view uses (env AETHER_HOST_TEST_INPUT).
    private func runTestInputSequence() {        guard loopRunning else {
            log("TEST INPUT: loop not running, skipping")
            return
        }
        let center = CGPoint(
            x: frameSize.width / 2, y: frameSize.height / 2)
        log("TEST INPUT: pointer move -> down -> up at (\(Int(center.x)),\(Int(center.y)))")
        sendPointer(
            type: EngineInputEvent.pointerMove,
            x: Double(center.x), y: Double(center.y), dx: 0, dy: 0,
            button: 0, modifiers: 0)
        sendPointer(
            type: EngineInputEvent.pointerDown,
            x: Double(center.x), y: Double(center.y), dx: 0, dy: 0,
            button: 0, modifiers: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.sendPointer(
                type: EngineInputEvent.pointerUp,
                x: Double(center.x), y: Double(center.y), dx: 0, dy: 0,
                button: 0, modifiers: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.log("TEST INPUT: Return key down/up")
            self.sendKey(
                pressed: true, keyCode: 0x0D, modifiers: 0, unicode: 0x0D)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.sendKey(
                    pressed: false, keyCode: 0x0D, modifiers: 0, unicode: 0)
            }
        }
    }

    static var defaultGamePath: String {
        if let env = ProcessInfo.processInfo.environment["AETHER_HOST_GAME_PATH"],
           !env.isEmpty {
            return env
        }
        // Dev default: the KAG3 demo data directory in this repository.
        return "/Users/colorcard/Aether/demos/aetherkiri-kag3/data"
    }

    func shutdown() {
        stopLoop()
        session.shutdown()
        status = "已关闭"
        log("engine destroyed")
    }
}
