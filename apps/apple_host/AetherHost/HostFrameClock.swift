import CoreVideo
import Foundation

/// Requested callback source for the engine tick loop.
enum FrameClockPreference: String {
    /// Prefer the display refresh link, fall back to a run-loop timer.
    case automatic
    /// Require a display link; still falls back with a recorded reason.
    case display = "display"
    /// Force the run-loop timer (no active display, offscreen hosts, tests).
    case timer

    init(environmentValue: String?) {
        switch environmentValue?.lowercased() {
        case "display", "displaylink", "display-link": self = .display
        case "timer": self = .timer
        default: self = .automatic
        }
    }
}

/// Callback source for the host tick loop.
///
/// The display link is preferred so the unrestricted path follows the screen
/// refresh instead of a fixed 60 Hz timer. When no active display is available
/// (offscreen hosts, headless machines, explicit override) the clock falls back
/// to a run-loop timer whose interval the controller derives from the target
/// rate or the display refresh rate.
final class HostFrameClock {
    enum Driver: String {
        case displayLink = "display-link"
        case timer
    }

    private(set) var driver: Driver = .timer
    private(set) var fallbackReason: String?
    private let preference: FrameClockPreference
    private let interval: TimeInterval
    private let startDisplayLink: (CVDisplayLink) -> CVReturn
    private var link: CVDisplayLink?
    private var timer: Timer?
    private var started = false
    private let coalescingLock = NSLock()
    private var pendingCallback = false
    private var pendingTimestamp: TimeInterval = 0

    /// Called on the main thread with a monotonic host timestamp in seconds.
    var onCallback: ((TimeInterval) -> Void)?

    init(preference: FrameClockPreference, interval: TimeInterval,
         startDisplayLink: @escaping (CVDisplayLink) -> CVReturn = CVDisplayLinkStart) {
        self.startDisplayLink = startDisplayLink
        self.preference = preference
        self.interval = min(1.0, max(1.0 / 1000.0, interval))
        guard preference != .timer else { return }
        var created: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard status == kCVReturnSuccess, let created else {
            fallbackReason = "CVDisplayLinkCreateWithActiveCGDisplays status \(status)"
            return
        }
        let handlerStatus = CVDisplayLinkSetOutputHandler(created) { [weak self] _, _, _, _, _ in
            self?.enqueueDisplayLinkCallback()
            return kCVReturnSuccess
        }
        guard handlerStatus == kCVReturnSuccess else {
            fallbackReason = "CVDisplayLinkSetOutputHandler status \(handlerStatus)"
            return
        }
        link = created
        driver = .displayLink
    }

    deinit { stop() }

    var isRunning: Bool { started }

    func start() {
        guard !started else { return }
        started = true
        if let link {
            let status = startDisplayLink(link)
            if status == kCVReturnSuccess { return }
            fallbackReason = "CVDisplayLinkStart status \(status)"
            self.link = nil
            driver = .timer
        }
        // Run-loop timer fallback: same callback contract, coarser source.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.onCallback?(ProcessInfo.processInfo.systemUptime)
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard started else { return }
        started = false
        if let link {
            CVDisplayLinkStop(link)
        }
        timer?.invalidate()
        timer = nil
    }

    /// Coalesces display-link callbacks so a busy main thread cannot replay a
    /// backlog of ticks after it catches up.
    private func enqueueDisplayLinkCallback() {
        let now = ProcessInfo.processInfo.systemUptime
        coalescingLock.lock()
        pendingTimestamp = now
        if pendingCallback {
            coalescingLock.unlock()
            return
        }
        pendingCallback = true
        coalescingLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coalescingLock.lock()
            let timestamp = self.pendingTimestamp
            self.pendingCallback = false
            self.coalescingLock.unlock()
            guard self.started else { return }
            self.onCallback?(timestamp)
        }
    }
}
