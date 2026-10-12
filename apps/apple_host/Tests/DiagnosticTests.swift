import Foundation

/// Diagnostic profile catalog, settings migration and overlay text.
enum DiagnosticTests {
    static func run(root: URL) throws {
        profileCatalog()
        try settingsMigrationAndValidation(root: root)
        overlayComposition()
        print("PASS: diagnostic profile catalog/availability, schema v6 migration and overlay metric composition")
    }

    private static func profileCatalog() {
        precondition(DiagnosticProfile.allCases.map(\.rawValue)
            == ["off", "baseline", "input", "render", "storage", "script", "audio", "video", "plugin", "system", "full"])
        // Engine option mapping mirrors the Godot profile env.
        precondition(DiagnosticProfile.input.engineOptions.map(\.key) == ["input_trace"])
        precondition(DiagnosticProfile.plugin.engineOptions.map(\.key) == ["plugin_trace"])
        precondition(DiagnosticProfile.full.engineOptions.map(\.key) == ["input_trace", "plugin_trace", "trace_log"])
        precondition(DiagnosticProfile.off.engineOptions.isEmpty && DiagnosticProfile.render.engineOptions.isEmpty)
        // Host sampling flags.
        precondition(DiagnosticProfile.baseline.hostFlags.sampleFrameWork)
        precondition(DiagnosticProfile.render.hostFlags.sampleFrameWork)
        precondition(DiagnosticProfile.input.hostFlags.logInputEvents)
        precondition(DiagnosticProfile.system.hostFlags.sampleSystemInfo)
        precondition(DiagnosticProfile.full.hostFlags
            == HostDiagnosticFlags(sampleFrameWork: true, logInputEvents: true, sampleSystemInfo: true))
        precondition(DiagnosticProfile.off.hostFlags == HostDiagnosticFlags())
        // Categories without an Apple sampling source are reported, not faked.
        for profile in [DiagnosticProfile.storage, .script, .audio, .video] {
            precondition(!profile.hasAppleSampling, "\(profile.rawValue) must not be selectable")
            precondition(profile.unavailableCategories == [profile.rawValue])
        }
        precondition(DiagnosticProfile.full.unavailableCategories == ["storage", "script", "audio", "video"])
        precondition(DiagnosticProfile.full.hasAppleSampling)
        for profile in [DiagnosticProfile.off, .baseline, .input, .render, .plugin, .system, .full] {
            precondition(profile.hasAppleSampling, "\(profile.rawValue) must stay selectable")
        }
        precondition(DiagnosticProfile.baseline.overhead == "low")
        precondition(DiagnosticProfile.full.overhead == "high")
        precondition(DiagnosticProfile.input.overhead == "medium")
        precondition(DiagnosticProfile.baseline.summary.contains("frame-work"))
        precondition(DiagnosticProfile.full.summary.contains("unavailable: storage/script/audio/video"))
        precondition(DebugOverlayMode.allCases.map(\.rawValue) == ["off", "summary", "detail"])
    }

    private static func settingsMigrationAndValidation(root: URL) throws {
        let suite = "aether-diagnostic-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(url: root.appendingPathComponent("diagnostic-settings/settings.json"))
        let fresh = try SettingsStore(url: root.appendingPathComponent("diagnostic-fresh/settings.json"))
            .load(defaults: defaults, legacyPrefix: "diag.")
        precondition(fresh.version == 6)
        precondition(fresh.diagnosticProfile == HostSettings.defaultDiagnosticProfile)
        precondition(fresh.debugOverlayMode == "off")
        // A v5 file has neither field and must migrate without losing values.
        try store.save(fresh)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        json["version"] = 5
        json.removeValue(forKey: "diagnosticProfile")
        json.removeValue(forKey: "debugOverlayMode")
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)
        let upgraded = try store.load(defaults: defaults, legacyPrefix: "diag.")
        precondition(upgraded.version == 6)
        precondition(upgraded.diagnosticProfile == HostSettings.defaultDiagnosticProfile)
        precondition(upgraded.debugOverlayMode == "off")
        precondition(upgraded == fresh)
        // Every profile/overlay pair round-trips.
        for profile in DiagnosticProfile.allCases {
            for mode in DebugOverlayMode.allCases {
                var value = fresh
                value.diagnosticProfile = profile.rawValue
                value.debugOverlayMode = mode.rawValue
                try store.save(value)
                let reloaded = try store.load(defaults: defaults, legacyPrefix: "diag.")
                precondition(reloaded == value && reloaded.profile == profile && reloaded.overlayMode == mode)
            }
        }
        var invalid = fresh
        invalid.diagnosticProfile = "turbo"
        do { try store.save(invalid); preconditionFailure("unknown profile accepted") } catch {}
        invalid = fresh
        invalid.debugOverlayMode = "verbose"
        do { try store.save(invalid); preconditionFailure("unknown overlay accepted") } catch {}
        var unknown = fresh
        unknown.diagnosticProfile = "turbo"
        unknown.debugOverlayMode = "verbose"
        try JSONEncoder().encode(unknown).write(to: store.url)
        let normalized = try store.load(defaults: defaults, legacyPrefix: "diag.")
        precondition(normalized.diagnosticProfile == HostSettings.defaultDiagnosticProfile)
        precondition(normalized.debugOverlayMode == "off")
    }

    private static func overlayComposition() {
        var summary = PerformanceSnapshot()
        summary.mode = "summary"
        summary.backend = "Metal"
        summary.apiVersion = 17_170_432
        summary.textureBackend = "native-texture"
        summary.frameWidth = 640
        summary.frameHeight = 480
        summary.outputWidth = 1440
        summary.outputHeight = 1080
        summary.tickRate = 116.3
        summary.renderRate = 19.1
        summary.presentationRate = 116.3
        summary.frameWorkMS = 1.2
        summary.pacingMode = "limited(target=80 FPS)"
        summary.pacingDriver = "timer"
        summary.pacingTarget = "80"
        summary.maxDeltaMS = 100
        summary.fallback = "none"
        summary.memory = DiagnosticMemory(available: true, appBytes: 320 * 1_048_576,
                                          peakBytes: 340 * 1_048_576, headroomBytes: 12 * 1_073_741_824,
                                          systemFreeBytes: 0, residentBytes: 0, graphicCacheBytes: 32 * 1_048_576,
                                          graphicCacheLimitBytes: 128 * 1_048_576, xp3CacheBytes: 12 * 1_048_576,
                                          psbCacheBytes: 8 * 1_048_576, psbEntries: 128,
                                          psbHits: 92, psbMisses: 8)
        let summaryLines = DiagnosticOverlay.lines(summary)
        let text = summaryLines.joined(separator: "\n")
        precondition(summaryLines.count == 7, "summary line count: \(summaryLines.count)")
        precondition(text.contains("Backend Metal") && text.contains("api v17170432"))
        precondition(text.contains("tick 116.3/s") && text.contains("render 19.1/s") && text.contains("presentation 116.3/s"))
        precondition(text.contains("none is display scan-out FPS"))
        precondition(text.contains("native-texture") && text.contains("frame 640x480") && text.contains("out 1440x1080"))
        precondition(text.contains("Memory App 320.0 MB") && text.contains("Peak 340.0 MB") && text.contains("Headroom 12.0 GB"))
        precondition(text.contains("GPU memory estimate is not available"))
        precondition(!text.contains("p50"), "summary must not include detail-only frame work")
        var detail = summary
        detail.mode = "detail"
        detail.frameWorkP50MS = 1.1
        detail.frameWorkP95MS = 2.4
        detail.frameWorkMaxMS = 6.2
        detail.droppedCatchUp = 101
        detail.coalescedCallbacks = 1136
        detail.pacingResets = 4
        detail.ticks = 2294
        detail.renders = 480
        detail.presentations = 2294
        detail.playSeconds = 52
        let detailLines = DiagnosticOverlay.lines(detail)
        precondition(detailLines.count == summaryLines.count + 4, "detail line count: \(detailLines.count)")
        let detailText = detailLines.joined(separator: "\n")
        precondition(detailText.contains("p50 1.10") && detailText.contains("p95 2.40") && detailText.contains("max 6.20"))
        precondition(detailText.contains("Pacing dropped 101") && detailText.contains("coalesced 1136"))
        precondition(detailText.contains("Session ticks 2294") && detailText.contains("play 52 s"))
        precondition(detailText.contains("Caches graphic 32.0 MB"))
        precondition(DiagnosticOverlay.bytes(0) == "0 B")
        precondition(DiagnosticOverlay.bytes(1023) == "1023 B")
        precondition(DiagnosticOverlay.bytes(1024) == "1.0 KB")
        var off = summary
        off.mode = "off"
        precondition(DiagnosticOverlay.lines(off).isEmpty)
        var translated = summary
        translated.translationState = "ready"
        translated.translationBackend = "cpu"
        translated.translationCompleted = 12
        translated.translationCacheHits = 9
        translated.translationCacheMisses = 1
        let translatedText = DiagnosticOverlay.lines(translated).joined(separator: "\n")
        precondition(translatedText.contains("Translation ready/cpu") && translatedText.contains("hit 90%"))
        var unavailableMemory = summary
        unavailableMemory.memory = DiagnosticMemory()
        precondition(DiagnosticOverlay.lines(unavailableMemory).contains { $0.contains("Memory unavailable") })
        // Without an ABI process headroom the overlay names the system scope.
        var systemFree = summary
        systemFree.memory.headroomBytes = 0
        systemFree.memory.systemFreeBytes = 8 * 1_073_741_824
        precondition(DiagnosticOverlay.lines(systemFree).joined(separator: "\n").contains("System free 8.0 GB"))
    }
}
