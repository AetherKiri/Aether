import CoreGraphics
import Foundation

/// Apple-host frame enhancement.
///
/// The Godot provider's algorithm set (Anime4K, FSR1, RAVU, CuNNy, NNEDI3,
/// FXAA) lives in the private RenderingDevice provider and cannot be reused by
/// the Metal presenter. This starts with a self-authored, fully specified
/// contrast-adaptive sharpen; a Godot algorithm id is only added once its real
/// kernel is ported and verified against a reference.
enum FrameEnhancement: String, CaseIterable, Identifiable {
    case off
    case adaptiveSharpen = "adaptive_sharpen"

    var id: String { rawValue }
    var textKey: String { "enhancement_" + rawValue }
    static func normalized(_ raw: String) -> FrameEnhancement? { FrameEnhancement(rawValue: raw) }
}

/// CPU reference for the Metal pass. Both use the same five-tap,
/// contrast-adaptive Laplacian kernel so the GPU result can be compared
/// deterministically.
enum FrameEnhancementKernel {
    static let amountRange = 0.0...1.0

    /// `pixels` is premultiplied RGBA8 in row-major order; alpha is preserved.
    static func sharpen(_ pixels: [UInt8], width: Int, height: Int, amount: Double) -> [UInt8] {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return pixels }
        let strength = min(amountRange.upperBound, max(amountRange.lowerBound, amount))
        guard strength > 0 else { return pixels }
        var output = pixels
        func value(_ x: Int, _ y: Int, _ channel: Int) -> Double {
            let cx = min(width - 1, max(0, x))
            let cy = min(height - 1, max(0, y))
            return Double(pixels[(cy * width + cx) * 4 + channel])
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    let center = value(x, y, channel)
                    let north = value(x, y - 1, channel)
                    let south = value(x, y + 1, channel)
                    let west = value(x - 1, y, channel)
                    let east = value(x + 1, y, channel)
                    let minimum = min(min(north, south), min(west, east))
                    let maximum = max(max(north, south), max(west, east))
                    // Only locally contrasting pixels are sharpened, and the
                    // delta is limited to the local contrast amplitude so the
                    // pass cannot introduce halos.
                    let contrast = (maximum - minimum) / 255.0
                    let weight = strength * contrast
                    let laplacian = 4 * center - (north + south + west + east)
                    let limit = maximum - minimum
                    let delta = (weight * laplacian).clamped(to: -limit...limit)
                    let sharpened = (center + delta).clamped(to: 0...255)
                    output[offset + channel] = UInt8(sharpened.rounded())
                }
            }
        }
        return output
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
