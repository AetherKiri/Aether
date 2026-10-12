import Foundation
import CoreVideo

/// Synthetic callback pulses for the pure pacing clock. These checks are what
/// separate "host tick rate" from "engine render rate" and "display scan-out".
enum FrameSchedulerTests {
    static func run() {
        followDisplayKeepsRealElapsed()
        limitedTargetNeverExceedsTargetRate()
        cumulativeSimulationTimeMatchesAcrossPulseRates()
        lateCallbackDropsCatchUpInsteadOfBursting()
        clampAndModeReset()
        targetValidation()
        let failedClock = HostFrameClock(preference: .display, interval: 0.01,
                                        startDisplayLink: { _ in kCVReturnError })
        precondition(failedClock.driver == .displayLink)
        var callbacks = 0
        failedClock.onCallback = { _ in callbacks += 1 }
        failedClock.start()
        precondition(failedClock.driver == .timer && failedClock.fallbackReason?.contains("CVDisplayLinkStart") == true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(callbacks > 0)
        failedClock.stop()
        let stopped = callbacks
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(callbacks == stopped)
        print("PASS: scheduler pacing under 60/120 Hz pulses, real elapsed delta, target rate ceiling, catch-up dropping and target validation")
    }

    /// Feeds callbacks at `hertz` for `seconds`; returns tick count and the
    /// cumulative simulated milliseconds handed to the engine.
    private static func pulse(_ scheduler: inout FrameScheduler, hertz: Double, seconds: Double,
                              from start: Double = 0) -> (ticks: Int, sumMS: Int) {
        let interval = 1.0 / hertz
        let callbacks = Int((seconds * hertz).rounded())
        var now = start
        var ticks = 0
        var sumMS = 0
        for _ in 0...callbacks {
            if let tick = scheduler.tick(now: now) {
                ticks += 1
                sumMS += Int(tick.deltaMS)
            }
            now += interval
        }
        return (ticks, sumMS)
    }

    private static func followDisplayKeepsRealElapsed() {
        var scheduler = FrameScheduler(mode: .followDisplay)
        let result = pulse(&scheduler, hertz: 60, seconds: 2)
        precondition(result.ticks == 121, "follow-display must tick once per callback, got \(result.ticks)")
        precondition((1990...2010).contains(result.sumMS), "cumulative delta must equal real elapsed, got \(result.sumMS)")
        precondition(scheduler.droppedCatchUpIntervals == 0)
    }

    private static func limitedTargetNeverExceedsTargetRate() {
        var scheduler = FrameScheduler(mode: .limited(fps: 80))
        let highRefresh = pulse(&scheduler, hertz: 120, seconds: 2)
        precondition(highRefresh.ticks <= 161, "120 Hz pulses at target 80 must not exceed the target: \(highRefresh.ticks)")
        precondition(highRefresh.ticks >= 158, "120 Hz pulses at target 80 must roughly reach the target: \(highRefresh.ticks)")
        precondition((1990...2010).contains(highRefresh.sumMS), "cumulative delta must stay real elapsed: \(highRefresh.sumMS)")

        var lowRefresh = FrameScheduler(mode: .limited(fps: 80))
        let lowResult = pulse(&lowRefresh, hertz: 60, seconds: 2)
        precondition(lowResult.ticks <= 161, "60 Hz pulses at target 80 must not exceed the target: \(lowResult.ticks)")
        precondition(lowResult.ticks == 121, "a slower callback source paces to its own rate: \(lowResult.ticks)")
        precondition((1990...2010).contains(lowResult.sumMS), "cumulative delta must stay real elapsed: \(lowResult.sumMS)")

        var sixty = FrameScheduler(mode: .limited(fps: 60))
        let sixtyResult = pulse(&sixty, hertz: 120, seconds: 2)
        precondition(sixtyResult.ticks <= 121, "120 Hz pulses at target 60 must not exceed the target: \(sixtyResult.ticks)")
        precondition(sixtyResult.ticks >= 118, "120 Hz pulses at target 60 must roughly reach the target: \(sixtyResult.ticks)")
    }

    private static func cumulativeSimulationTimeMatchesAcrossPulseRates() {
        var sixty = FrameScheduler(mode: .limited(fps: 80))
        var oneTwenty = FrameScheduler(mode: .limited(fps: 80))
        let a = pulse(&sixty, hertz: 60, seconds: 3)
        let b = pulse(&oneTwenty, hertz: 120, seconds: 3)
        // The same story duration must advance the same simulated time; only
        // the callback rate may differ.
        precondition(abs(a.sumMS - b.sumMS) <= 8, "cumulative simulated time diverged: \(a.sumMS) vs \(b.sumMS)")
        precondition(abs(a.sumMS - 3000) <= 10 && abs(b.sumMS - 3000) <= 10, "simulated time must match wall time: \(a.sumMS), \(b.sumMS)")
    }

    private static func lateCallbackDropsCatchUpInsteadOfBursting() {
        var scheduler = FrameScheduler(mode: .limited(fps: 60))
        precondition(scheduler.tick(now: 0)?.firstTickAfterReset == true)
        // Five seconds of sleep/occlusion must not replay as 300 catch-up ticks.
        let late = scheduler.tick(now: 5.0)
        precondition(late != nil, "the first callback after a stall must advance once")
        precondition(late!.deltaMS <= FrameScheduler.maximumDeltaMS, "delta must be clamped: \(late!.deltaMS)")
        precondition(late!.droppedCatchUpIntervals >= 299, "expected dropped intervals, got \(late!.droppedCatchUpIntervals)")
        precondition(scheduler.droppedCatchUpIntervals == late!.droppedCatchUpIntervals)
        let followUp = pulse(&scheduler, hertz: 60, seconds: 1, from: 5.0)
        precondition(followUp.ticks <= 62, "no catch-up burst after a stall: \(followUp.ticks)")
    }

    private static func clampAndModeReset() {
        var scheduler = FrameScheduler(mode: .followDisplay)
        _ = scheduler.tick(now: 0)
        let late = scheduler.tick(now: 12.0)
        precondition(late?.deltaMS == FrameScheduler.maximumDeltaMS, "follow-display delta must clamp: \(late?.deltaMS ?? 0)")
        scheduler.setMode(.limited(fps: 90))
        let afterSwitch = scheduler.tick(now: 12.1)
        precondition(afterSwitch?.firstTickAfterReset == true && afterSwitch?.deltaMS == 0,
                     "mode change must restart timing without a burst")
        scheduler.reset()
        precondition(scheduler.tick(now: 20)?.firstTickAfterReset == true)
    }

    private static func targetValidation() {
        precondition(FrameScheduler.normalizedTarget(60) == 60)
        precondition(FrameScheduler.normalizedTarget(80) == 80)
        precondition(FrameScheduler.normalizedTarget(90) == 90)
        precondition(FrameScheduler.normalizedTarget(120) == 120)
        precondition(FrameScheduler.normalizedTarget(144) == 144)
        for invalid in [0, 30, 59, 75, 100, 143, 165] {
            precondition(FrameScheduler.normalizedTarget(invalid) == nil, "invalid target \(invalid) accepted")
        }
        precondition(FrameScheduler.defaultTargetFPS == 80)
    }
}
