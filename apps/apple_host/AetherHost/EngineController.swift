import AppKit
import CoreGraphics
import Metal
import SwiftUI

// Engine lifecycle and fixed-step ticking. Native sessions pass immutable
// textures to MetalFramePresenter; software remains the diagnostic fallback.
@MainActor
final class EngineController: ObservableObject {
    @Published var failureMessage: String?
    @Published var status = "未初始化"
    @Published var logText = ""
    @Published var frameImage: CGImage?
    @Published var nativeFrameTexture: MTLTexture?
    // The lease is an internal render-session handle. Publishing it every
    // tick would invalidate SwiftUI even when the underlying texture is the
    // same; the presenter owns it until GPU completion.
    var nativeFrameLease: AetherMetalFrameLease?
    private let directRender = ProcessInfo.processInfo.environment["AETHER_HOST_DIRECT_RENDER"] == "1"
    private let offscreenBenchmark = ProcessInfo.processInfo.environment["AETHER_HOST_BENCHMARK"] == "1"
    private let offscreenWaitForGPU = ProcessInfo.processInfo.environment["AETHER_HOST_BENCHMARK_WAIT_GPU"] != "0"
    private var nativeRendererEnabled = false
    private var loggedNativeFrame = false
    @Published var frameSize: CGSize = .zero
    @Published var tickCount: UInt64 = 0
    @Published private(set) var outputFrameSize: CGSize = .zero
    private var displayPixels: CGSize = .zero
    private var sourceFrameImage: CGImage?
    private var failedOutputTarget: CGSize?
    private var sessionCanvasMode: CanvasMode = .game
    private var sessionOutputResolution: OutputResolution = .original
    private var sessionSamplingAlgorithm: SamplingAlgorithm = .bicubic

    func updateDisplayPixels(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != displayPixels else { return }
        displayPixels = size
        updateOutputGeometry()
    }

    private var geometryDiagnostics: [String: String] {
        ["canvasMode": sessionCanvasMode.rawValue, "outputResolution": sessionOutputResolution.rawValue,
         "samplingAlgorithm": sessionSamplingAlgorithm.rawValue,
         "logicalCanvas": "\(Int(frameSize.width))x\(Int(frameSize.height))",
         "outputFrame": "\(Int(outputFrameSize.width))x\(Int(outputFrameSize.height))"]
    }

    private func updateOutputGeometry() {
        let requested = RenderGeometry.target(source: frameSize, mode: sessionCanvasMode,
            resolution: sessionOutputResolution, displayPixels: displayPixels)
        var target = requested
        var fallbackChanged = false
        if !useMetalPresentation, let sourceFrameImage, requested.width > 0 {
            if failedOutputTarget == requested {
                frameImage = sourceFrameImage
                target = frameSize
            } else if let resized = RenderGeometry.image(sourceFrameImage, size: requested,
                                                        sampling: sessionSamplingAlgorithm) {
                frameImage = resized
                failedOutputTarget = nil
                if renderState.fallbacks.contains(where: { $0.reasonKey == "outputScalingFailed" }) {
                    renderState.fallbacks.removeAll { $0.reasonKey == "outputScalingFailed" }
                    fallbackChanged = true
                }
            } else {
                failedOutputTarget = requested
                frameImage = sourceFrameImage
                target = frameSize
                if !renderState.fallbacks.contains(where: { $0.reasonKey == "outputScalingFailed" }) {
                    renderState.fallbacks.append(.init(reasonKey: "outputScalingFailed", detail: "Software output allocation failed"))
                    fallbackChanged = true
                }
            }
        }
        metalPresenter?.outputSize = target
        if target != outputFrameSize || fallbackChanged {
            outputFrameSize = target
            recordDiagnostics(geometryDiagnostics.merging(renderState.diagnostics) { _, new in new })
            log("output size -> \(Int(target.width))x\(Int(target.height)) (\(sessionCanvasMode.rawValue), \(sessionOutputResolution.rawValue)); logical canvas \(Int(frameSize.width))x\(Int(frameSize.height))")
        }
    }

    let metalPresenter: MetalFramePresenter?
    private let metalAvailability: HostCapabilities.Availability
    private let activateMetal: (AetherEngineSession) throws -> Void
    @Published private(set) var renderState = RenderSessionState()
    var capabilities: HostCapabilities {
        HostCapabilities(nativeMetal: metalAvailability, translation: session.isTextTranslationAvailable()
                         ? .ready : .init(reasonKey: "translationModelUnavailable", detail: ""))
    }
    enum SetupFailure: Error { case noDevice }
    init(presenterFactory: (() throws -> MetalFramePresenter)? = nil,
         metalActivation: ((AetherEngineSession) throws -> Void)? = nil) {
        self.activateMetal = metalActivation ?? { try $0.enableMetalRenderer() }
        do {
            if let presenterFactory { metalPresenter = try presenterFactory() }
            else {
                guard let device = MTLCreateSystemDefaultDevice() else { throw SetupFailure.noDevice }
                metalPresenter = try MetalFramePresenter(device: device, commandQueue: AetherMetalBridgeCommandQueue())
            }
            metalAvailability = .ready
        } catch {
            metalPresenter = nil
            metalAvailability = .init(reasonKey: error is SetupFailure ? "metalDeviceUnavailable" : "metalPresenterUnavailable",
                                      detail: String(describing: error))
        }
    }
    private var metalPresenterGateWired = false
    @Published var useMetalPresentation =
        ProcessInfo.processInfo.environment["AETHER_HOST_PRESENTATION"] != "image"

    func presentationFailed(_ message: String) {
        guard useMetalPresentation else { return }
        useMetalPresentation = false
        renderState.presentation = .image
        renderState.fallbacks.append(.init(reasonKey: "metalPresentationFailed", detail: message))
        metalPresenter?.suspend()
        if !AetherMetalBridgeDrain() { log("Metal queue drain failed during presentation fallback") }
        metalPresenter?.clear()
        nativeFrameLease = nil
        nativeFrameTexture = nil
        recordDiagnostics(renderState.diagnostics)
        log("Metal presentation failed, using Image: \(message)")
    }

    private let session = AetherEngineSession()
    var hostSettings = HostSettings()
    private(set) var appliedSettingOptions: [String: String] = [:]
    private var frameClock: HostFrameClock?
    private var scheduler = FrameScheduler(mode: .followDisplay)
    private(set) var pacingDriver = "none"
    private(set) var pacingMode = FramePacingMode.followDisplay
    private(set) var pacingTargetFPS: Int?
    private(set) var pacingLifecycleReasons: Set<String> = []
    private(set) var renderTickCount: UInt64 = 0
    private(set) var presentationCount: UInt64 = 0
    private(set) var lastTickDeltaMS: UInt32 = 0
    private(set) var maxTickDeltaMS: UInt32 = 0
    private var lastPresenterFrameCount: UInt64 = 0
    private var lastPublishedImage: CGImage?
    private var pacingSessionStart: TimeInterval = 0
    private var lifecycleObservers: [NotificationCenter: [NSObjectProtocol]] = [:]
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

    // Local-model text translation. Availability is process-wide and queried
    // before a game is started; a settings preview never changes this result.
    var translationSettings = TranslationSettings()
    var translationTargetLanguage = TranslationSettings.targetLanguageCode(for: .english)
    @Published private(set) var translationStatus = TranslationStatus()
    private var loggedTranslationState: UInt32?
    var textTranslationAvailable: Bool {
        capabilities.translation.available
    }

    // Focused game text layer (KiriKiri edit control) and IME composition.
    @Published private(set) var gameTextInput = GameTextInputState()
    private(set) var gameTextCaretPoint: CGPoint?
    private var imePreedit = IMEPreeditTracker()
    private var preeditUnsupported = false

    /// Polls the focused text layer and mirrors the Godot shell's
    /// _sync_game_text_input_state() activation decision: composed input is
    /// enabled only while the layer publishes a caret and accepts IME input.
    func refreshGameTextInput() {
        let state = GameTextInputState(dictionary: session.textInputState())
        guard state != gameTextInput else { return }
        let wasActive = gameTextInput.wantsHostIME
        gameTextInput = state
        gameTextCaretPoint = state.wantsHostIME ? state.attention : nil
        InputNSView.activeView?.inputContext?.invalidateCharacterCoordinates()
        if state.wantsHostIME {
            if let view = InputNSView.activeView, view.window?.firstResponder !== view {
                view.window?.makeFirstResponder(view)
            }
            log("game text input active (ime_mode=\(state.imeMode), selection=\(state.selectionStart)..\(state.selectionEnd), caret=\(Int(state.attention.x)),\(Int(state.attention.y)))")
        } else if wasActive {
            clearIMEPreedit()
            log("game text input inactive")
        }
    }

    /// Forwards IME composition to the engine. Siglus consumes the preedit
    /// options; the KiriKiri legacy layer ignores them and receives the
    /// committed text instead, so a rejected option is reported once.
    func sendIMEPreedit(markedText: String, selectedRange: NSRange) {
        guard let payload = imePreedit.update(
            markedText: markedText, selectedRange: selectedRange) else { return }
        guard !preeditUnsupported else { return }
        do {
            try session.sendIMEPreedit(
                payload.text,
                cursorStart: Int32(payload.cursorStart),
                cursorLength: Int32(payload.cursorLength))
        } catch {
            preeditUnsupported = true
            log("ime preedit unsupported: \(error.localizedDescription)")
        }
    }

    func clearIMEPreedit() {
        guard let payload = imePreedit.clearIfNeeded(), !preeditUnsupported else { return }
        try? session.sendIMEPreedit(payload.text, cursorStart: 0, cursorLength: 0)
    }

    /// Committed text from the input method or paste (composed text path).
    /// Shares the manual entry filter and logs the scalar count only.
    func commitComposedText(_ text: String) {
        guard loopRunning, !runtimeMovieActive else { return }
        let scalars = GameTextInput.scalars(text)
        guard !scalars.isEmpty else { return }
        do {
            try session.sendTextInput(text)
            log("composed text committed: \(scalars.count) Unicode scalars")
        } catch {
            log("composed text failed: \(error.localizedDescription)")
        }
    }

    private var unhandledPlatformRequests = 0

    /// Operations the host consumes without submitting a response. Every other
    /// operation must answer explicitly: a runtime waiting on a response would
    /// otherwise stall silently.
    private static let operationsWithoutResponse: Set<String> = ["open_browser"]

    /// Applies text_translation.* before a game opens; mirrors the Godot
    /// shell's option order. Rejections are logged instead of aborting the
    /// session so an unsupported build still starts the game.
    @discardableResult
    func applyTranslationOptions() -> Bool {
        guard textTranslationAvailable else { return false }
        var applied = true
        for option in translationSettings.engineOptions(targetLanguage: translationTargetLanguage) {
            do { try session.setOption(option.key, value: option.value) }
            catch {
                applied = false
                log("translation option \(option.key) rejected: \(error.localizedDescription)")
            }
        }
        if applied {
            let model = translationSettings.displayName.isEmpty ? "none" : translationSettings.displayName
            log("translation options applied (model=\(model), target=\(translationTargetLanguage), enabled=\(translationSettings.isConfigured ? "1" : "0"))")
        }
        refreshTranslationStatus()
        return applied
    }

    /// Samples the process-wide translation state; logs transitions only.
    func refreshTranslationStatus() {
        let stats = session.textTranslationStats()
        let status = TranslationStatus(state: session.textTranslationState(), stats: stats)
        translationStatus = status
        if loggedTranslationState != status.state.rawValue {
            loggedTranslationState = status.state.rawValue
            log("translation state -> \(status.state)")
        }
    }

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
        guard session.borrowedEngineHandle() == nil else {
            failureMessage = "The engine must be shut down before initializing another render session."
            return false
        }
        failureMessage = nil
        let requested = ProcessInfo.processInfo.environment["AETHER_HOST_RENDERER"] ?? renderer ?? hostSettings.renderer
        guard let requestedRenderer = HostRenderer(rawValue: requested) else {
            failureMessage = "Unknown renderer: " + requested
            return false
        }
        let env = ProcessInfo.processInfo.environment
        guard let mode = CanvasMode(rawValue: hostSettings.canvasMode),
              let resolution = OutputResolution(rawValue: env["AETHER_HOST_OUTPUT_RESOLUTION"] ?? hostSettings.outputResolution),
              let sampling = SamplingAlgorithm.normalized(env["AETHER_HOST_SAMPLING_ALGORITHM"] ?? hostSettings.upscaleAlgorithm) else {
            failureMessage = "Invalid canvas or output resolution."
            return false
        }
        failedOutputTarget = nil
        sessionCanvasMode = mode
        sessionOutputResolution = resolution
        sessionSamplingAlgorithm = sampling
        metalPresenter?.samplingAlgorithm = sampling
        renderState = RenderSessionState(requested: requestedRenderer)
        useMetalPresentation = metalAvailability.available && ProcessInfo.processInfo.environment["AETHER_HOST_PRESENTATION"] != "image"
        nativeRendererEnabled = false
        if !metalPresenterGateWired, let presenter = metalPresenter {
            // Drawable requests pause while the window cannot present; the
            // nextDrawable timeout would otherwise stall the main thread.
            presenter.onGateChange = { [weak self] message in self?.log(message) }
            metalPresenterGateWired = true
        }
        metalPresenter?.resume()
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

            func createBaseSession() throws {
                try session.initialize(writablePath: support.path, cachePath: cache.path)
                if let font = ProcessInfo.processInfo.environment["AETHER_HOST_DEFAULT_FONT"]
                    ?? Bundle.main.url(forResource: "aetherkiri-runtime-cjk", withExtension: "otf")?.path {
                    try session.setOption("default_font", value: font)
                }
            }
            try createBaseSession()
            if requestedRenderer == .metal {
                if let reason = metalAvailability.reasonKey {
                    renderState.fallbacks.append(.init(reasonKey: reason, detail: metalAvailability.detail))
                } else {
                    do { try activateMetal(session); nativeRendererEnabled = true }
                    catch {
                        let nsError = error as NSError
                        let unsupported = nsError.domain == "AetherEngineOption" && nsError.code == -3
                        renderState.fallbacks.append(.init(reasonKey: unsupported ? "metalRuntimeUnsupported" : "metalInitializationFailed",
                                                          detail: error.localizedDescription))
                        // Native activation can fail after the generation/backend has
                        // changed. A fresh engine prevents carrying partial state
                        // into the software path. No game has been opened yet.
                        session.shutdown()
                        try createBaseSession()
                    }
                }
            }
            if !nativeRendererEnabled {
                try session.setOption("renderer", value: "software")
                try session.setOption("frame_output", value: "raw_source")
            }
            renderState.effective = nativeRendererEnabled ? .metal : .software
            renderState.presentation = useMetalPresentation ? .metal : .image
            renderState.active = true
            for fallback in renderState.fallbacks { log("renderer fallback \(fallback.reasonKey): \(fallback.detail)") }
            // Disables engine console.log writes (engine DebugIntf path).
            // NOTE: the sidecar krkr2.log beside the game root attaches
            // unconditionally in engine_open_game; same behavior as the Godot
            // host (games live in managed copies there). Parity accepted.
            try session.setOption("console_log_file", value: "0")
            appliedSettingOptions = [:]
            for option in hostSettings.engineOptions {
                // The engine option is applied before any game is opened. The
                // smoke override may replace it, so record the effective value.
                let value = option.key == "fps_limit" ? effectiveFPSLimitOption : option.value
                do {
                    try session.setOption(option.key, value: value)
                    appliedSettingOptions[option.key] = value
                    log("settings option \(option.key)=\(value) applied")
                }
                catch { log("settings option \(option.key) rejected: \(error.localizedDescription)") }
            }
            pacingMode = effectivePacingMode
            pacingTargetFPS = pacingMode.targetFPS
            log("pacing configured: \(pacingMode.description), fps_limit=\(effectiveFPSLimitOption)")
            if textTranslationAvailable {
                applyTranslationOptions()
            } else {
                log("local text translation unavailable in this build")
            }
            recordDiagnostics(geometryDiagnostics.merging(renderState.diagnostics) { _, new in new }.merging(["api": String(session.engineAPIVersion())]) { _, new in new })
            status = "引擎已创建 (api v\(session.engineAPIVersion()))"
            log("engine_create OK, renderer=\(nativeRendererEnabled ? "metal-bridge" : "software"), api=\(session.engineAPIVersion())")
            return true
        } catch {
            session.shutdown()
            nativeRendererEnabled = false
            renderState.active = false
            renderState.effective = nil
            renderState.presentation = nil
            recordDiagnostics(renderState.diagnostics)
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
        // Developer callers may initialize before preparing the game report.
        // Re-publish the complete state after prepareDiagnostics resets metadata.
        recordDiagnostics(geometryDiagnostics.merging(renderState.diagnostics) { _, new in new }.merging(["api": String(session.engineAPIVersion())]) { _, new in new })
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
        if offscreenBenchmark {
            log("tick loop started (uncapped offscreen benchmark), presentation=metal-offscreen")
            scheduleBenchmarkStep()
            return
        }
        configurePacing()
        observePacingLifecycle()
        pacingSessionStart = ProcessInfo.processInfo.systemUptime
        renderTickCount = 0
        presentationCount = 0
        maxTickDeltaMS = 0
        lastPresenterFrameCount = metalPresenter?.presentedFrameCount ?? 0
        lastPublishedImage = nil
        scheduler.reset()
        let clock = HostFrameClock(preference: effectiveClockPreference, interval: pacingClockInterval)
        // HostFrameClock always delivers callbacks on the main thread; the
        // assumeIsolated hop mirrors the previous Timer loop's contract.
        clock.onCallback = { [weak self] now in
            MainActor.assumeIsolated { self?.handlePacingCallback(now: now) }
        }
        frameClock = clock
        clock.start()
        pacingDriver = clock.driver.rawValue
        log("tick loop started (pacing=\(pacingMode.description), driver=\(pacingDriver)\(clock.fallbackReason.map { " - \($0)" } ?? ""), refresh=\(Int(displayRefreshHz))Hz, presentation=\(metalPresenter?.directPresentation == true ? "direct" : "deferred")")
        recordDiagnostics(pacingDiagnostics)
    }

    private func scheduleBenchmarkStep() {
        guard loopRunning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.loopRunning else { return }
            // Deliberately synthetic: the offscreen benchmark compares submit
            // throughput at a fixed 1/60 step and is not the product scheduler.
            self.step(deltaMS: 16, syntheticStep: true)
            self.scheduleBenchmarkStep()
        }
    }

    func stopLoop() {
        if loopRunning, !offscreenBenchmark {
            log("pacing stats: \(frameStatisticsSummary)")
            recordDiagnostics(pacingDiagnostics)
        }
        frameClock?.stop()
        frameClock = nil
        removePacingLifecycleObservers()
        loopRunning = false
        log("tick loop stopped")
    }

    // MARK: - Pacing

    private var pacingClockPreference: FrameClockPreference {
        FrameClockPreference(environmentValue: ProcessInfo.processInfo.environment["AETHER_HOST_PACE"])
    }

    /// A display link can never exceed the refresh rate, so a target above the
    /// current display uses the timer source instead.
    private var effectiveClockPreference: FrameClockPreference {
        let requested = pacingClockPreference
        guard requested == .automatic else { return requested }
        if let target = pacingMode.targetFPS, Double(target) > displayRefreshHz + 1 { return .timer }
        return .automatic
    }

    /// Display refresh reported by AppKit. Used for the timer fallback interval
    /// and for the driver choice when a target exceeds the refresh rate.
    private var displayRefreshHz: Double {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let refresh = Double(screen?.maximumFramesPerSecond ?? 60)
        return refresh > 0 ? refresh : 60
    }

    /// Effective pacing mode. The persisted settings are authoritative; the
    /// AETHER_HOST_FPS_LIMIT override exists for smoke/benchmark runs.
    private var effectivePacingMode: FramePacingMode {
        if let raw = ProcessInfo.processInfo.environment["AETHER_HOST_FPS_LIMIT"],
           let value = Int(raw), value >= 0 {
            if value == 0 { return .followDisplay }
            if let target = FrameScheduler.normalizedTarget(value) { return .limited(fps: target) }
        }
        if hostSettings.fpsLimitEnabled,
           let target = FrameScheduler.normalizedTarget(hostSettings.targetFPS) {
            return .limited(fps: target)
        }
        return .followDisplay
    }

    /// Value handed to the engine's `fps_limit` option: `0` or the target rate.
    var effectiveFPSLimitOption: String {
        effectivePacingMode.targetFPS.map(String.init) ?? "0"
    }

    private var pacingClockInterval: TimeInterval {
        // Drive callbacks at least as fast as the target or the refresh so the
        // scheduler, not callback jitter, decides the realized tick rate.
        let sourceRate = min(144, max(60, displayRefreshHz))
        return 1.0 / max(sourceRate, Double(pacingMode.targetFPS ?? 0))
    }

    private func configurePacing() {
        pacingMode = effectivePacingMode
        pacingTargetFPS = pacingMode.targetFPS
        scheduler.setMode(pacingMode)
    }

    private func handlePacingCallback(now: TimeInterval) {
        guard loopRunning, !offscreenBenchmark else { return }
        guard let tick = scheduler.tick(now: now) else { return }
        step(deltaMS: tick.deltaMS, syntheticStep: false)
    }

    /// Records a focus/hide/minimize/sleep transition. The host deliberately
    /// keeps ticking so game audio and logic are unaffected by occlusion (the
    /// presenter gate already withholds drawables); the pacing clock is reset
    /// in both directions so a long pause can never become a catch-up burst.
    func handlePacingLifecycle(_ reason: String, active: Bool) {
        let changed = active ? pacingLifecycleReasons.insert(reason).inserted
                             : pacingLifecycleReasons.remove(reason) != nil
        guard changed else { return }
        scheduler.reset()
        log("host lifecycle \(reason)=\(active ? "on" : "off"); pacing reset (state=\(pacingStateDescription))")
        recordDiagnostics(pacingDiagnostics)
    }

    var pacingStateDescription: String {
        pacingLifecycleReasons.isEmpty ? "active" : pacingLifecycleReasons.sorted().joined(separator: "+")
    }

    var frameStatisticsSummary: String {
        let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - pacingSessionStart)
        func rate(_ value: UInt64) -> String { String(format: "%.1f/s", Double(value) / elapsed) }
        return "tick=\(tickCount) (\(rate(tickCount))) render=\(renderTickCount) (\(rate(renderTickCount))) "
            + "presentation=\(presentationCount) (\(rate(presentationCount))) "
            + "dropped_catch_up=\(scheduler.droppedCatchUpIntervals) coalesced=\(scheduler.coalescedCallbacks) "
            + "resets=\(scheduler.resets) max_delta_ms=\(maxTickDeltaMS)"
    }

    private var pacingDiagnostics: [String: String] {
        ["pacingMode": pacingMode.description,
         "pacingDriver": pacingDriver,
         "pacingTargetFPS": pacingTargetFPS.map(String.init) ?? "follow-display",
         "pacingState": pacingStateDescription,
         "fpsLimitOption": effectiveFPSLimitOption,
         "tickStat": String(tickCount),
         "renderStat": String(renderTickCount),
         "presentationStat": String(presentationCount),
         "droppedCatchUpIntervals": String(scheduler.droppedCatchUpIntervals),
         "maxTickDeltaMS": String(maxTickDeltaMS),
         "frameStatNote": "tick=host engine_tick calls; render=ticks whose engine render step produced a frame; presentation=drawable submissions or image publications; none equals display scan-out FPS"]
    }

    private func observePacingLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let application = NotificationCenter.default
        func observe(_ center: NotificationCenter, _ name: Notification.Name,
                     _ handler: @escaping @MainActor (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            }
            lifecycleObservers[center, default: []].append(token)
        }
        observe(application, NSApplication.didResignActiveNotification) { [weak self] _ in
            self?.handlePacingLifecycle("appInactive", active: true)
        }
        observe(application, NSApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.handlePacingLifecycle("appInactive", active: false)
        }
        observe(application, NSApplication.didHideNotification) { [weak self] _ in
            self?.handlePacingLifecycle("appHidden", active: true)
        }
        observe(application, NSApplication.didUnhideNotification) { [weak self] _ in
            self?.handlePacingLifecycle("appHidden", active: false)
        }
        observe(application, NSWindow.didMiniaturizeNotification) { [weak self] _ in
            self?.handlePacingLifecycle("windowMiniaturized", active: true)
        }
        observe(application, NSWindow.didDeminiaturizeNotification) { [weak self] _ in
            self?.handlePacingLifecycle("windowMiniaturized", active: false)
        }
        observe(application, NSWindow.didChangeOcclusionStateNotification) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.handlePacingLifecycle("windowOccluded", active: !window.occlusionState.contains(.visible))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in
            self?.handlePacingLifecycle("systemSleep", active: true)
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.handlePacingLifecycle("systemSleep", active: false)
        }
    }

    private func removePacingLifecycleObservers() {
        for (center, tokens) in lifecycleObservers {
            for token in tokens { center.removeObserver(token) }
        }
        lifecycleObservers.removeAll()
    }

    private func step(deltaMS: UInt32, syntheticStep: Bool) {
        let started = profileFrames ? ProcessInfo.processInfo.systemUptime : 0
        defer {
            // Direct mode also includes upload, drawable acquisition and
            // presentation encoding. Deferred mode excludes the later draw.
            if profileFrames, tickCount > 60, frameSize.width > 0,
               frameWorkMilliseconds.count < 10_000 {
                frameWorkMilliseconds.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
        }
        // Real elapsed host time for this tick (clamped by the scheduler).
        // The offscreen benchmark is the only synthetic 1/60 step.
        session.tick(deltaMS: deltaMS)
        tickCount += 1
        lastTickDeltaMS = deltaMS
        maxTickDeltaMS = max(maxTickDeltaMS, deltaMS)
        if !syntheticStep, session.lastTickRenderedFrame() { renderTickCount += 1 }
        if tickCount % 30 == 1 { drainEngineLogs() }
        // Follow the loading->ready/failed transition while a model loads.
        if tickCount % 60 == 0, translationStatus.state == .loading { refreshTranslationStatus() }
        // Track the focused game text layer (~100ms) so composition and the
        // candidate window follow the game's edit control.
        if tickCount % 6 == 0 { refreshGameTextInput() }

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
            let nextTexture: MTLTexture?
            if directRender {
                // A publication serial is monotonic. When the engine did not
                // publish a new frame, keep presenting the last texture and
                // avoid allocating a redundant lease for an unchanged frame.
                if let lease = session.acquireNativeFrame() {
                    nativeFrameLease = lease
                    nextTexture = lease.texture
                } else {
                    nativeFrameLease = nil
                    nextTexture = nativeFrameTexture
                }
            } else {
                nativeFrameLease = nil
                nextTexture = session.copyNativeFrameTexture()
            }
            if nativeFrameTexture !== nextTexture {
                nativeFrameTexture = nextTexture
            }
            if nativeFrameTexture != nil, !loggedNativeFrame {
                loggedNativeFrame = true
                log("native GPU frame: Metal texture acquired")
            }
        }
        // CPU frames remain a diagnostic/display fallback; the native Metal
        // path does not read back or upload each frame.
        if !nativeRendererEnabled || !useMetalPresentation || nativeFrameTexture == nil {
            sourceFrameImage = session.copyFrameImage()
            frameImage = sourceFrameImage
        }
        if nativeFrameTexture != nil || sourceFrameImage != nil {
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
                    appliedSurfaceSize = size
                    log("surface size -> \(Int(size.width))x\(Int(size.height)) (game native)")
                } catch {
                    log("setSurfaceSize failed: \(error.localizedDescription)")
                }
            }
            updateOutputGeometry()
            if useMetalPresentation, let presenter = metalPresenter {
                if profileFrames { presenter.profileFrame(tick: tickCount, started: started) }
                do {
                    if offscreenBenchmark {
                        if let nativeFrameLease {
                            presenter.useNativeFrame(nativeFrameLease)
                        } else if let nativeFrameTexture {
                            presenter.useNativeTexture(nativeFrameTexture)
                        } else if let frameImage {
                            try presenter.upload(frameImage)
                        } else {
                            presenter.clear()
                        }
                        _ = try presenter.renderOffscreen(width: 1920, height: 1080,
                                                          waitForCompletion: offscreenWaitForGPU)
                        if directRender { nativeFrameLease = nil }
                    } else {
                        try presenter.presentFrame(native: nativeFrameTexture, lease: nativeFrameLease, image: frameImage)
                    }
                    if directRender {
                        // MetalFramePresenter retains the lease through GPU
                        // completion; the controller must not keep the prior
                        // frame alive across the next engine tick.
                        nativeFrameLease = nil
                    }
                } catch {
                    presentationFailed(String(describing: error))
                }
                if !offscreenBenchmark, let presented = metalPresenter?.presentedFrameCount,
                   presented > lastPresenterFrameCount {
                    presentationCount += presented - lastPresenterFrameCount
                }
                lastPresenterFrameCount = metalPresenter?.presentedFrameCount ?? 0
            } else if !offscreenBenchmark, renderTickCount > 0,
                      let image = frameImage, image !== lastPublishedImage {
                // Image fallback publishes a frame to SwiftUI; still a host
                // presentation, still not a display scan-out measurement.
                presentationCount += 1
                lastPublishedImage = image
            }
        }
        if tickCount % 300 == 0 {
            log("pacing stats: \(frameStatisticsSummary)")
            recordDiagnostics(pacingDiagnostics)
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
                let configuredOutput = presenter.outputSize
                // Keep the historic source/GPU regression pair unchanged;
                // capture the configured product output as a separate image.
                presenter.outputSize = .zero
                defer { presenter.outputSize = configuredOutput }
                if let nativeFrameTexture {
                    if let nativeFrameLease { presenter.useNativeFrame(nativeFrameLease) }
                    else { presenter.useNativeTexture(nativeFrameTexture) }
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
                if configuredOutput.width > 0, configuredOutput.height > 0 {
                    presenter.outputSize = configuredOutput
                    let width = Int(configuredOutput.width), height = Int(configuredOutput.height)
                    let output = try presenter.renderOffscreen(width: width, height: height)
                    let outputImage = CGImage(width: width, height: height, bitsPerComponent: 8,
                        bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: CGDataProvider(data: Data(output) as CFData)!, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)!
                    if let png = NSBitmapImageRep(cgImage: outputImage).representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: "\(dir)/aetherhost-output-\(tag).png"))
                        log("Output capture saved: \(width)x\(height)")
                    }
                }
            } else if let output = RenderGeometry.image(image, size: outputFrameSize,
                                                        sampling: sessionSamplingAlgorithm),
                      let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "\(dir)/aetherhost-output-\(tag).png"))
            }
        } catch {
            log("capture \(tag) failed: \(error.localizedDescription)")
        }
    }

    func handlePlatformRequest(_ operation: String, argument: String) {
        if operation == "open_browser" {
            guard let request = PlatformBrowserRequest(argument: argument) else {
                log("open_browser rejected invalid URL")
                return
            }
            if !NSWorkspace.shared.open(request.url) {
                log("open_browser failed for scheme=\(request.url.scheme ?? "unknown")")
            }
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
        } else if operation == "call_native" {
            // Parity with the Godot shell, which answers an empty native call
            // so the runtime never waits on it.
            do {
                try session.submitPlatformResponse("call_native", argument: "result=")
                log("call_native acknowledged")
            } catch {
                log("call_native response failed: \(error.localizedDescription)")
            }
        } else if Self.operationsWithoutResponse.contains(operation) {
            let preview = argument.count > 96 ? String(argument.prefix(96)) + "…" : argument
            log("platform_request: \(operation) \(preview)")
        } else {
            let preview = argument.count > 96 ? String(argument.prefix(96)) + "…" : argument
            unhandledPlatformRequests += 1
            log("unhandled platform_request (no response): \(operation) \(preview)")
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
        log("presentation=\(useMetalPresentation && metalPresenter != nil ? "metal-upload" : "image"), requested renderer=\(env["AETHER_HOST_RENDERER"] ?? hostSettings.renderer)")
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
        if let argument = env["AETHER_HOST_TEST_PURCHASE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard self.loopRunning else { return }
                self.handlePlatformRequest("purchase", argument: argument)
            }
        }
        if let argument = env["AETHER_HOST_TEST_OPEN_BROWSER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard self.loopRunning else { return }
                self.handlePlatformRequest("open_browser", argument: argument)
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
        // Scripted lifecycle events, e.g. "4:on,7:off", drive the same handler
        // as the AppKit focus/occlusion/minimize notifications.
        if let raw = env["AETHER_HOST_TEST_LIFECYCLE"] {
            for entry in raw.split(separator: ",").prefix(32) {
                let pair = entry.split(separator: ":")
                guard pair.count == 2, let delay = Double(pair[0]), delay.isFinite, delay >= 0 else { continue }
                let active = pair[1] == "on"
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard self.loopRunning else { return }
                    self.log("TEST LIFECYCLE: testLifecycle=\(active ? "on" : "off")")
                    self.handlePacingLifecycle("testLifecycle", active: active)
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
        log("input pointer type=1 at (\(Int(center.x)),\(Int(center.y))) btn=0 mods=0")
        sendPointer(
            type: EngineInputEvent.pointerDown,
            x: Double(center.x), y: Double(center.y), dx: 0, dy: 0,
            button: 0, modifiers: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.log("input pointer type=3 at (\(Int(center.x)),\(Int(center.y))) btn=0 mods=0")
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
        // Stop drawable requests before tearing the session down: a pending
        // draw against a closing window waits on nextDrawable for a second.
        metalPresenter?.suspend()
        if !AetherMetalBridgeDrain() { log("Metal queue drain failed") }
        if !frameWorkMilliseconds.isEmpty {
            let sorted = frameWorkMilliseconds.sorted()
            let p50 = sorted[(sorted.count - 1) / 2]
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            log(String(format: "PROFILE host-work %dx%d samples=%d warmup_ticks=60 p50_ms=%.3f p95_ms=%.3f max_ms=%.3f %@",
                       Int(frameSize.width), Int(frameSize.height), sorted.count,
                       p50, p95, sorted.last!,
                       offscreenBenchmark
                           ? "(tick+texture+offscreen GPU completion)"
                           : metalPresenter?.directPresentation == true && useMetalPresentation
                           ? "(tick+texture+MTKView submit; excludes async GPU completion)"
                           : "(tick+texture; excludes MTKView)"))
            if offscreenBenchmark {
                log("PROFILE offscreen ticks=\(tickCount) measured_samples=\(sorted.count)")
            }
            frameWorkMilliseconds.removeAll(keepingCapacity: true)
        }
        if profileFrames, let summary = metalPresenter?.finishProfile() {
            log(summary)
        }
        runtimeMovie.reset()
        movieInput.reset()
        platformDialogs.reset()
        imePreedit.reset()
        preeditUnsupported = false
        gameTextInput = GameTextInputState()
        gameTextCaretPoint = nil
        releaseAllKeys()
        hostInputSuspended = false
        inputSuspended = false
        stopLoop()
        drainEngineLogs()
        recordDiagnostics(["state": failureMessage == nil ? "stopped" : "failed", "closed": ISO8601DateFormatter().string(from: Date()),
                           "ticks": String(tickCount), "frame": "\(Int(frameSize.width))x\(Int(frameSize.height))",
                           "unhandledPlatformRequests": String(unhandledPlatformRequests),
                           "translationState": "\(translationStatus.state)"].merging(pacingDiagnostics) { _, new in new })
        unhandledPlatformRequests = 0
        nativeFrameLease = nil
        nativeFrameTexture = nil
        metalPresenter?.clear()
        session.shutdown()
        renderState.active = false
        log(session.metalBridgeDiagnostics())
        nativeFrameTexture = nil
        nativeRendererEnabled = false
        loggedNativeFrame = false
        frameImage = nil
        sourceFrameImage = nil
        frameSize = .zero
        outputFrameSize = .zero
        metalPresenter?.outputSize = .zero
        appliedSurfaceSize = .zero
        lastStartupState = 0
        metalPresenter?.clear()
        status = "已关闭"
        log("engine destroyed")
    }
}
