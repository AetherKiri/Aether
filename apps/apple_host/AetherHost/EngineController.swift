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
    @Published var tickCount: UInt64 = 0

    private let session = AetherEngineSession()
    private var timer: Timer?
    private var lastStartupState: UInt32 = 0
    private(set) var loopRunning = false

    func log(_ line: String) {
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
            if tickCount % 300 == 0 {
                log("frame presented (tick \(tickCount))")
            }
        }
    }

    func autorunIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["AETHER_HOST_AUTORUN"] == "1" else { return }
        log("AUTORUN: initializing engine")
        initializeEngine()
        let path = env["AETHER_HOST_GAME_PATH"] ?? Self.defaultGamePath
        log("AUTORUN: opening \(path)")
        openAndRun(gamePath: path)
        if let raw = env["AETHER_HOST_EXIT_AFTER"], let seconds = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                self.log("AUTORUN: exit after \(seconds)s")
                self.shutdown()
                NSApp.terminate(nil)
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
