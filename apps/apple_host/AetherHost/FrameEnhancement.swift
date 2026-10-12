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
    /// AMD FidelityFX FSR1 RCAS, ported from the published MIT reference.
    case fsr1Rcas = "fsr1_rcas"

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

    /// FidelityFX FSR1 RCAS (robust contrast adaptive sharpening).
    ///
    /// Port of `FsrRcasF` from the published AMD FidelityFX FSR1 reference
    /// (`ffx-fsr/ffx_fsr1.h`, MIT; see THIRD_PARTY_LICENSES.md). The optional
    /// `FSR_RCAS_DENOISE` branch is not enabled, and the medium-precision
    /// reciprocal is replaced by an exact one so the CPU reference and the
    /// Metal pass agree bit-for-bit apart from unorm rounding.
    static func fsr1Rcas(_ pixels: [UInt8], width: Int, height: Int, sharpness: Double) -> [UInt8] {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return pixels }
        let strength = min(1.0, max(0.0, sharpness))
        guard strength > 0 else { return pixels }
        let lobeLimit = 0.25 - 1.0 / 16.0
        func safeDivide(_ numerator: Double, _ denominator: Double) -> Double {
            // A fully black neighbourhood makes both limiter denominators zero;
            // the reference relies on GPU reciprocal semantics there, so pin
            // the ratio to zero instead of producing NaN.
            abs(denominator) < 1e-6 ? 0 : numerator / denominator
        }
        func load(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let cx = min(width - 1, max(0, x))
            let cy = min(height - 1, max(0, y))
            let offset = (cy * width + cx) * 4
            return (Double(pixels[offset]) / 255.0, Double(pixels[offset + 1]) / 255.0,
                    Double(pixels[offset + 2]) / 255.0)
        }
        var output = pixels
        for y in 0..<height {
            for x in 0..<width {
                let b = load(x, y - 1), d = load(x - 1, y), e = load(x, y)
                let f = load(x + 1, y), h = load(x, y + 1)
                func channel(_ value: (Double, Double, Double), _ index: Int) -> Double {
                    [value.0, value.1, value.2][index]
                }
                var lobeChannels = [Double](repeating: 0, count: 3)
                for index in 0..<3 {
                    let ring = [channel(b, index), channel(d, index), channel(f, index), channel(h, index)]
                    let center = channel(e, index)
                    let minimum = ring.min() ?? 0
                    let maximum = ring.max() ?? 0
                    let hitMin = safeDivide(min(minimum, center), 4 * maximum)
                    let hitMax = safeDivide(1.0 - max(maximum, center), 4 * minimum - 4.0)
                    lobeChannels[index] = max(-hitMin, hitMax)
                }
                let lobe = max(-lobeLimit, min(lobeChannels.max() ?? 0, 0)) * strength
                let reciprocal = 1.0 / (4.0 * lobe + 1.0)
                let offset = (y * width + x) * 4
                for index in 0..<3 {
                    let ringSum = channel(b, index) + channel(d, index) + channel(f, index) + channel(h, index)
                    let value = (lobe * ringSum + channel(e, index)) * reciprocal
                    output[offset + index] = UInt8(min(255, max(0, (value * 255).rounded())))
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
