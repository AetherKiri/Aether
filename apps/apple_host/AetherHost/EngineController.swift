import AppKit
import CoreGraphics
import Metal
import SwiftUI

// Engine lifecycle and fixed-step ticking. P0 reads software frames; opt-in
// P2 hands immutable native textures to MetalFramePresenter.
@MainActor
final class EngineController: ObservableObject {
    @Published var failureMessage: String?
    @Published var status = "未初始化"
    @Published var logText = ""
    @Published var frameImage: CGImage?
    @Published var nativeFrameTexture: MTLTexture?
    private var nativeRendererEnabled = false
    private var loggedNativeFrame = false
    @Published var frameSize: CGSize = .zero
    @Published var tickCount: UInt64 = 0

    let metalPresenter: MetalFramePresenter? = MTLCreateSystemDefaultDevice().flatMap {
        try? MetalFramePresenter(device: $0)
    }
    @Published var useMetalPresentation =
        ProcessInfo.processInfo.environment["AETHER_HOST_PRESENTATION"] != "image"

    func presentationFailed(_ message: String) {
        guard useMetalPresentation else { return }
        useMetalPresentation = false
        log("Metal presentation failed, using Image: \(message)")
    }

    private let session = AetherEngineSession()
    private var timer: Timer?
    private var lastStartupState: UInt32 = 0
    private var pointerEventCount = 0
    private var keyEventCount = 0
    private var keyInput = KeyInputState()
    private var hostInputSuspended = false
    @Published private(set) var runtimeMovieActive = false
    private var movieInput = RuntimeMovieInputState()
    lazy var runtimeMovie: RuntimeMovieController = {
        let controller = RuntimeMovieController()
        controller.submit = { [weak self] response in
            guard let self else { throw CocoaError(.userCancelled) }
            try self.session.submitPlatformResponse("minori_movie", argument: response)
        }
        controller.log = { [weak self] in self?.log($0) }
        controller.failure = { [weak self] message in
            self?.failureMessage = message
            self?.recordDiagnostics(["state": "failed", "error": message])
        }
        controller.activityChanged = { [weak self] active in
            guard let self else { return }
            self.runtimeMovieActive = active
            if active { InputNSView.activeView?.cancelPressedButtons() }
            self.setInputSuspended(self.hostInputSuspended)
        }
        return controller
    }()
    lazy var platformDialogs: PlatformDialogController = {
        let controller = PlatformDialogController()
        controller.submitRequest = { [weak self] operation, response in
            guard let self else { throw CocoaError(.userCancelled) }
            try self.session.submitPlatformResponse(operation, argument: response)
        }
        controller.log = { [weak self] in self?.log($0) }
        controller.pendingChanged = { [weak self] _ in
            guard let self else { return }
            self.setInputSuspended(self.hostInputSuspended)
        }
        return controller
    }()
    @Published private(set) var virtualControlHeld = false
    @Published private(set) var inputSuspended = false
    private var appliedSurfaceSize: CGSize = .zero
    private let profileFrames = ProcessInfo.processInfo.environment["AETHER_HOST_PROFILE"] == "1"
    private var frameWorkMilliseconds: [Double] = []
    private(set) var loopRunning = false

    let diagnostics: DiagnosticStore = {
        let base = ProcessInfo.processInfo.environment["AETHER_HOST_LIBRARY_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether", isDirectory: true)
        return DiagnosticStore(root: base.appendingPathComponent("Diagnostics", isDirectory: true))
    }()
    private var diagnosticWriteFailed = false
    private var diagnosticsPrepared = false

    func prepareDiagnostics(gamePath: String, title: String = "") {
        diagnosticsPrepared = true
        recordDiagnostics(["gamePath": gamePath, "gameTitle": title, "state": "initializing"], newSession: true)
        log("session \(diagnostics.metadata["session"] ?? "unknown") started")
    }

    private func recordDiagnostics(_ values: [String: String], newSession: Bool = false) {
        do { try diagnostics.update(values, newSession: newSession) }
        catch { reportDiagnosticWriteFailure(error) }
    }

    private func reportDiagnosticWriteFailure(_ error: Error) {
        if !diagnosticWriteFailed {
            diagnosticWriteFailed = true
            print("[host] diagnostic persistence failed: \(error.localizedDescription)")
            logText += "Diagnostic persistence failed: \(error.localizedDescription)\n"
        }
    }

    private func drainEngineLogs() {
        for line in session.drainStartupLogs().split(separator: "\n") { log("[engine] \(line)") }
    }

    func log(_ line: String) {
        print("[host] \(line)")
        do { try diagnostics.append(line) } catch { reportDiagnosticWriteFailure(error) }
        logText += line + "\n"
        if logText.count > 12000 {
            logText.removeFirst(logText.count - 12000)
        }
    }

    @discardableResult
    func initializeEngine(renderer: String? = nil) -> Bool {
        failureMessage = nil
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
            if let font = ProcessInfo.processInfo.environment["AETHER_HOST_DEFAULT_FONT"]
                ?? Bundle.main.url(forResource: "aetherkiri-runtime-cjk", withExtension: "otf")?.path {
                try session.setOption("default_font", value: font)
            }
            // M0 baseline: software renderer feeds engine_read_frame_rgba.
            if (ProcessInfo.processInfo.environment["AETHER_HOST_RENDERER"] ?? renderer) == "metal" {
                try session.enableMetalRenderer()
                nativeRendererEnabled = true
            } else {
                try session.setOption("renderer", value: "software")
                nativeRendererEnabled = false
            }
            // Disables engine console.log writes (engine DebugIntf path).
            // NOTE: the sidecar krkr2.log beside the game root attaches
            // unconditionally in engine_open_game; same behavior as the Godot
            // host (games live in managed copies there). Parity accepted.
            try session.setOption("console_log_file", value: "0")
            recordDiagnostics(["renderer": nativeRendererEnabled ? "metal" : "software", "api": String(session.engineAPIVersion())])
            status = "引擎已创建 (api v\(session.engineAPIVersion()))"
            log("engine_create OK, renderer=\(nativeRendererEnabled ? "metal-bridge" : "software"), api=\(session.engineAPIVersion())")
            return true
        } catch {
            failureMessage = error.localizedDescription
            recordDiagnostics(["state": "failed", "error": error.localizedDescription])
            status = "初始化失败"
            log("initialize failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func openAndRun(gamePath: String) -> Bool {
        failureMessage = nil
        guard !gamePath.isEmpty else {
            log("game path is empty")
            failureMessage = "Game path is empty"
            return false
        }
        if !diagnosticsPrepared {
            prepareDiagnostics(gamePath: gamePath)
        }
        diagnosticsPrepared = false
        recordDiagnostics(["renderer": nativeRendererEnabled ? "metal" : "software", "api": String(session.engineAPIVersion())])
        do {
            try session.openGame(atPath: gamePath)
            drainEngineLogs()
            recordDiagnostics(["state": "starting"])
            log("engine_open_game: \(gamePath)")
            tickCount = 0
            frameWorkMilliseconds.removeAll(keepingCapacity: true)
            metalPresenter?.resetProfile()
            status = "启动中…"
            startLoop()
            return true
        } catch {
            failureMessage = error.localizedDescription
            recordDiagnostics(["state": "failed", "error": error.localizedDescription])
            drainEngineLogs()
            log("open failed: \(error.localizedDescription)")
            return false
        }
    }

    func startLoop() {
        guard !loopRunning else { return }
        loopRunning = true
        // TODO(M1): CVDisplayLink / CADisplayLink pacing; Timer is the M0 smoke.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // Timer is installed exclusively on RunLoop.main. Execute here
            // instead of enqueueing another task for every fired timer.
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log("tick loop started (60 Hz timer), presentation=\(metalPresenter?.directPresentation == true ? "direct" : "deferred")")
    }

    func stopLoop() {
        timer?.invalidate()
        timer = nil
        loopRunning = false
        log("tick loop stopped")
    }

    private func step() {
        let started = profileFrames ? ProcessInfo.processInfo.systemUptime : 0
        defer {
            // Direct mode also includes upload, drawable acquisition and
            // presentation encoding. Deferred mode excludes the later draw.
            if profileFrames, tickCount > 60, frameSize.width > 0,
               frameWorkMilliseconds.count < 10_000 {
                frameWorkMilliseconds.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
        }
        // Fixed step mirrors the Godot host (main.gd passes 1/60).
        session.tick(deltaMS: 16)
        tickCount += 1
        if tickCount % 30 == 1 { drainEngineLogs() }

        if !platformDialogs.hasPending {
            session.pollPlatformRequests { [weak self] operation, argument in
                self?.handlePlatformRequest(operation, argument: argument)
            }
        }

        runtimeMovie.update()

        let state = session.startupState()
        if state != lastStartupState {
            lastStartupState = state
            switch state {
            case 1:
                log("startup state: RUNNING")
            case 2:
                status = "运行中"
                drainEngineLogs()
                recordDiagnostics(["state": "running"])
                log("startup state: SUCCEEDED")
            case 3:
                status = "启动失败"
                drainEngineLogs()
                let detail = session.lastError()
                failureMessage = detail.isEmpty ? "Game startup failed." : detail
                recordDiagnostics(["state": "failed", "error": failureMessage ?? ""])
                log("startup error: \(failureMessage ?? "")")
                stopLoop()
                log("startup state: FAILED — check engine log output")
            default:
                break
            }
        }

        if nativeRendererEnabled {
            nativeFrameTexture = session.copyNativeFrameTexture()
            if nativeFrameTexture != nil, !loggedNativeFrame {
                loggedNativeFrame = true
                log("native GPU frame: Metal texture acquired")
            }
        }
        // CPU frames remain a diagnostic/display fallback; the native Metal
        // path does not read back or upload each frame.
        if !nativeRendererEnabled || !useMetalPresentation || nativeFrameTexture == nil {
            frameImage = session.copyFrameImage()
        }
        if nativeFrameTexture != nil || frameImage != nil {
            let size = nativeFrameTexture.map { CGSize(width: $0.width, height: $0.height) }
                ?? session.framePixelSize()
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
                    if nativeRendererEnabled {
                        try session.setOption("frame_output", value: "surface")
                    }
                    appliedSurfaceSize = size
                    log("surface size -> \(Int(size.width))x\(Int(size.height)) (game native)")
                } catch {
                    log("setSurfaceSize failed: \(error.localizedDescription)")
                }
            }
            if useMetalPresentation, let presenter = metalPresenter {
                if profileFrames { presenter.profileFrame(tick: tickCount, started: started) }
                do {
                    try presenter.presentFrame(native: nativeFrameTexture, image: frameImage)
                } catch {
                    presentationFailed(String(describing: error))
                }
            }
            if tickCount % 300 == 0 {
                log("frame presented (tick \(tickCount))")
            }
        }
    }

    // Saves the current engine frame as PNG (env AETHER_HOST_CAPTURE_AFTER).
    private func saveFrameSnapshot(tag: String) {
        guard let image = session.copyFrameImage() ?? frameImage else {
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
            if useMetalPresentation, let presenter = metalPresenter {
                if let nativeFrameTexture {
                    presenter.useNativeTexture(nativeFrameTexture)
                } else {
                    try presenter.upload(image)
                }
                let bgra = try presenter.renderOffscreen(width: image.width, height: image.height)
                var rgba = bgra
                var maxDifference = 0
                if let original = image.dataProvider?.data,
                   let originalBytes = CFDataGetBytePtr(original) {
                    for y in 0..<image.height {
                        for x in 0..<image.width {
                            let offset = (y * image.width + x) * 4
                            rgba[offset] = bgra[offset + 2]
                            rgba[offset + 2] = bgra[offset]
                            let sourceOffset = y * image.bytesPerRow + x * 4
                            for channel in 0..<3 {
                                maxDifference = max(maxDifference,
                                    abs(Int(rgba[offset + channel]) - Int(originalBytes[sourceOffset + channel])))
                            }
                        }
                    }
                }
                let provider = CGDataProvider(data: Data(rgba) as CFData)!
                let gpuImage = CGImage(
                    width: image.width, height: image.height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent)!
                let gpuPath = "\(dir)/aetherhost-metal-\(tag).png"
                if let gpuData = NSBitmapImageRep(cgImage: gpuImage).representation(using: .png, properties: [:]) {
                    try gpuData.write(to: URL(fileURLWithPath: gpuPath))
                    log("Metal capture saved: \(gpuPath); RGB max diff=\(maxDifference)")
                }
            }
        } catch {
            log("capture \(tag) failed: \(error.localizedDescription)")
        }
    }

    func handlePlatformRequest(_ operation: String, argument: String) {
        if operation == "open_browser", let url = URL(string: argument) {
            NSWorkspace.shared.open(url)
        } else if operation == "minori_movie", let handle = session.borrowedEngineHandle() {
            runtimeMovie.open(argument, engine: handle)
        } else if operation == "dialog" {
            platformDialogs.enqueue(argument)
        } else if operation == "text_input" {
            platformDialogs.enqueueTextInput(argument)
        } else if operation == "purchase" {
            let request = PlatformPurchaseRequest(argument: argument)
            let response = PlatformPurchaseResponse.unavailable(productID: request.productID)
            do {
                try session.submitPlatformResponse("purchase", argument: response.argument)
                log("purchase unavailable (product=\(request.productID.isEmpty ? "unknown" : request.productID))")
            } catch {
                log("purchase response failed: \(error.localizedDescription)")
            }
        } else {
            let preview = argument.count > 96 ? String(argument.prefix(96)) + "…" : argument
            log("platform_request: \(operation) \(preview)")
        }
    }

    // MARK: - Input forwarding (see InputMapping for translation rules)

    func sendPointer(
        type: UInt32, x: Double, y: Double, dx: Double, dy: Double,
        button: Int32, modifiers: Int32
    ) {
        if movieInput.consumePointer(type: type, button: button, movieActive: runtimeMovieActive) {
            if runtimeMovieActive, type == EngineInputEvent.pointerDown,
               !hostInputSuspended && !platformDialogs.hasPending { runtimeMovie.skip() }
            return
        }
        guard !inputSuspended || type == EngineInputEvent.pointerUp else { return }
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
        if movieInput.consumeKey(pressed: pressed, key: keyCode, movieActive: runtimeMovieActive) {
            if runtimeMovieActive, pressed, !hostInputSuspended && !platformDialogs.hasPending,
               [13, 27, 32].contains(keyCode) { runtimeMovie.skip() }
            return
        }
        guard !pressed || !inputSuspended else { return }
        for transition in keyInput.set(.physical, key: keyCode, pressed: pressed, modifiers: modifiers, unicode: unicode) {
            forwardKey(transition)
        }
    }

    private func forwardKey(_ event: KeyTransition) {
        let pressed = event.pressed, keyCode = event.key, unicode = event.unicode
        let modifiers = event.modifiers | (virtualControlHeld && keyCode != 0x11 ? 0x04 : 0)
        keyEventCount += 1
        if keyEventCount <= 12 {
            log("input key \(pressed ? "down" : "up") vk=0x\(String(keyCode, radix: 16)) unicode=\(unicode) mods=\(modifiers)")
        }
        session.sendKey(
            pressed: pressed, keyCode: keyCode, modifiers: modifiers,
            unicode: unicode)
    }

    func tapVirtualKey(_ key: Int32) {
        guard loopRunning, !inputSuspended else { return }
        log("virtual key tap vk=0x\(String(key, radix: 16))")
        for event in keyInput.set(.virtual, key: key, pressed: true) { forwardKey(event) }
        for event in keyInput.set(.virtual, key: key, pressed: false) { forwardKey(event) }
    }

    func setVirtualControlHeld(_ held: Bool) {
        guard !held || (loopRunning && !inputSuspended) else { return }
        virtualControlHeld = held
        for event in keyInput.set(.virtual, key: 0x11, pressed: held, modifiers: held ? 0x04 : 0) { forwardKey(event) }
        log("virtual Ctrl \(held ? "down" : "up")")
    }

    func releaseVirtualKeys() {
        let wasHeld = virtualControlHeld
        virtualControlHeld = false
        for event in keyInput.release(.virtual) { forwardKey(event) }
        if wasHeld { log("virtual Ctrl released") }
    }

    func setInputSuspended(_ suspended: Bool) {
        hostInputSuspended = suspended
        let effective = suspended || platformDialogs.hasPending || runtimeMovieActive
        guard inputSuspended != effective else { return }
        inputSuspended = effective
        if effective { releaseAllKeys() }
    }

    private func releaseAllKeys() {
        virtualControlHeld = false
        for event in keyInput.releaseAll() { forwardKey(event) }
    }

    func commitGameText(_ text: String) throws {
        guard loopRunning, !runtimeMovieActive else { throw CocoaError(.userCancelled) }
        let scalars = GameTextInput.scalars(text)
        for scalar in scalars { try session.sendTextCodepoint(scalar) }
        log("game text committed: \(scalars.count) Unicode scalars")
    }

    func autorunIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["AETHER_HOST_AUTORUN"] == "1" else { return }
        log("AUTORUN: initializing engine")
        log("presentation=\(useMetalPresentation && metalPresenter != nil ? "metal-upload" : "image"), engine renderer=\(env["AETHER_HOST_RENDERER"] ?? "software")")
        initializeEngine()
        let path = env["AETHER_HOST_GAME_PATH"] ?? Self.defaultGamePath
        log("AUTORUN: opening \(path)")
        openAndRun(gamePath: path)
        #if DEBUG
        // Test-only request injection; ACK is intentionally not a real Minori provider.
        if let argument = env["AETHER_HOST_TEST_RUNTIME_MOVIE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard self.loopRunning else { return }
                self.runtimeMovie.submit = { [weak self] response in self?.log("TEST MOVIE ACK: \(response)") }
                self.handlePlatformRequest("minori_movie", argument: argument)
            }
        }
        #endif
        if let raw = env["AETHER_HOST_TEST_INPUT"], let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.runTestInputSequence()
            }
        }
        // Optional scripted virtual keys, e.g. "9:90,12:83" means Z then S.
        // Uses the same engine input boundary as AppKit, for renderer regressions.
        if let raw = env["AETHER_HOST_TEST_KEYS"] {
            for entry in raw.split(separator: ",").prefix(100) {
                let pair = entry.split(separator: ":")
                guard pair.count == 2, let delay = Double(pair[0]),
                      delay.isFinite, delay >= 0, let key = Int32(pair[1]),
                      key >= 0, key <= 0xffff else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard self.loopRunning else { return }
                    self.log("TEST KEY: \(key)")
                    self.sendKey(pressed: true, keyCode: key, modifiers: 0, unicode: 0)
                    self.sendKey(pressed: false, keyCode: key, modifiers: 0, unicode: 0)
                }
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
    private func runTestInputSequence() {
        guard loopRunning else {
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
                pressed: true, keyCode: 0x0D, modifiers: 0, unicode: 0)
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
        if !frameWorkMilliseconds.isEmpty {
            let sorted = frameWorkMilliseconds.sorted()
            let p50 = sorted[(sorted.count - 1) / 2]
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            log(String(format: "PROFILE host-work %dx%d samples=%d warmup_ticks=60 p50_ms=%.3f p95_ms=%.3f max_ms=%.3f %@",
                       Int(frameSize.width), Int(frameSize.height), sorted.count,
                       p50, p95, sorted.last!,
                       metalPresenter?.directPresentation == true && useMetalPresentation
                           ? "(tick+texture+MTKView submit; excludes async GPU completion)"
                           : "(tick+texture; excludes MTKView)"))
            frameWorkMilliseconds.removeAll(keepingCapacity: true)
        }
        if profileFrames, let summary = metalPresenter?.finishProfile() {
            log(summary)
        }
        runtimeMovie.reset()
        movieInput.reset()
        platformDialogs.reset()
        releaseAllKeys()
        hostInputSuspended = false
        inputSuspended = false
        stopLoop()
        drainEngineLogs()
        recordDiagnostics(["state": failureMessage == nil ? "stopped" : "failed", "closed": ISO8601DateFormatter().string(from: Date()),
                           "ticks": String(tickCount), "frame": "\(Int(frameSize.width))x\(Int(frameSize.height))"])
        session.shutdown()
        log(session.metalBridgeDiagnostics())
        nativeFrameTexture = nil
        nativeRendererEnabled = false
        loggedNativeFrame = false
        frameImage = nil
        frameSize = .zero
        appliedSurfaceSize = .zero
        lastStartupState = 0
        metalPresenter?.clear()
        status = "已关闭"
        log("engine destroyed")
    }
}
