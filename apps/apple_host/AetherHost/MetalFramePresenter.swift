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
    private let sharpenPipeline: MTLRenderPipelineState
    private let rcasPipeline: MTLRenderPipelineState
    private let debugLabels: Bool
    private(set) var texture: MTLTexture?
    private var frameLease: AetherMetalFrameLease?
    var outputSize: CGSize = .zero
    var samplingAlgorithm: SamplingAlgorithm = .bicubic {
        didSet {
            if oldValue != samplingAlgorithm { outputRevision = nil }
        }
    }
    private var outputTexture: MTLTexture?
    private var frameRevision: UInt64 = 0
    private var outputRevision: UInt64?
    private var enhancedTexture: MTLTexture?
    private var enhancedRevision: UInt64?
    /// The algorithm and amount baked into `enhancedTexture`. The scratch
    /// texture is only valid for one source revision and one configuration, so
    /// switching algorithms on a static frame must re-run the pass.
    private var enhancedConfig: (FrameEnhancement, Float)?
    private(set) var outputPassCount = 0
    /// Frame enhancement applied after the output scaling pass. Only algorithms
    /// with a verified kernel are exposed; the Godot provider's private shaders
    /// cannot be reused by this Metal path.
    var enhancement: FrameEnhancement = .off
    var enhancementAmount: Double = 0.5
    private(set) var lastError: String?
    let directPresentation = ProcessInfo.processInfo.environment["AETHER_HOST_SCHEDULING"] != "deferred"
    private weak var presentationView: MTKView?
    private var suspended = false
    private(set) var skippedDraws = 0
    /// Drawable submissions actually encoded and presented. This is a
    /// submission counter, not the display scan-out rate.
    private(set) var presentedFrameCount: UInt64 = 0
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
        presentedFrameCount = 0
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
        float4 sample_point(texture2d<float> frame, float2 uv) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge,
                                filter::nearest);
            return frame.sample(s, clamp(uv, float2(0), float2(1)));
        }
        float4 sample_linear(texture2d<float> frame, float2 uv) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge,
                                filter::linear);
            return frame.sample(s, clamp(uv, float2(0), float2(1)));
        }
        float4 cubic_weights(float v) {
            float v2 = v * v;
            float v3 = v2 * v;
            return float4(-0.5 * v3 + v2 - 0.5 * v,
                          1.5 * v3 - 2.5 * v2 + 1.0,
                          -1.5 * v3 + 2.0 * v2 + 0.5 * v,
                          0.5 * v3 - 0.5 * v2);
        }
        float4 sample_bicubic(texture2d<float> frame, float2 uv) {
            float2 texel = 1.0 / float2(frame.get_width(), frame.get_height());
            float2 coord = uv / texel - float2(0.5);
            float2 base = floor(coord);
            float2 fraction = fract(coord);
            float4 weights_x = cubic_weights(fraction.x);
            float4 weights_y = cubic_weights(fraction.y);
            float4 color = float4(0);
            for (int y = 0; y < 4; y++) {
                for (int x = 0; x < 4; x++) {
                    float2 sample_uv = (base + float2(float(x - 1), float(y - 1)) + float2(0.5)) * texel;
                    color += sample_point(frame, sample_uv) * weights_x[x] * weights_y[y];
                }
            }
            return float4(clamp(color.rgb, float3(0), float3(1)), 1);
        }
        float sinc(float value) {
            float distance = abs(value);
            if (distance < 0.0001) return 1.0;
            return sin(3.14159265359 * distance) / (3.14159265359 * distance);
        }
        float lanczos_weight(float value) {
            float distance = abs(value);
            if (distance >= 3.0) return 0.0;
            return sinc(distance) * sinc(distance / 3.0);
        }
        float4 sample_lanczos(texture2d<float> frame, float2 uv) {
            float2 texel = 1.0 / float2(frame.get_width(), frame.get_height());
            float2 coord = uv / texel - float2(0.5);
            float2 base = floor(coord);
            float2 fraction = fract(coord);
            float4 color = float4(0);
            float weight_sum = 0.0;
            for (int y = -2; y <= 3; y++) {
                for (int x = -2; x <= 3; x++) {
                    float weight = lanczos_weight(float(x) - fraction.x) * lanczos_weight(float(y) - fraction.y);
                    float2 sample_uv = (base + float2(float(x), float(y)) + float2(0.5)) * texel;
                    color += sample_point(frame, sample_uv) * weight;
                    weight_sum += weight;
                }
            }
            color /= max(weight_sum, 0.0001);
            return float4(clamp(color.rgb, float3(0), float3(1)), 1);
        }
        fragment float4 frame_fragment(Vertex v [[stage_in]],
                                       texture2d<float> frame [[texture(0)]],
                                       constant uint &algorithm [[buffer(0)]]) {
            float4 tex;
            if (algorithm == 0) tex = sample_point(frame, v.uv);
            else if (algorithm == 2) tex = sample_bicubic(frame, v.uv);
            else if (algorithm == 3) tex = sample_lanczos(frame, v.uv);
            else tex = sample_linear(frame, v.uv);
            // Engine images use premultiplied RGBA. Composite on opaque black
            // without applying alpha again or introducing sRGB conversion.
            return float4(tex.rgb, 1);
        }
        // Contrast-adaptive five-tap sharpen. Mirrors FrameEnhancementKernel:
        // only locally contrasting pixels are sharpened and the delta is limited
        // to the local contrast amplitude so no halo can be introduced.
        fragment float4 sharpen_fragment(Vertex v [[stage_in]],
                                         texture2d<float> frame [[texture(0)]],
                                         constant float &amount [[buffer(0)]],
                                         constant float2 &texel [[buffer(1)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge,
                                filter::nearest);
            float4 center = frame.sample(s, v.uv);
            float4 north = frame.sample(s, v.uv + float2(0, -texel.y));
            float4 south = frame.sample(s, v.uv + float2(0, texel.y));
            float4 west = frame.sample(s, v.uv + float2(-texel.x, 0));
            float4 east = frame.sample(s, v.uv + float2(texel.x, 0));
            float3 minimum = min(min(north.rgb, south.rgb), min(west.rgb, east.rgb));
            float3 maximum = max(max(north.rgb, south.rgb), max(west.rgb, east.rgb));
            float3 weight = amount * (maximum - minimum);
            float3 laplacian = 4.0 * center.rgb - (north.rgb + south.rgb + west.rgb + east.rgb);
            float3 limit = maximum - minimum;
            float3 delta = clamp(weight * laplacian, -limit, limit);
            return float4(clamp(center.rgb + delta, float3(0), float3(1)), 1);
        }
        // FidelityFX FSR1 RCAS, ported from the published AMD reference
        // (ffx-fsr/ffx_fsr1.h, MIT; see THIRD_PARTY_LICENSES.md). Mirrors
        // FrameEnhancementKernel.fsr1Rcas including the zero-denominator guard.
        fragment float4 rcas_fragment(Vertex v [[stage_in]],
                                      texture2d<float> frame [[texture(0)]],
                                      constant float &sharpness [[buffer(0)]],
                                      constant float2 &texel [[buffer(1)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
            float3 b = frame.sample(s, v.uv + float2(0, -texel.y)).rgb;
            float3 d = frame.sample(s, v.uv + float2(-texel.x, 0)).rgb;
            float3 e = frame.sample(s, v.uv).rgb;
            float3 f = frame.sample(s, v.uv + float2(texel.x, 0)).rgb;
            float3 h = frame.sample(s, v.uv + float2(0, texel.y)).rgb;
            float3 minimum = min(min(b, d), min(f, h));
            float3 maximum = max(max(b, d), max(f, h));
            float3 minDenominator = 4.0 * maximum;
            float3 maxDenominator = 4.0 * minimum - 4.0;
            float3 hitMin = select(min(minimum, e) / max(minDenominator, float3(1e-6)),
                                   float3(0), minDenominator < float3(1e-6));
            float3 hitMax = select((1.0 - max(maximum, e)) / min(maxDenominator, float3(-1e-6)),
                                   float3(0), abs(maxDenominator) < float3(1e-6));
            float3 lobe = max(-hitMin, hitMax);
            float lobeValue = max(-0.1875, min(max(max(lobe.r, lobe.g), lobe.b), 0.0)) * sharpness;
            float reciprocal = 1.0 / (4.0 * lobeValue + 1.0);
            float3 result = (lobeValue * (b + d + f + h) + e) * reciprocal;
            return float4(clamp(result, float3(0), float3(1)), 1);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "frame_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "frame_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let sharpenDescriptor = MTLRenderPipelineDescriptor()
        sharpenDescriptor.vertexFunction = library.makeFunction(name: "frame_vertex")
        sharpenDescriptor.fragmentFunction = library.makeFunction(name: "sharpen_fragment")
        sharpenDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        sharpenPipeline = try device.makeRenderPipelineState(descriptor: sharpenDescriptor)
        let rcasDescriptor = MTLRenderPipelineDescriptor()
        rcasDescriptor.vertexFunction = library.makeFunction(name: "frame_vertex")
        rcasDescriptor.fragmentFunction = library.makeFunction(name: "rcas_fragment")
        rcasDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        rcasPipeline = try device.makeRenderPipelineState(descriptor: rcasDescriptor)
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
        frameRevision &+= 1
        lastError = nil
    }

    func useNativeTexture(_ next: MTLTexture) {
        frameLease = nil
        if texture !== next { frameRevision &+= 1 }
        texture = next
        lastError = nil
    }

    func useNativeFrame(_ frame: AetherMetalFrameLease) {
        guard frame.valid, let next = frame.texture else { clear(); return }
        frameLease = frame
        frameRevision &+= 1
        texture = next
        lastError = nil
    }

    func clear() {
        texture = nil; frameLease = nil
        outputTexture = nil; outputRevision = nil
        enhancedTexture = nil; enhancedRevision = nil; enhancedConfig = nil
    }

    // Shared by onscreen rendering and deterministic offscreen verification.
    func encode(target: MTLTexture, command: MTLCommandBuffer) throws {
        var source = texture
        if let texture, outputSize.width > 0, outputSize.height > 0,
           Int(outputSize.width) != texture.width || Int(outputSize.height) != texture.height {
            let width = Int(outputSize.width), height = Int(outputSize.height)
            guard width <= Int(RenderGeometry.maximum.width), height <= Int(RenderGeometry.maximum.height) else {
                throw Failure.unsupportedFrame
            }
            // A drawable command may still be using the previous target when
            // the next engine frame arrives. Keep the target only while the
            // source revision is unchanged; a new frame receives a fresh
            // texture whose lifetime is retained by its command buffer.
            if outputTexture?.width != width || outputTexture?.height != height || outputRevision != frameRevision {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: width, height: height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                guard let next = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
                outputTexture = next
                outputRevision = nil
            }
            if let outputTexture {
                if outputRevision != frameRevision {
                    // Both passes share the producer queue and the same command.
                    // Its completion retains the source lease and resized target.
                    try encodeImage(source: texture, target: outputTexture, command: command,
                                    aspectFit: false, sampling: samplingAlgorithm)
                    outputRevision = frameRevision
                    outputPassCount += 1
                }
                source = outputTexture
            }
        }
        if enhancement != .off, let current = source, enhancementAmount > 0 {
            source = enhancedSource(current, command: command)
        }
        try encodeImage(source: source, target: target, command: command,
                        sampling: outputTexture == nil ? samplingAlgorithm : .linear)
    }

    /// Runs the enhancement pass into a scratch texture. A missing allocation
    /// or a failed pass keeps the original frame, matching Godot's "safe
    /// fallback to the original picture" contract.
    private func enhancedSource(_ current: MTLTexture, command: MTLCommandBuffer) -> MTLTexture {
        let width = current.width, height = current.height
        if enhancedTexture?.width != width || enhancedTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let next = device.makeTexture(descriptor: descriptor) else {
                lastError = "enhancement allocation failed; presenting the original frame"
                return current
            }
            enhancedTexture = next
            enhancedRevision = nil
            enhancedConfig = nil
        }
        guard let target = enhancedTexture else { return current }
        let amount = Float(min(1, max(0, enhancementAmount)))
        if enhancedRevision != frameRevision || enhancedConfig?.0 != enhancement || enhancedConfig?.1 != amount {
            do {
                let passPipeline: MTLRenderPipelineState
                switch enhancement {
                case .fsr1Rcas: passPipeline = rcasPipeline
                default: passPipeline = sharpenPipeline
                }
                try encodeImage(source: current, target: target, command: command,
                                aspectFit: false, sampling: .nearest,
                                pipelineOverride: passPipeline,
                                sharpenAmount: amount)
            } catch {
                lastError = "enhancement pass failed: \(error); presenting the original frame"
                enhancedTexture = nil
                enhancedRevision = nil
                enhancedConfig = nil
                return current
            }
            enhancedRevision = frameRevision
            enhancedConfig = (enhancement, amount)
        }
        return target
    }

    private func encodeImage(source: MTLTexture?, target: MTLTexture, command: MTLCommandBuffer,
                             aspectFit: Bool = true, sampling: SamplingAlgorithm,
                             pipelineOverride: MTLRenderPipelineState? = nil,
                             sharpenAmount: Float = 0) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw Failure.encoding
        }
        if debugLabels { encoder.label = "AetherHost.frame-encode" }
        if let texture = source {
            let scale = min(Double(target.width) / Double(texture.width),
                            Double(target.height) / Double(texture.height))
            let width = aspectFit ? Double(texture.width) * scale : Double(target.width)
            let height = aspectFit ? Double(texture.height) * scale : Double(target.height)
            encoder.setViewport(MTLViewport(
                originX: (Double(target.width) - width) / 2,
                originY: (Double(target.height) - height) / 2,
                width: width, height: height, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipelineOverride ?? pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            if sharpenAmount > 0 {
                var amount = sharpenAmount
                var texel = SIMD2<Float>(1 / Float(max(1, target.width)), 1 / Float(max(1, target.height)))
                encoder.setFragmentBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
                encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            } else {
                var algorithm = sampling.metalIndex
                encoder.setFragmentBytes(&algorithm, length: MemoryLayout<UInt32>.size, index: 0)
            }
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
            presentedFrameCount += 1
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
