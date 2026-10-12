import Foundation

/// Engine memory/cache accounting shown by the overlay.
///
/// `graphic/XP3/PSB` are the engine's own caches; a separate GPU estimate is
/// not available in this build, so the overlay says so instead of guessing.
struct DiagnosticMemory: Equatable {
    var available = false
    var appBytes: UInt64 = 0
    var peakBytes: UInt64 = 0
    var headroomBytes: UInt64 = 0
    var systemFreeBytes: UInt64 = 0
    var residentBytes: UInt64 = 0
    var graphicCacheBytes: UInt64 = 0
    var graphicCacheLimitBytes: UInt64 = 0
    var xp3CacheBytes: UInt64 = 0
    var psbCacheBytes: UInt64 = 0
    var psbEntries: Int = 0
    var psbHits: UInt64 = 0
    var psbMisses: UInt64 = 0
}

/// One overlay refresh. Field names keep the measurement layer explicit:
/// tick = host `engine_tick` calls, render = ticks whose engine render step
/// produced a frame, presentation = drawable submissions / image publications.
struct PerformanceSnapshot: Equatable {
    var mode = "off"
    var backend = "-"
    var apiVersion: UInt32 = 0
    var textureBackend = "-"
    var frameWidth = 0
    var frameHeight = 0
    var outputWidth = 0
    var outputHeight = 0
    var fallback = "none"
    var errorCount = 0
    var tickRate = 0.0
    var renderRate = 0.0
    var presentationRate = 0.0
    var frameWorkMS = 0.0
    var frameWorkP50MS = 0.0
    var frameWorkP95MS = 0.0
    var frameWorkMaxMS = 0.0
    var pacingMode = "-"
    var pacingDriver = "-"
    var pacingState = "active"
    var pacingTarget = "-"
    var droppedCatchUp: UInt64 = 0
    var coalescedCallbacks: UInt64 = 0
    var pacingResets: UInt64 = 0
    var maxDeltaMS: UInt32 = 0
    var ticks: UInt64 = 0
    var renders: UInt64 = 0
    var presentations: UInt64 = 0
    var playSeconds = 0
    var memory = DiagnosticMemory()
    var translationState = "off"
    var translationBackend = "-"
    var translationJobs = 0
    var translationCompleted: UInt64 = 0
    var translationFailed: UInt64 = 0
    var translationCacheHits: UInt64 = 0
    var translationCacheMisses: UInt64 = 0
}

/// Godot's overlay text is English technical output; the Apple overlay keeps
/// the same metric names so tick/render/presentation never blur together.
enum DiagnosticOverlay {
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        return index == 0 ? "\(Int(amount)) B" : String(format: "%.1f %@", amount, units[index])
    }

    static func lines(_ snapshot: PerformanceSnapshot) -> [String] {
        guard snapshot.mode != "off" else { return [] }
        var lines: [String] = []
        lines.append(String(format: "Backend %@ · api v%d · texture %@ · frame %dx%d · out %dx%d",
                            snapshot.backend, Int(snapshot.apiVersion), snapshot.textureBackend,
                            snapshot.frameWidth, snapshot.frameHeight, snapshot.outputWidth, snapshot.outputHeight))
        lines.append(String(format: "tick %.1f/s · render %.1f/s · presentation %.1f/s",
                            snapshot.tickRate, snapshot.renderRate, snapshot.presentationRate))
        lines.append("tick = host engine_tick calls; render = ticks that produced a frame; presentation = drawable submissions / image publications; none is display scan-out FPS")
        lines.append(String(format: "Frame %.2f ms · pacing %@ (%@) · target %@ · max delta %d ms",
                            snapshot.frameWorkMS, snapshot.pacingMode, snapshot.pacingDriver,
                            snapshot.pacingTarget, Int(snapshot.maxDeltaMS)))
        lines.append("Fallback \(snapshot.fallback) · errors \(snapshot.errorCount)")
        if snapshot.memory.available {
            let spare = snapshot.memory.headroomBytes > 0
                ? "Headroom " + bytes(snapshot.memory.headroomBytes)
                : "System free " + bytes(snapshot.memory.systemFreeBytes)
            lines.append(String(format: "Memory App %@ · Peak %@ · %@ · Cache %@ (engine graphic/XP3/PSB)",
                                bytes(snapshot.memory.appBytes), bytes(snapshot.memory.peakBytes),
                                spare, bytes(cacheBytes(snapshot.memory))))
            lines.append("GPU memory estimate is not available in this build; Cache counts engine caches, not VRAM")
        } else {
            lines.append("Memory unavailable: the engine did not report memory stats")
        }
        if snapshot.translationState != "off" {
            let requests = snapshot.translationCacheHits + snapshot.translationCacheMisses
            let hit = requests > 0 ? Double(snapshot.translationCacheHits) * 100 / Double(requests) : 0
            lines.append(String(format: "Translation %@/%@ · jobs %d · done %d · failed %d · cache %d/%d (hit %.0f%%)",
                                snapshot.translationState, snapshot.translationBackend, snapshot.translationJobs,
                                Int(snapshot.translationCompleted), Int(snapshot.translationFailed),
                                Int(snapshot.translationCacheHits), Int(snapshot.translationCacheMisses), hit))
        }
        guard snapshot.mode == "detail" else { return lines }
        lines.append(String(format: "Frame work p50 %.2f · p95 %.2f · max %.2f ms (host tick+texture work)",
                            snapshot.frameWorkP50MS, snapshot.frameWorkP95MS, snapshot.frameWorkMaxMS))
        lines.append(String(format: "Pacing dropped %d · coalesced %d · resets %d · state %@",
                            Int(snapshot.droppedCatchUp), Int(snapshot.coalescedCallbacks),
                            Int(snapshot.pacingResets), snapshot.pacingState))
        lines.append(String(format: "Session ticks %d · renders %d · presentations %d · play %d s",
                            Int(snapshot.ticks), Int(snapshot.renders), Int(snapshot.presentations), snapshot.playSeconds))
        if snapshot.memory.available {
            let psbRequests = snapshot.memory.psbHits + snapshot.memory.psbMisses
            let hit = psbRequests > 0 ? Double(snapshot.memory.psbHits) * 100 / Double(psbRequests) : 0
            lines.append(String(format: "Caches graphic %@ / %@ · XP3 %@ · PSB %@ (%d entries, %.0f%% hit)",
                                bytes(snapshot.memory.graphicCacheBytes), bytes(snapshot.memory.graphicCacheLimitBytes),
                                bytes(snapshot.memory.xp3CacheBytes), bytes(snapshot.memory.psbCacheBytes),
                                snapshot.memory.psbEntries, hit))
        }
        return lines
    }

    private static func cacheBytes(_ memory: DiagnosticMemory) -> UInt64 {
        memory.graphicCacheBytes + memory.xp3CacheBytes + memory.psbCacheBytes
    }
}
