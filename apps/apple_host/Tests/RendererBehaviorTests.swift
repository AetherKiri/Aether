import AppKit

/// Real engine sessions with injected failure boundaries, not fabricated UI state.
enum RendererBehaviorTests {
    @MainActor static func run(root: URL) throws {
        // Renderer tests must not inherit benchmark/presentation overrides.
        for key in ["AETHER_HOST_RENDERER", "AETHER_HOST_OUTPUT_RESOLUTION", "AETHER_HOST_SAMPLING_ALGORITHM", "AETHER_HOST_PRESENTATION", "AETHER_HOST_BENCHMARK", "AETHER_HOST_DIRECT_RENDER"] {
            unsetenv(key)
        }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("demos/aetherkiri-kag3/data")
        let demo = root.appendingPathComponent("render-demo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: demo)

        let noDevice = EngineController(presenterFactory: { throw EngineController.SetupFailure.noDevice })
        precondition(!noDevice.capabilities.nativeMetal.available)
        precondition(noDevice.capabilities.nativeMetal.reasonKey == "metalDeviceUnavailable")
        precondition(noDevice.capabilities.enhancement.available == false)
        precondition(noDevice.initializeEngine(renderer: "metal"))
        check(noDevice, requested: .metal, effective: .software, presentation: .image, reason: "metalDeviceUnavailable")
        precondition(noDevice.hostSettings.renderer == "metal", "fallback must retain next-launch preference")
        try playUntilFrame(noDevice, demo: demo, root: root)
        precondition(noDevice.frameImage?.width == Int(noDevice.outputFrameSize.width))
        precondition(noDevice.frameImage?.height == Int(noDevice.outputFrameSize.height))
        precondition(noDevice.outputFrameSize == RenderGeometry.fit(noDevice.frameSize, within: CGSize(width: 1920, height: 1080)))
        noDevice.shutdown()
        precondition(!noDevice.renderState.active)

        let noPresenter = EngineController(presenterFactory: {
            throw NSError(domain: "RendererTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "pipeline compile failed"])
        })
        precondition(noPresenter.capabilities.nativeMetal.reasonKey == "metalPresenterUnavailable")
        precondition(noPresenter.initializeEngine(renderer: "metal"))
        check(noPresenter, requested: .metal, effective: .software, presentation: .image, reason: "metalPresenterUnavailable")
        noPresenter.shutdown()
        precondition(noPresenter.initializeEngine(renderer: "software"))
        check(noPresenter, requested: .software, effective: .software, presentation: .image, reason: nil)
        precondition(!noPresenter.initializeEngine(renderer: "metal"), "must reject double initialization")
        precondition(noPresenter.renderState.effective == .software && noPresenter.renderState.active)
        noPresenter.shutdown()
        precondition(!noPresenter.initializeEngine(renderer: "invalid"))
        precondition(!noPresenter.renderState.active)

        let unsupported = EngineController(metalActivation: { _ in
            throw NSError(domain: "AetherEngineOption", code: -3, userInfo: [NSLocalizedDescriptionKey: "native runtime unsupported"])
        })
        precondition(unsupported.capabilities.nativeMetal.available, "this Mac needs Metal for native lifecycle tests")
        precondition(unsupported.initializeEngine(renderer: "metal"))
        check(unsupported, requested: .metal, effective: .software, presentation: .metal, reason: "metalRuntimeUnsupported")
        unsupported.shutdown()

        var activations = 0
        setenv("AETHER_HOST_DIRECT_RENDER", "1", 1)
        defer { unsetenv("AETHER_HOST_DIRECT_RENDER") }
        let partial = EngineController(metalActivation: { session in
            // Acquire the real render generation and change the backend before failing.
            try session.enableMetalRenderer()
            activations += 1
            if activations <= 2 {
                throw NSError(domain: "RendererTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "failure after native activation"])
            }
        })
        for attempt in 1...2 {
            precondition(partial.initializeEngine(renderer: "metal"))
            precondition(activations == attempt)
            check(partial, requested: .metal, effective: .software, presentation: .metal, reason: "metalInitializationFailed")
            if attempt == 1 { try playUntilFrame(partial, demo: demo, root: root) }
            partial.shutdown()
        }
        // A succeeding native session proves partial generations were released.
        precondition(partial.initializeEngine(renderer: "metal"))
        precondition(activations == 3)
        check(partial, requested: .metal, effective: .metal, presentation: .metal, reason: nil)
        try playUntilFrame(partial, demo: demo, root: root)
        partial.presentationFailed("injected drawable failure")
        check(partial, requested: .metal, effective: .metal, presentation: .image, reason: "metalPresentationFailed")
        precondition(partial.nativeFrameLease == nil && partial.nativeFrameTexture == nil)
        let ticks = partial.tickCount
        let deadline = Date().addingTimeInterval(3)
        while (partial.tickCount <= ticks || partial.frameImage == nil) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(partial.tickCount > ticks && partial.frameImage != nil, "display fallback must keep the game running")
        partial.presentationFailed("duplicate callback")
        precondition(partial.renderState.fallbacks.count == 1)
        partial.shutdown()
        precondition(partial.logText.contains("leases_live=0") && partial.logText.contains("render_generation=0"))
        let acquired = partial.logText.components(separatedBy: "leases_acquired=").last?.prefix(while: { $0.isNumber }) ?? ""
        precondition((Int(acquired) ?? 0) > 0, "test must exercise direct frame leases")
        precondition(partial.initializeEngine(renderer: "metal"))
        precondition(activations == 4 && partial.useMetalPresentation)
        check(partial, requested: .metal, effective: .metal, presentation: .metal, reason: nil)
        partial.shutdown()

        let display = EngineController()
        display.hostSettings.canvasMode = "display"
        display.hostSettings.outputResolution = "original"
        display.updateDisplayPixels(CGSize(width: 2000, height: 1000))
        precondition(display.initializeEngine(renderer: "metal"))
        try playUntilFrame(display, demo: demo, root: root)
        let native = display.frameSize
        precondition(display.outputFrameSize == RenderGeometry.fit(native, within: CGSize(width: 2000, height: 1000)))
        display.updateDisplayPixels(CGSize(width: 800, height: 600))
        precondition(display.frameSize == native && display.outputFrameSize == RenderGeometry.fit(native, within: CGSize(width: 800, height: 600)))
        display.hostSettings.outputResolution = "4k" // next launch only
        display.updateDisplayPixels(CGSize(width: 1600, height: 900))
        precondition(display.outputFrameSize == RenderGeometry.fit(native, within: CGSize(width: 1600, height: 900)))
        precondition(display.diagnostics.metadata["logicalCanvas"] == "\(Int(native.width))x\(Int(native.height))")
        display.shutdown()

        let probe = AetherEngineSession()
        precondition(partial.textTranslationAvailable == probe.isTextTranslationAvailable())
        try probe.initialize(writablePath: root.path, cachePath: root.path)
        do {
            try probe.setOption("frame_output", value: "invalid")
            preconditionFailure("invalid frame_output must be rejected by the actual ABI")
        } catch {
            let detail = error as NSError
            precondition(detail.domain == "AetherEngineOption" && detail.code == -1)
            precondition(detail.localizedDescription.contains("frame_output"))
        }
        probe.shutdown()
        print("PASS: device/presenter/runtime/partial-activation fallback, real software/native game frames, display fallback continuity, generation cleanup, retry and diagnostic persistence")
    }

    @MainActor private static func check(_ engine: EngineController, requested: HostRenderer,
                                         effective: HostRenderer, presentation: HostPresentation, reason: String?) {
        precondition(engine.renderState.requested == requested && engine.renderState.effective == effective)
        precondition(engine.renderState.presentation == presentation && engine.renderState.active)
        precondition(engine.renderState.fallbacks.map(\.reasonKey) == reason.map { [$0] } ?? [])
        let persisted = try! JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: engine.diagnostics.root.appendingPathComponent("session.json")))
        for (key, value) in engine.renderState.diagnostics {
            precondition(engine.diagnostics.metadata[key] == value && persisted[key] == value)
        }
    }

    @MainActor private static func playUntilFrame(_ engine: EngineController, demo: URL, root: URL) throws {
        // Deliberately initialize before openAndRun: its new diagnostic session
        // must retain requested/effective/presentation and fallback details.
        precondition(engine.openAndRun(gamePath: demo.path))
        let deadline = Date().addingTimeInterval(5)
        while (engine.frameSize == .zero || engine.tickCount < 15 || !engine.logText.contains("startup state: SUCCEEDED")) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(engine.frameSize.width > 0 && engine.frameSize.height > 0 && engine.tickCount > 0)
        precondition(engine.failureMessage == nil, engine.failureMessage ?? "game failed")
        precondition(engine.logText.contains("startup state: SUCCEEDED"), "test must reach successful game startup")
        for (key, value) in engine.renderState.diagnostics { precondition(engine.diagnostics.metadata[key] == value) }
        let report = root.appendingPathComponent("render-diagnostics.txt")
        try engine.diagnostics.export(to: report, context: [:])
        let text = try String(contentsOf: report)
        for (key, value) in engine.renderState.diagnostics { precondition(text.contains(key + ": " + value)) }
    }
}
