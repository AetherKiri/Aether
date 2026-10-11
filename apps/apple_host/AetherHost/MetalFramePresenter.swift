import CoreGraphics
import MetalKit
import SwiftUI

/// Decides when the presenter must not ask for a drawable.
///
/// CAMetalLayer's nextDrawable() always blocks until a drawable is free and
/// only gives up after a one second timeout (measured: a ~930ms main-thread
/// stall when the window could not present). There is no non-blocking variant
/// (allowsNextDrawableTimeout = NO waits forever), so the presenter skips the
/// request whenever the window cannot produce frames.
enum PresentationGate {
    struct State: Equatable {
        var suspended = false
        var hasWindow = true
        var windowVisible = true
        var windowMiniaturized = false
        var windowOccluded = false
        var drawableWidth = 0
        var drawableHeight = 0
    }

    /// Nil when a drawable may be requested; otherwise the pause reason.
    static func blockedReason(_ state: State) -> String? {
        if state.suspended { return "presenter suspended" }
        if !state.hasWindow { return "no window" }
        if !state.windowVisible { return "window hidden" }
        if state.windowMiniaturized { return "window minimized" }
        if state.windowOccluded { return "window occluded" }
        if state.drawableWidth < 1 || state.drawableHeight < 1 { return "empty drawable" }
        return nil
    }
}

// Metal presentation shared by P0 software uploads and P2 native textures.
final class MetalFramePresenter: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let debugLabels: Bool
    private(set) var texture: MTLTexture?
    private var frameLease: AetherMetalFrameLease?
    private(set) var lastError: String?
    let directPresentation = ProcessInfo.processInfo.environment["AETHER_HOST_SCHEDULING"] != "deferred"
    private weak var presentationView: MTKView?
    private var suspended = false
    private(set) var skippedDraws = 0
    private var lastGateReason: String?
    /// Reports presentation pause/resume transitions (host logging).
    var onGateChange: ((String) -> Void)?

    func attach(_ view: MTKView) { presentationView = view }
    func detach(_ view: MTKView) {
        if presentationView === view { presentationView = nil }
    }

    /// Stops requesting drawables (session shutdown, window teardown).
    func suspend() {
        suspended = true
        pendingProfile = nil
    }

    func resume() {
        suspended = false
        skippedDraws = 0
        lastGateReason = nil
    }

    // Called once per engine tick on the main thread. SwiftUI handles layout,
    // but no longer schedules the frame upload/draw on a later run-loop turn.
    func presentFrame(native: MTLTexture?, lease: AetherMetalFrameLease? = nil, image: CGImage?) throws {
        guard directPresentation else { return }
        if let lease { useNativeFrame(lease) }
        else if let native { useNativeTexture(native) }
        else if let image { try upload(image) }
        else { clear() }
        presentationView?.draw()
    }


    // A tick can be coalesced by SwiftUI; only a drawable actually submitted
    // for that tick contributes a sample. Monotonic CPU completion includes
    // main-run-loop scheduling, upload, drawable acquisition and GPU queue wait.
    private var pendingProfile: (tick: UInt64, start: Double)?
    private var lastProfiledTick: UInt64?
    private let profileLock = NSLock()
    private var profileGeneration: UInt64 = 0
    private var profileRows: [String] = []
    private var profileDurations: [Double] = []

    func profileFrame(tick: UInt64, started: Double) {
        pendingProfile = (tick, started)
    }

    func resetProfile() {
        pendingProfile = nil
        lastProfiledTick = nil
        profileLock.lock()
        profileGeneration &+= 1
        profileRows.removeAll(keepingCapacity: true)
        profileDurations.removeAll(keepingCapacity: true)
        profileLock.unlock()
    }

    func finishProfile() -> String? {
        profileLock.lock()
        let rows = profileRows
        let sorted = profileDurations.sorted()
        profileLock.unlock()
        guard !sorted.isEmpty else { return nil }
        if let dir = ProcessInfo.processInfo.environment["AETHER_HOST_CAPTURE_DIR"] {
            let header = "tick,drawable_width,drawable_height,tick_to_completion_ms,gpu_ms,tick_to_draw_ms,drawable_acquire_ms,encode_ms\n"
            try? (header + rows.joined(separator: "\n") + "\n").write(
                toFile: dir + "/aetherhost-presentation.csv", atomically: true, encoding: .utf8)
        }
        return String(format: "PROFILE tick-to-gpu-completion samples=%d p50_ms=%.3f p95_ms=%.3f max_ms=%.3f over_16_6=%d (includes MTKView; excludes scanout; coalesced ticks omitted)",
                      sorted.count, sorted[(sorted.count - 1) / 2],
                      sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!,
                      sorted.filter { $0 > 16.6 }.count)
    }

    enum Failure: Error { case unavailable, unsupportedFrame, allocation, encoding }

    init(device: MTLDevice, commandQueue: MTLCommandQueue? = nil) throws {
        self.device = device
        self.debugLabels = ProcessInfo.processInfo.environment["AETHER_HOST_METAL_DEBUG"] == "1"
        guard let queue = commandQueue ?? device.makeCommandQueue(),
              queue.device.registryID == device.registryID else { throw Failure.unavailable }
        self.queue = queue
        if debugLabels { queue.label = "AetherHost.shared-metal" }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex frame_vertex(uint id [[vertex_id]]) {
            const float2 p[] = {float2(-1, 1), float2(3, 1), float2(-1, -3)};
            const float2 uv[] = {float2(0, 0), float2(2, 0), float2(0, 2)};
            return {float4(p[id], 0, 1), uv[id]};
        }
        fragment float4 frame_fragment(Vertex v [[stage_in]],
                                       texture2d<float> frame [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge,
                                filter::linear);
            // Engine images use premultiplied RGBA. Composite on opaque black
            // without applying alpha again or introducing sRGB conversion.
            return float4(frame.sample(s, v.uv).rgb, 1);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "frame_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "frame_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    func upload(_ image: CGImage) throws {
        // EngineSession.copyFrameImage owns this exact RGBA contract. Reject
        // other layouts rather than silently swapping channels/alpha.
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.alphaInfo == .premultipliedLast,
              image.bitmapInfo.intersection(.byteOrderMask).rawValue == 0,
              image.bytesPerRow >= image.width * 4,
              let data = image.dataProvider?.data,
              CFDataGetLength(data) >= image.bytesPerRow * image.height,
              let bytes = CFDataGetBytePtr(data) else { throw Failure.unsupportedFrame }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: image.width, height: image.height,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        // Each uploaded frame is immutable. Command buffers retain older
        // textures until GPU completion, so CPU writes never race sampling.
        guard let next = device.makeTexture(descriptor: descriptor) else {
            throw Failure.allocation
        }
        next.replace(region: MTLRegionMake2D(0, 0, image.width, image.height),
                     mipmapLevel: 0, withBytes: bytes, bytesPerRow: image.bytesPerRow)
        frameLease = nil
        texture = next
        lastError = nil
    }

    func useNativeTexture(_ next: MTLTexture) {
        frameLease = nil
        texture = next
        lastError = nil
    }

    func useNativeFrame(_ frame: AetherMetalFrameLease) {
        guard frame.valid, let next = frame.texture else { clear(); return }
        frameLease = frame
        texture = next
        lastError = nil
    }

    func clear() { texture = nil; frameLease = nil }

    // Shared by onscreen rendering and deterministic offscreen verification.
    func encode(target: MTLTexture, command: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw Failure.encoding
        }
        if debugLabels { encoder.label = "AetherHost.frame-encode" }
        if let texture {
            let scale = min(Double(target.width) / Double(texture.width),
                            Double(target.height) / Double(texture.height))
            let width = Double(texture.width) * scale
            let height = Double(texture.height) * scale
            encoder.setViewport(MTLViewport(
                originX: (Double(target.width) - width) / 2,
                originY: (Double(target.height) - height) / 2,
                width: width, height: height, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
    }

    func draw(in view: MTKView) {
        if let reason = gateReason(view) {
            // Never wait on nextDrawable for a window that cannot present; the
            // frame is dropped and the next tick retries.
            pendingProfile = nil
            skippedDraws += 1
            if lastGateReason != reason {
                lastGateReason = reason
                onGateChange?("presentation paused: \(reason)")
            }
            return
        }
        if lastGateReason != nil {
            lastGateReason = nil
            onGateChange?("presentation resumed after \(skippedDraws) skipped draws")
        }
        let drawStarted = ProcessInfo.processInfo.systemUptime
        guard let drawable = view.currentDrawable else { return }
        let command: MTLCommandBuffer?
        if frameLease != nil {
            command = AetherMetalBridgePresentationCommand()
        } else {
            command = queue.makeCommandBuffer()
        }
        guard let command else { return }
        if debugLabels { command.label = "AetherHost.present-frame" }
        let acquired = ProcessInfo.processInfo.systemUptime
        do {
            try encode(target: drawable.texture, command: command)
            command.present(drawable)
            let encoded = ProcessInfo.processInfo.systemUptime
            if let sample = pendingProfile, sample.tick > 60,
               lastProfiledTick != sample.tick {
                lastProfiledTick = sample.tick
                let width = drawable.texture.width
                let height = drawable.texture.height
                profileLock.lock()
                let generation = profileGeneration
                profileLock.unlock()
                command.addCompletedHandler { [weak self] completed in
                    guard let self, completed.status == .completed else { return }
                    let elapsed = (ProcessInfo.processInfo.systemUptime - sample.start) * 1000
                    let gpu = (completed.gpuEndTime - completed.gpuStartTime) * 1000
                    self.profileLock.lock()
                    if self.profileGeneration == generation, self.profileRows.count < 10_000 {
                        self.profileDurations.append(elapsed)
                        self.profileRows.append(String(format: "%llu,%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f",
                                                       sample.tick, width, height, elapsed, gpu,
                                                       (drawStarted - sample.start) * 1000,
                                                       (acquired - drawStarted) * 1000,
                                                       (encoded - acquired) * 1000))
                    }
                    self.profileLock.unlock()
                }
            }
            command.addCompletedHandler { [weak self] completed in
                if let error = completed.error {
                    let message = error.localizedDescription
                    DispatchQueue.main.async { self?.lastError = message }
                }
            }
            if let frameLease {
                guard frameLease.submitCommand(command) else { throw Failure.encoding }
                // The completion handler installed by submitCommand retains
                // the lease until GPU completion. Release the presenter-side
                // ownership immediately so the producer can reuse the source
                // texture on the next tick without a defensive detach copy.
                self.frameLease = nil
            } else { command.commit() }
        } catch {
            lastError = String(describing: error)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay(view.bounds)
    }

    /// Current blockers for requesting a drawable (see PresentationGate).
    private func gateReason(_ view: MTKView) -> String? {
        let window = view.window
        let state = PresentationGate.State(
            suspended: suspended,
            hasWindow: window != nil,
            windowVisible: window?.isVisible ?? false,
            windowMiniaturized: window?.isMiniaturized ?? false,
            windowOccluded: window.map { !$0.occlusionState.contains(.visible) } ?? true,
            drawableWidth: Int(view.drawableSize.width),
            drawableHeight: Int(view.drawableSize.height))
        return PresentationGate.blockedReason(state)
    }

    func renderOffscreen(width: Int, height: Int, waitForCompletion: Bool = true) throws -> [UInt8] {
        guard width > 0, height > 0 else { throw Failure.allocation }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let target = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { throw Failure.allocation }
        try encode(target: target, command: command)
        if let frameLease {
            guard frameLease.submitCommand(command) else { throw Failure.encoding }
        } else { command.commit() }
        guard waitForCompletion else { return [] }
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }
}

struct MetalFrameView: NSViewRepresentable {
    let presenter: MetalFramePresenter
    let image: CGImage?
    var nativeTexture: MTLTexture? = nil
    var nativeLease: AetherMetalFrameLease? = nil
    let onFailure: (String) -> Void

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: presenter.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // Development-only fixed output resolution; game/input coordinates
        // still use the original frame size. Measures a real onscreen target.
        if ProcessInfo.processInfo.environment["AETHER_HOST_DRAWABLE_1080P"] == "1" {
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: 1920, height: 1080)
        }
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = presenter
        presenter.attach(view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        if let error = presenter.lastError {
            DispatchQueue.main.async { onFailure(error) }
            return
        }
        guard !presenter.directPresentation else { return }
        do {
            if let nativeLease {
                presenter.useNativeFrame(nativeLease)
            } else if let nativeTexture {
                presenter.useNativeTexture(nativeTexture)
            } else if let image {
                try presenter.upload(image)
            } else {
                presenter.clear()
            }
            view.setNeedsDisplay(view.bounds)
        } catch {
            // Defer published-state mutation until SwiftUI finishes updating.
            DispatchQueue.main.async { onFailure(String(describing: error)) }
        }
    }

    static func dismantleNSView(_ view: MTKView, coordinator: ()) {
        (view.delegate as? MetalFramePresenter)?.detach(view)
        view.delegate = nil
    }
}
