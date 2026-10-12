import CoreGraphics
import Foundation
import Metal

/// Frame enhancement: CPU reference kernel, Metal parity and settings schema.
enum FrameEnhancementTests {
    static func run(root: URL) throws {
        kernelBasics()
        try gpuMatchesReference()
        try gpuEasuMatchesReference()
        try settingsMigration(root: root)
        print("PASS: enhancement kernel (identity/contrast-adaptive/RCAS/EASU), chain parity and schema v9 migration")
    }

    private static func kernelBasics() {
        precondition(FrameEnhancement.allCases.map(\.rawValue) == ["off", "adaptive_sharpen", "fsr1_easu", "fsr1_rcas"])
        precondition(FrameEnhancement.normalized("adaptive_sharpen") == .adaptiveSharpen)
        precondition(FrameEnhancement.normalized("fsr1_rcas") == .fsr1Rcas)
        precondition(FrameEnhancement.normalized("fsr1_easu") == .fsr1Easu)
        precondition(FrameEnhancement.fsr1Easu.scalesOutput && !FrameEnhancement.fsr1Rcas.scalesOutput)
        precondition(FrameEnhancement.normalized("anime4k_upscale_s") == nil, "unported Godot algorithms must not be selectable")
        // Amount 0 is an exact identity.
        let source: [UInt8] = [10, 10, 10, 255, 20, 20, 20, 255, 30, 30, 30, 255,
                               40, 40, 40, 255, 120, 120, 120, 255, 60, 60, 60, 255,
                               70, 70, 70, 255, 80, 80, 80, 255, 90, 90, 90, 255]
        precondition(FrameEnhancementKernel.sharpen(source, width: 3, height: 3, amount: 0) == source)
        let sharpened = FrameEnhancementKernel.sharpen(source, width: 3, height: 3, amount: 1)
        // The bright center on a dark neighbourhood is pushed up, but the delta
        // is limited to the local contrast amplitude (80 - 20 here).
        let center = (1 * 3 + 1) * 4
        precondition(sharpened[center] > source[center], "a contrasting pixel must be sharpened")
        precondition(sharpened[center] <= 120 + (80 - 20), "delta limited to the local contrast amplitude")
        for pixel in 0..<9 {
            for channel in 0..<3 {
                let offset = pixel * 4 + channel
                let value = Int(sharpened[offset])
                let original = Int(source[offset])
                precondition(abs(value - original) <= 255)
                precondition(value >= 0 && value <= 255)
            }
            precondition(sharpened[pixel * 4 + 3] == source[pixel * 4 + 3], "alpha is preserved")
        }
        // A flat neighbourhood has no contrast and therefore no change.
        let flat = [UInt8](repeating: 128, count: 4 * 4 * 4)
        precondition(FrameEnhancementKernel.sharpen(flat, width: 4, height: 4, amount: 1) == flat)
        // Edges clamp instead of reading out of bounds.
        let edge = FrameEnhancementKernel.sharpen(source, width: 3, height: 3, amount: 1)
        precondition(edge.count == source.count)

        // FSR1 RCAS: identity at zero sharpness, edge enhancement otherwise,
        // alpha preserved and a fully black neighbourhood stays black.
        precondition(FrameEnhancementKernel.fsr1Rcas(source, width: 3, height: 3, sharpness: 0) == source)
        let rcas = FrameEnhancementKernel.fsr1Rcas(source, width: 3, height: 3, sharpness: 1)
        precondition(rcas[center] > source[center], "RCAS must sharpen a contrasting center")
        precondition(rcas[center] <= 255)
        for pixel in 0..<9 {
            precondition(rcas[pixel * 4 + 3] == source[pixel * 4 + 3], "RCAS preserves alpha")
        }
        let black = [UInt8](repeating: 0, count: 3 * 3 * 4)
        precondition(FrameEnhancementKernel.fsr1Rcas(black, width: 3, height: 3, sharpness: 1) == black,
                     "a fully black neighbourhood must not produce NaN")
        let white = [UInt8](repeating: 255, count: 3 * 3 * 4)
        precondition(FrameEnhancementKernel.fsr1Rcas(white, width: 3, height: 3, sharpness: 1) == white,
                     "a fully white neighbourhood stays white")

        // FSR1 EASU: a flat neighbourhood upscales unchanged, grows to the
        // requested size and emits opaque alpha.
        let flatSource = [UInt8](repeating: 90, count: 4 * 4 * 4)
        let upscaled = FrameEnhancementKernel.fsr1Easu(flatSource, width: 4, height: 4,
                                                       outputWidth: 8, outputHeight: 8)
        precondition(upscaled.count == 8 * 8 * 4)
        for pixel in 0..<(8 * 8) {
            precondition(upscaled[pixel * 4] == 90 && upscaled[pixel * 4 + 1] == 90 && upscaled[pixel * 4 + 2] == 90,
                         "a flat neighbourhood upscales unchanged")
            precondition(upscaled[pixel * 4 + 3] == 255, "EASU emits opaque alpha")
        }
        // EASU preserves the output size even for a 1:1 request.
        let identity = FrameEnhancementKernel.fsr1Easu(source, width: 3, height: 3, outputWidth: 3, outputHeight: 3)
        precondition(identity.count == source.count)
    }

    private static func gpuMatchesReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("SKIP: Metal device unavailable; CPU reference only")
            return
        }
        let presenter = try MetalFramePresenter(device: device)
        presenter.samplingAlgorithm = .linear
        // Opaque checker/gradient so the adaptive weight actually engages.
        let width = 8, height = 8
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = UInt8((x * 24 + y * 8) % 256)
                let checker: UInt8 = (x + y) % 2 == 0 ? 0 : 40
                rgba[offset] = value
                rgba[offset + 1] = UInt8(min(255, Int(value) + Int(checker)))
                rgba[offset + 2] = UInt8(255 - value)
                rgba[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try presenter.upload(image)
        let plain = try presenter.renderOffscreen(width: width, height: height)
        func compare(_ algorithm: FrameEnhancement,
                     _ reference: ([UInt8], Int, Int, Double) -> [UInt8]) throws {
            presenter.enhancementChain = [algorithm]
            presenter.enhancementAmount = 0.5
            let enhanced = try presenter.renderOffscreen(width: width, height: height)
            let expected = reference(rgba, width, height, 0.5)
            var maxDifference = 0
            var changed = 0
            for pixel in 0..<(width * height) {
                for channel in 0..<3 {
                    // renderOffscreen returns BGRA; the reference is RGBA.
                    let gpuChannel = channel == 0 ? 2 : (channel == 2 ? 0 : 1)
                    let gpu = Int(enhanced[pixel * 4 + gpuChannel])
                    let cpu = Int(expected[pixel * 4 + channel])
                    maxDifference = max(maxDifference, abs(gpu - cpu))
                    if abs(gpu - Int(plain[pixel * 4 + gpuChannel])) > 0 { changed += 1 }
                }
            }
            precondition(maxDifference <= 2, "\(algorithm.rawValue) must match the CPU reference (max diff \(maxDifference))")
            precondition(changed > 0, "\(algorithm.rawValue) must change at least one pixel")
        }
        // Both run against the same uploaded frame, so this also covers the
        // scratch-texture cache key: switching algorithms without a new source
        // revision must re-run the pass instead of reusing the previous result.
        try compare(.adaptiveSharpen) { FrameEnhancementKernel.sharpen($0, width: $1, height: $2, amount: $3) }
        try compare(.fsr1Rcas) { FrameEnhancementKernel.fsr1Rcas($0, width: $1, height: $2, sharpness: $3) }
        // A two-step chain applies both kernels in order and matches the CPU
        // composition of the same two kernels.
        presenter.enhancementChain = [.fsr1Rcas, .adaptiveSharpen]
        presenter.enhancementAmount = 0.5
        let chained = try presenter.renderOffscreen(width: width, height: height)
        let expectedChain = FrameEnhancementKernel.sharpen(
            FrameEnhancementKernel.fsr1Rcas(rgba, width: width, height: height, sharpness: 0.5),
            width: width, height: height, amount: 0.5)
        var chainDifference = 0
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                let gpuChannel = channel == 0 ? 2 : (channel == 2 ? 0 : 1)
                chainDifference = max(chainDifference,
                    abs(Int(chained[pixel * 4 + gpuChannel]) - Int(expectedChain[pixel * 4 + channel])))
            }
        }
        precondition(chainDifference <= 2, "a two-step chain must match the CPU composition (max diff \(chainDifference))")
        // Turning the enhancement off restores the unmodified frame.
        presenter.enhancementChain = []
        let restored = try presenter.renderOffscreen(width: width, height: height)
        precondition(restored == plain, "off must present the original frame")
        presenter.clear()
    }

    private static func gpuEasuMatchesReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("SKIP: Metal device unavailable; EASU CPU reference only")
            return
        }
        let presenter = try MetalFramePresenter(device: device)
        presenter.samplingAlgorithm = .linear
        let width = 12, height = 10, outWidth = 25, outHeight = 21
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                rgba[offset] = UInt8((x * 20 + y * 7) % 256)
                rgba[offset + 1] = UInt8((x * 11 + y * 31) % 256)
                rgba[offset + 2] = UInt8(255 - (x * 9 + y * 13) % 256)
                rgba[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try presenter.upload(image)
        // EASU owns the output upscale, so it runs only when an output size is
        // configured; the offscreen target then matches the upscaled size.
        presenter.enhancementChain = [.fsr1Easu]
        presenter.outputSize = CGSize(width: outWidth, height: outHeight)
        let enhanced = try presenter.renderOffscreen(width: outWidth, height: outHeight)
        let expected = FrameEnhancementKernel.fsr1Easu(rgba, width: width, height: height,
                                                       outputWidth: outWidth, outputHeight: outHeight)
        var maxDifference = 0
        for pixel in 0..<(outWidth * outHeight) {
            for channel in 0..<3 {
                // renderOffscreen returns BGRA; the reference is RGBA.
                let gpuChannel = channel == 0 ? 2 : (channel == 2 ? 0 : 1)
                maxDifference = max(maxDifference,
                                    abs(Int(enhanced[pixel * 4 + gpuChannel]) - Int(expected[pixel * 4 + channel])))
            }
        }
        precondition(maxDifference <= 2, "fsr1_easu must match the CPU reference (max diff \(maxDifference))")
        presenter.clear()
    }

    private static func settingsMigration(root: URL) throws {
        let suite = "aether-enhancement-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(url: root.appendingPathComponent("enhancement-settings/settings.json"))
        let fresh = try SettingsStore(url: root.appendingPathComponent("enhancement-fresh/settings.json"))
            .load(defaults: defaults, legacyPrefix: "enh.")
        precondition(fresh.version == 9)
        precondition(fresh.frameEnhancementKind == "off" && fresh.frameEnhancementAmount == 0.5)
        precondition(fresh.enhancementSteps.isEmpty)
        try store.save(fresh)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        // A v8 file stored a single algorithm; it migrates to a 1-step custom chain.
        json["version"] = 8
        json["frameEnhancement"] = "fsr1_rcas"
        json.removeValue(forKey: "frameEnhancementKind")
        json.removeValue(forKey: "frameEnhancementPreset")
        json.removeValue(forKey: "frameEnhancementChain")
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)
        let upgraded = try store.load(defaults: defaults, legacyPrefix: "enh.")
        precondition(upgraded.version == 9)
        precondition(upgraded.frameEnhancementKind == "custom")
        precondition(upgraded.enhancementSteps == [.fsr1Rcas])
        // A v7 file has no enhancement keys and migrates to off.
        json["version"] = 7
        json.removeValue(forKey: "frameEnhancement")
        json.removeValue(forKey: "frameEnhancementAmount")
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)
        let legacy = try store.load(defaults: defaults, legacyPrefix: "enh.")
        precondition(legacy.frameEnhancementKind == "off" && legacy.enhancementSteps.isEmpty)
        // The fsr1 preset resolves to EASU then RCAS.
        var presetValue = fresh
        presetValue.frameEnhancementKind = "preset"
        presetValue.frameEnhancementPreset = "fsr1"
        try store.save(presetValue)
        let reloadedPreset = try store.load(defaults: defaults, legacyPrefix: "enh.")
        precondition(reloadedPreset.enhancementSteps == [.fsr1Easu, .fsr1Rcas])
        // A custom chain round-trips in order.
        var chainValue = fresh
        chainValue.frameEnhancementKind = "custom"
        chainValue.frameEnhancementChain = ["fsr1_rcas", "adaptive_sharpen"]
        try store.save(chainValue)
        let reloadedChain = try store.load(defaults: defaults, legacyPrefix: "enh.")
        precondition(reloadedChain.enhancementSteps == [.fsr1Rcas, .adaptiveSharpen])
        // Unported algorithms, a scaling step after a same-size step and two
        // scaling steps are all rejected.
        for bad in [["anime4k_upscale_s"], ["fsr1_rcas", "fsr1_easu"], ["fsr1_easu", "fsr1_easu"], []] {
            var invalid = fresh
            invalid.frameEnhancementKind = "custom"
            invalid.frameEnhancementChain = bad
            do { try store.save(invalid); preconditionFailure("invalid chain accepted: \(bad)") } catch {}
        }
        // Amounts snap to 0.05 like Godot's slider; invalid values are rejected.
        for (input, expected) in [(0.62, 0.6), (0.63, 0.65), (0.0, 0.0), (1.0, 1.0)] {
            var value = fresh
            value.frameEnhancementKind = "custom"
            value.frameEnhancementChain = ["adaptive_sharpen"]
            value.frameEnhancementAmount = input
            try store.save(value)
            let reloaded = try store.load(defaults: defaults, legacyPrefix: "enh.")
            precondition(reloaded.enhancementSteps == [.adaptiveSharpen])
            precondition(abs(reloaded.frameEnhancementAmount - expected) < 0.0001,
                         "amount \(input) -> \(reloaded.frameEnhancementAmount)")
        }
        var invalidAmount = fresh
        invalidAmount.frameEnhancementAmount = 1.5
        do { try store.save(invalidAmount); preconditionFailure("amount above the maximum accepted") } catch {}
        // An unknown algorithm normalizes a custom chain to off.
        var unknown = fresh
        unknown.frameEnhancementKind = "custom"
        unknown.frameEnhancementChain = ["anime4k_upscale_s"]
        unknown.frameEnhancementAmount = -1
        try JSONEncoder().encode(unknown).write(to: store.url)
        let normalized = try store.load(defaults: defaults, legacyPrefix: "enh.")
        precondition(normalized.frameEnhancementKind == "off" && normalized.frameEnhancementAmount == 0.0)
    }
}
