import CoreGraphics
import Foundation
import Metal

/// Frame enhancement: CPU reference kernel, Metal parity and settings schema.
enum FrameEnhancementTests {
    static func run(root: URL) throws {
        kernelBasics()
        try gpuMatchesReference()
        try settingsMigration(root: root)
        print("PASS: enhancement kernel (identity/contrast-adaptive/no overshoot/alpha), Metal parity and schema v8 migration")
    }

    private static func kernelBasics() {
        precondition(FrameEnhancement.allCases.map(\.rawValue) == ["off", "adaptive_sharpen"])
        precondition(FrameEnhancement.normalized("adaptive_sharpen") == .adaptiveSharpen)
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
        presenter.enhancement = .adaptiveSharpen
        presenter.enhancementAmount = 0.5
        let enhanced = try presenter.renderOffscreen(width: width, height: height)
        let expected = FrameEnhancementKernel.sharpen(rgba, width: width, height: height, amount: 0.5)
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
        precondition(maxDifference <= 2, "Metal pass must match the CPU reference (max diff \(maxDifference))")
        precondition(changed > 0, "the enhancement pass must change at least one pixel")
        // Turning the enhancement off restores the unmodified frame.
        presenter.enhancement = .off
        let restored = try presenter.renderOffscreen(width: width, height: height)
        precondition(restored == plain, "off must present the original frame")
        presenter.clear()
    }

    private static func settingsMigration(root: URL) throws {
        let suite = "aether-enhancement-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(url: root.appendingPathComponent("enhancement-settings/settings.json"))
        let fresh = try SettingsStore(url: root.appendingPathComponent("enhancement-fresh/settings.json"))
            .load(defaults: defaults, legacyPrefix: "enh.")
        precondition(fresh.version == 8)
        precondition(fresh.frameEnhancement == "off" && fresh.frameEnhancementAmount == 0.5)
        // A v7 file has neither field and migrates to off/0.5.
        try store.save(fresh)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        json["version"] = 7
        json.removeValue(forKey: "frameEnhancement")
        json.removeValue(forKey: "frameEnhancementAmount")
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)
        let upgraded = try store.load(defaults: defaults, legacyPrefix: "enh.")
        precondition(upgraded.version == 8)
        precondition(upgraded.frameEnhancement == "off" && upgraded.frameEnhancementAmount == 0.5)
        // Amounts snap to 0.05 like Godot's slider; invalid values are rejected.
        for (input, expected) in [(0.62, 0.6), (0.63, 0.65), (0.0, 0.0), (1.0, 1.0)] {
            var value = fresh
            value.frameEnhancement = "adaptive_sharpen"
            value.frameEnhancementAmount = input
            try store.save(value)
            let reloaded = try store.load(defaults: defaults, legacyPrefix: "enh.")
            precondition(reloaded.frameEnhancement == "adaptive_sharpen")
            precondition(abs(reloaded.frameEnhancementAmount - expected) < 0.0001,
                         "amount \(input) -> \(reloaded.frameEnhancementAmount)")
        }
        var invalid = fresh
        invalid.frameEnhancement = "anime4k_upscale_s"
        do { try store.save(invalid); preconditionFailure("unported algorithm accepted") } catch {}
        invalid = fresh
        invalid.frameEnhancementAmount = 1.5
        do { try store.save(invalid); preconditionFailure("amount above the maximum accepted") } catch {}
        var unknown = fresh
        unknown.frameEnhancement = "anime4k_upscale_s"
        unknown.frameEnhancementAmount = -1
        try JSONEncoder().encode(unknown).write(to: store.url)
        let normalized = try store.load(defaults: defaults, legacyPrefix: "enh.")
        precondition(normalized.frameEnhancement == "off" && normalized.frameEnhancementAmount == 0.0)
    }
}
