import AppKit

/// Deterministic, asymmetric content proves orientation, aspect and sample location.
enum RenderGeometryTests {
    @MainActor static func run(root: URL) throws {
        precondition(RenderGeometry.target(source: CGSize(width: 640, height: 480), mode: .game,
            resolution: .fullHD, displayPixels: .zero) == CGSize(width: 1440, height: 1080))
        precondition(RenderGeometry.target(source: CGSize(width: 1920, height: 1080), mode: .game,
            resolution: .quadHD, displayPixels: .zero) == CGSize(width: 2560, height: 1440))
        precondition(RenderGeometry.target(source: CGSize(width: 640, height: 480), mode: .display,
            resolution: .original, displayPixels: CGSize(width: 2000, height: 1000)) == CGSize(width: 1333, height: 1000))
        precondition(RenderGeometry.target(source: CGSize(width: 640, height: 480), mode: .display,
            resolution: .ultraHD, displayPixels: CGSize(width: 800, height: 600)) == CGSize(width: 2880, height: 2160))
        precondition(RenderGeometry.target(source: CGSize(width: 640, height: 480), mode: .display,
            resolution: .original, displayPixels: CGSize(width: 10000, height: 10000)) == CGSize(width: 2880, height: 2160))
        let image = fixture()
        let engine = EngineController()
        guard let presenter = engine.metalPresenter else { preconditionFailure("GPU tests require Metal") }
        presenter.samplingAlgorithm = .linear
        try presenter.upload(image)
        for size in [CGSize(width: 64, height: 48), CGSize(width: 1440, height: 1080),
                     CGSize(width: 1333, height: 1000), CGSize(width: 1920, height: 1440), CGSize(width: 2880, height: 2160)] {
            presenter.outputSize = size
            let gpu = try presenter.renderOffscreen(width: Int(size.width), height: Int(size.height))
            let cpu = RenderGeometry.image(image, size: size)!
            precondition(cpu.width == Int(size.width) && cpu.height == Int(size.height))
            let data = cpu.dataProvider!.data!
            let bytes = CFDataGetBytePtr(data)!
            // Sample asymmetric interiors, avoiding interpolation boundaries.
            for (x, y, rgb) in [(0.2, 0.2, [UInt8(240), 10, 20]), (0.8, 0.2, [10, 230, 30]),
                                (0.2, 0.8, [20, 30, 220]), (0.8, 0.8, [210, 180, 40])] {
                let ix = Int(Double(cpu.width) * x), iy = Int(Double(cpu.height) * y)
                let i = (iy * cpu.width + ix) * 4, c = iy * cpu.bytesPerRow + ix * 4
                for channel in 0..<3 {
                    let gpuChannel = channel == 0 ? 2 : channel == 2 ? 0 : 1
                    precondition(abs(Int(gpu[i + gpuChannel]) - Int(rgb[channel])) <= 1, "GPU orientation/color mismatch")
                    precondition(abs(Int(bytes[c + channel]) - Int(rgb[channel])) <= 1, "CPU orientation/color mismatch")
                }
            }
            let passes = presenter.outputPassCount
            _ = try presenter.renderOffscreen(width: Int(size.width), height: Int(size.height))
            precondition(presenter.outputPassCount == passes, "unchanged frame must reuse cached output")
        }
        // Check letterboxing and reversible pointer/IME geometry at desktop/fullscreen sizes.
        for view in [CGSize(width: 960, height: 640), CGSize(width: 1280, height: 800), CGSize(width: 2560, height: 1440)] {
            let source = CGSize(width: 640, height: 480)
            for output in [source, CGSize(width: 1333, height: 1000), CGSize(width: 1440, height: 1080)] {
            for point in [CGPoint(x: 0, y: 0), CGPoint(x: 319, y: 241), CGPoint(x: 640, y: 480)] {
                let displayed = InputMapping.mapCanvasToView(point: point, viewSize: view, contentSize: source, presentationSize: output)!
                let mapped = InputMapping.mapToSurface(point: displayed, viewSize: view, contentSize: source, presentationSize: output)!
                precondition(abs(mapped.x - point.x) < 0.001 && abs(mapped.y - point.y) < 0.001)
            }
            }
            precondition(InputMapping.mapToSurface(point: .zero, viewSize: view, contentSize: source) == nil)
        }
        presenter.clear()
        precondition(SamplingAlgorithm.normalized("smooth") == .linear)
        precondition(SamplingAlgorithm.normalized("nearest") == .nearest)
        let nearest = RenderGeometry.image(image, size: CGSize(width: 17, height: 13), sampling: .nearest)!
        let bicubic = RenderGeometry.image(image, size: CGSize(width: 17, height: 13), sampling: .bicubic)!
        precondition(nearest.dataProvider?.data != bicubic.dataProvider?.data,
                     "distinct sampling algorithms must produce distinct output")
        // Compare every implemented Metal kernel with its CPU fallback on a
        // same-aspect deterministic fixture. A small tolerance covers float
        // rounding at kernel boundaries while still catching wrong kernels,
        // channel order, or a hidden second resize.
        for algorithm in SamplingAlgorithm.allCases {
            presenter.clear()
            presenter.outputSize = .zero
            presenter.samplingAlgorithm = algorithm
            try presenter.upload(image)
            let gpu = try presenter.renderOffscreen(width: 40, height: 30)
            let cpu = RenderGeometry.image(image, size: CGSize(width: 40, height: 30), sampling: algorithm)!
            let cpuData = cpu.dataProvider!.data!
            let cpuBytes = CFDataGetBytePtr(cpuData)!
            var maxDifference = 0
            for y in 0..<30 { for x in 0..<40 {
                let offset = (y * 40 + x) * 4
                for channel in 0..<3 {
                    let gpuChannel = channel == 0 ? 2 : channel == 2 ? 0 : 1
                    maxDifference = max(maxDifference,
                        abs(Int(gpu[offset + gpuChannel]) - Int(cpuBytes[offset + channel])))
                }
            } }
            precondition(maxDifference <= 2, "Metal/CPU sampling mismatch for \(algorithm): \(maxDifference)")
        }
        print("PASS: Godot output bounds, Display Fit/Retina pixels, 4K cap, asymmetric GPU/CPU color/orientation, cached output, pointer/IME round trips and letterbox rejection")
    }

    private static func fixture() -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 64 * 48 * 4)
        let colors: [[UInt8]] = [[240, 10, 20], [10, 230, 30], [20, 30, 220], [210, 180, 40]]
        for y in 0..<48 { for x in 0..<64 {
            let color = colors[(y >= 24 ? 2 : 0) + (x >= 32 ? 1 : 0)]
            for channel in 0..<3 { bytes[(y * 64 + x) * 4 + channel] = color[channel] }
        } }
        return CGImage(width: 64, height: 48, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
