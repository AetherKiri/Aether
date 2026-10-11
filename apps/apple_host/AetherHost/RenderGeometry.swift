import Foundation
import CoreGraphics

enum CanvasMode: String, CaseIterable { case game, display }
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

    /// Device-independent fallback uses the same opaque-black composition as Metal.
    static func image(_ source: CGImage, size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        if source.width == width && source.height == height { return source }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .low
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
