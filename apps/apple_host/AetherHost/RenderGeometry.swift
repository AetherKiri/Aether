import Foundation
import CoreGraphics

enum CanvasMode: String, CaseIterable { case game, display }
enum SamplingAlgorithm: String, CaseIterable {
    case nearest, linear, bicubic, lanczos

    /// Godot kept `smooth` as a legacy spelling for its linear sampler.
    static func normalized(_ raw: String) -> SamplingAlgorithm? {
        if raw == "smooth" { return .linear }
        return SamplingAlgorithm(rawValue: raw)
    }

    var metalIndex: UInt32 {
        switch self {
        case .nearest: return 0
        case .linear: return 1
        case .bicubic: return 2
        case .lanczos: return 3
        }
    }
}

enum OutputResolution: String, CaseIterable {
    case original, fullHD = "1080p", quadHD = "2k", ultraHD = "4k"
    var bounds: CGSize? {
        switch self {
        case .original: return nil
        case .fullHD: return CGSize(width: 1920, height: 1080)
        case .quadHD: return CGSize(width: 2560, height: 1440)
        case .ultraHD: return CGSize(width: 3840, height: 2160)
        }
    }
}

/// The engine/input canvas stays native. Only the host output changes size.
/// Preset bounds and rounding mirror Godot _frame_output_target_size.
enum RenderGeometry {
    static let maximum = CGSize(width: 3840, height: 2160)
    static func target(source: CGSize, mode: CanvasMode, resolution: OutputResolution, displayPixels: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        if let bounds = resolution.bounds { return fit(source, within: bounds) }
        if mode == .display && displayPixels.width > 0 && displayPixels.height > 0 {
            return fit(source, within: CGSize(width: min(displayPixels.width, maximum.width),
                                             height: min(displayPixels.height, maximum.height)))
        }
        return source
    }
    static func fit(_ source: CGSize, within bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: max(1, (source.width * scale).rounded()),
                      height: max(1, (source.height * scale).rounded()))
    }

    /// Device-independent fallback uses the same opaque-black composition and
    /// sampling kernels as Metal. `smooth` is normalized to linear before it
    /// reaches this function, so labels never claim a different kernel.
    static func image(_ source: CGImage, size: CGSize,
                      sampling: SamplingAlgorithm = .linear) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        if source.width == width && source.height == height { return source }
        guard source.bitsPerComponent == 8, source.bitsPerPixel == 32,
              source.alphaInfo == .premultipliedLast,
              let data = source.dataProvider?.data,
              let sourceBytes = CFDataGetBytePtr(data) else { return nil }
        let sourceStride = source.bytesPerRow
        guard sourceStride >= source.width * 4,
              CFDataGetLength(data) >= sourceStride * source.height else { return nil }
        var output = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let sourceY = (Double(y) + 0.5) * Double(source.height) / Double(height) - 0.5
            for x in 0..<width {
                let sourceX = (Double(x) + 0.5) * Double(source.width) / Double(width) - 0.5
                let rgb = sample(sourceBytes, stride: sourceStride, width: source.width,
                                 height: source.height, x: sourceX, y: sourceY,
                                 sampling: sampling)
                let offset = (y * width + x) * 4
                output[offset] = UInt8(max(0, min(255, Int((rgb.0 * 255).rounded()))))
                output[offset + 1] = UInt8(max(0, min(255, Int((rgb.1 * 255).rounded()))))
                output[offset + 2] = UInt8(max(0, min(255, Int((rgb.2 * 255).rounded()))))
                output[offset + 3] = 255
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(output) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func sample(_ bytes: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int,
                               x: Double, y: Double, sampling: SamplingAlgorithm) -> (Double, Double, Double) {
        func pixel(_ px: Int, _ py: Int) -> (Double, Double, Double) {
            let ix = max(0, min(width - 1, px)), iy = max(0, min(height - 1, py))
            let offset = iy * stride + ix * 4
            return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255,
                    Double(bytes[offset + 2]) / 255)
        }
        func add(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ weight: Double) -> (Double, Double, Double) {
            (a.0 + b.0 * weight, a.1 + b.1 * weight, a.2 + b.2 * weight)
        }
        func cubicWeights(_ value: Double) -> [Double] {
            let v2 = value * value, v3 = v2 * value
            return [-0.5 * v3 + v2 - 0.5 * value,
                    1.5 * v3 - 2.5 * v2 + 1,
                    -1.5 * v3 + 2 * v2 + 0.5 * value,
                    0.5 * v3 - 0.5 * v2]
        }
        func sinc(_ value: Double) -> Double {
            let distance = abs(value)
            if distance < 0.0001 { return 1 }
            return sin(Double.pi * distance) / (Double.pi * distance)
        }
        func lanczos(_ value: Double) -> Double {
            let distance = abs(value)
            if distance >= 3 { return 0 }
            return sinc(distance) * sinc(distance / 3)
        }
        switch sampling {
        case .nearest:
            return pixel(Int(floor(x + 0.5)), Int(floor(y + 0.5)))
        case .linear:
            let x0 = Int(floor(x)), y0 = Int(floor(y))
            let fx = x - floor(x), fy = y - floor(y)
            let p00 = pixel(x0, y0), p10 = pixel(x0 + 1, y0)
            let p01 = pixel(x0, y0 + 1), p11 = pixel(x0 + 1, y0 + 1)
            let top = (p00.0 + (p10.0 - p00.0) * fx, p00.1 + (p10.1 - p00.1) * fx, p00.2 + (p10.2 - p00.2) * fx)
            let bottom = (p01.0 + (p11.0 - p01.0) * fx, p01.1 + (p11.1 - p01.1) * fx, p01.2 + (p11.2 - p01.2) * fx)
            return (top.0 + (bottom.0 - top.0) * fy, top.1 + (bottom.1 - top.1) * fy, top.2 + (bottom.2 - top.2) * fy)
        case .bicubic:
            let baseX = floor(x), baseY = floor(y), fractionX = x - baseX, fractionY = y - baseY
            let wx = cubicWeights(fractionX), wy = cubicWeights(fractionY)
            var color = (0.0, 0.0, 0.0)
            for row in 0..<4 { for column in 0..<4 {
                color = add(color, pixel(Int(baseX) + column - 1, Int(baseY) + row - 1), wx[column] * wy[row])
            } }
            return (max(0, min(1, color.0)), max(0, min(1, color.1)), max(0, min(1, color.2)))
        case .lanczos:
            let baseX = floor(x), baseY = floor(y), fractionX = x - baseX, fractionY = y - baseY
            var color = (0.0, 0.0, 0.0), weightSum = 0.0
            for row in -2...3 { for column in -2...3 {
                let weight = lanczos(Double(column) - fractionX) * lanczos(Double(row) - fractionY)
                color = add(color, pixel(Int(baseX) + column, Int(baseY) + row), weight)
                weightSum += weight
            } }
            let divisor = max(weightSum, 0.0001)
            return (max(0, min(1, color.0 / divisor)), max(0, min(1, color.1 / divisor)), max(0, min(1, color.2 / divisor)))
        }
    }
}
