import CoreGraphics
import Metal

@main
struct MetalPresentationTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device required for presentation verification")
        }
        let presenter = try MetalFramePresenter(device: device)
        // Different colours in every corner expose flips and channel swaps;
        // non-opaque premultiplied pixels expose double alpha multiplication.
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                             0, 0, 255, 255, 64, 32, 16, 128]
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        try presenter.upload(image)
        func pixel(_ bytes: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
            Array(bytes[((y * width + x) * 4)..<((y * width + x) * 4 + 4)])
        }
        let native = try presenter.renderOffscreen(width: 2, height: 2)
        precondition(pixel(native, 2, 0, 0) == [0, 0, 255, 255])
        precondition(pixel(native, 2, 1, 0) == [0, 255, 0, 255])
        precondition(pixel(native, 2, 0, 1) == [255, 0, 0, 255])
        precondition(pixel(native, 2, 1, 1) == [16, 32, 64, 255])
        let wide = try presenter.renderOffscreen(width: 8, height: 4)
        precondition(pixel(wide, 8, 0, 0) == [0, 0, 0, 255])
        precondition(pixel(wide, 8, 2, 0) == [0, 0, 255, 255])
        precondition(pixel(wide, 8, 5, 3) == [16, 32, 64, 255])
        precondition(pixel(wide, 8, 7, 3) == [0, 0, 0, 255])
        let tall = try presenter.renderOffscreen(width: 4, height: 8)
        precondition(pixel(tall, 4, 0, 0) == [0, 0, 0, 255])
        precondition(pixel(tall, 4, 0, 2) == [0, 0, 255, 255])
        precondition(pixel(tall, 4, 3, 5) == [16, 32, 64, 255])
        presenter.clear()
        let empty = try presenter.renderOffscreen(width: 2, height: 2)
        precondition(empty == [0, 0, 0, 255, 0, 0, 0, 255,
                                0, 0, 0, 255, 0, 0, 0, 255])

        // Drawable gating: a request is only allowed while the window can
        // present, because nextDrawable blocks until availability or its
        // one second timeout.
        var gate = PresentationGate.State(
            drawableWidth: 1920, drawableHeight: 1080)
        precondition(PresentationGate.blockedReason(gate) == nil)
        gate.suspended = true
        precondition(PresentationGate.blockedReason(gate) == "presenter suspended")
        gate.suspended = false
        gate.hasWindow = false
        precondition(PresentationGate.blockedReason(gate) == "no window")
        gate.hasWindow = true
        gate.windowVisible = false
        precondition(PresentationGate.blockedReason(gate) == "window hidden")
        gate.windowVisible = true
        gate.windowMiniaturized = true
        precondition(PresentationGate.blockedReason(gate) == "window minimized")
        gate.windowMiniaturized = false
        gate.windowOccluded = true
        precondition(PresentationGate.blockedReason(gate) == "window occluded")
        gate.windowOccluded = false
        gate.drawableWidth = 0
        precondition(PresentationGate.blockedReason(gate) == "empty drawable")
        gate.drawableWidth = 1920
        precondition(PresentationGate.blockedReason(gate) == nil)
        // Suspension outranks window state so shutdown never waits.
        gate.windowOccluded = true
        gate.suspended = true
        precondition(PresentationGate.blockedReason(gate) == "presenter suspended")

        print("PASS: GPU shader, RGBA/BGRA, orientation, alpha, resize/letterbox, clear, drawable gating")
    }
}
