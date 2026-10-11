import Foundation

/// Host-side frame pacing policy for the Apple engine loop.
///
/// The product distinguishes three rates that must never be conflated:
/// * tick        - `engine_tick` calls issued by the clock below;
/// * render      - engine ticks whose C++ render step produced a new frame;
/// * presentation - drawable submissions or image publications by the host.
///
/// None of them equals the display scan-out rate. The scheduler only decides
/// how often the host asks the engine to advance, and with which elapsed time.
enum FramePacingMode: Equatable {
    /// Follow the display refresh; the host ticks once per display callback.
    case followDisplay
    /// Target a fixed rate; the host skips callbacks and drops backlog.
    case limited(fps: Int)

    var targetFPS: Int? {
        if case .limited(let fps) = self { return fps }
        return nil
    }

    var description: String {
        switch self {
        case .followDisplay: return "follow-display"
        case .limited(let fps): return "limited(target=\(fps) FPS)"
        }
    }
}

/// One engine advancement decided by `FrameScheduler`.
struct FramePacingTick: Equatable {
    /// Real elapsed host time since the previous engine tick, in milliseconds.
    let deltaMS: UInt32
    /// Target intervals absorbed into this tick instead of being replayed.
    /// Non-zero only after the host fell behind (lifecycle gap, busy frame).
    let droppedCatchUpIntervals: UInt64
    /// True for the first tick after a reset; its delta is always zero.
    let firstTickAfterReset: Bool
}

/// Pure pacing clock. Kept free of AppKit/Metal so unit tests can drive it
/// with synthetic callback pulses at 60/120 Hz.
struct FrameScheduler {
    static let supportedTargets = [60, 80, 90, 120, 144]
    static let defaultTargetFPS = 80
    /// Longest delta handed to the engine in one tick. A longer gap is a
    /// lifecycle stall (sleep, occlusion, debugger), not gameplay time.
    static let maximumDeltaMS: UInt32 = 100

    static func normalizedTarget(_ fps: Int) -> Int? {
        supportedTargets.contains(fps) ? fps : nil
    }

    private(set) var mode: FramePacingMode
    private var previousCallback: TimeInterval?
    private var lastTickTimestamp: TimeInterval?
    private var accumulator: TimeInterval = 0
    private var quantizationRemainderMS: Double = 0
    private(set) var ticksIssued: UInt64 = 0
    private(set) var coalescedCallbacks: UInt64 = 0
    private(set) var droppedCatchUpIntervals: UInt64 = 0
    private(set) var resets: UInt64 = 0
    private(set) var lastDeltaMS: UInt32 = 0

    init(mode: FramePacingMode) { self.mode = mode }

    var targetFPS: Int? { mode.targetFPS }

    var frameInterval: TimeInterval? {
        guard let target = mode.targetFPS else { return nil }
        return 1.0 / Double(max(1, target))
    }

    /// Drops any elapsed time measured before now. Called on loop start, on
    /// every lifecycle transition (focus, hide, minimize, sleep) and on mode
    /// changes so a pause can never turn into a catch-up burst.
    mutating func reset() {
        previousCallback = nil
        lastTickTimestamp = nil
        accumulator = 0
        quantizationRemainderMS = 0
        resets += 1
    }

    mutating func setMode(_ newMode: FramePacingMode) {
        guard newMode != mode else { return }
        mode = newMode
        reset()
    }

    /// Single entry point from the frame clock callback (or the test harness).
    /// Returns nil when this callback must not advance the engine.
    mutating func tick(now: TimeInterval) -> FramePacingTick? {
        guard now.isFinite else { return nil }
        guard let previous = previousCallback else {
            // First callback after start or reset: begin timing honestly with
            // a zero delta instead of replaying the time spent paused.
            previousCallback = now
            lastTickTimestamp = now
            ticksIssued += 1
            lastDeltaMS = 0
            return FramePacingTick(deltaMS: 0, droppedCatchUpIntervals: 0, firstTickAfterReset: true)
        }
        previousCallback = now
        switch mode {
        case .followDisplay:
            ticksIssued += 1
            let delta = quantizeMS(max(0, now - (lastTickTimestamp ?? now)))
            lastTickTimestamp = now
            lastDeltaMS = delta
            return FramePacingTick(deltaMS: delta, droppedCatchUpIntervals: 0, firstTickAfterReset: false)
        case .limited(let fps):
            let interval = 1.0 / Double(max(1, fps))
            accumulator += max(0, now - previous)
            guard accumulator + 1e-9 >= interval else {
                coalescedCallbacks += 1
                return nil
            }
            // One tick per callback: consume every whole interval but issue
            // only one tick, so a backlog becomes a drop, never a burst.
            let wholeIntervals = UInt64(max(1, floor(accumulator / interval)))
            let dropped = wholeIntervals - 1
            droppedCatchUpIntervals += dropped
            accumulator = max(0, accumulator - Double(wholeIntervals) * interval)
            // The delta handed to the engine is the real time since the
            // previous tick, so coalesced callbacks never double-count.
            let delta = quantizeMS(max(0, now - (lastTickTimestamp ?? now)))
            lastTickTimestamp = now
            ticksIssued += 1
            lastDeltaMS = delta
            return FramePacingTick(deltaMS: delta, droppedCatchUpIntervals: dropped, firstTickAfterReset: false)
        }
    }

    /// Quantizes milliseconds while carrying the sub-millisecond remainder, so
    /// rounding never inflates the cumulative simulated time (same approach as
    /// the Godot host's RuntimeTickMillisecondQuantizer).
    private mutating func quantizeMS(_ seconds: TimeInterval) -> UInt32 {
        let exact = seconds * 1000 + quantizationRemainderMS
        guard exact.isFinite, exact > 0 else {
            quantizationRemainderMS = 0
            return 0
        }
        if exact >= Double(Self.maximumDeltaMS) {
            // Lifecycle stall: clamp and drop the excess instead of replaying.
            quantizationRemainderMS = 0
            return Self.maximumDeltaMS
        }
        let rounded = exact.rounded()
        quantizationRemainderMS = exact - rounded
        return UInt32(max(0, rounded))
    }
}
