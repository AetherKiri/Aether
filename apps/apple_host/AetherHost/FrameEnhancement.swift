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
    /// AMD FidelityFX FSR1 EASU, ported from the published MIT reference.
    case fsr1Easu = "fsr1_easu"
    /// AMD FidelityFX FSR1 RCAS, ported from the published MIT reference.
    case fsr1Rcas = "fsr1_rcas"

    var id: String { rawValue }
    var textKey: String { "enhancement_" + rawValue }
    /// EASU owns the output scaling (edge-adaptive upscale); the others run as
    /// a same-size pass after the output pass, matching Godot's split between
    /// reconstruction/scaling and same-size restore.
    var scalesOutput: Bool { self == .fsr1Easu }
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

    /// FidelityFX FSR1 EASU (edge-adaptive spatial upscaling).
    ///
    /// Port of `FsrEasuF` / `FsrEasuSetF` / `FsrEasuTapF` from the published AMD
    /// FidelityFX FSR1 reference (`ffx-fsr/ffx_fsr1.h`, MIT; see
    /// THIRD_PARTY_LICENSES.md). The hardware `gather4` is emulated with four
    /// clamped point reads over the same 2x2 footprint, and the reference's
    /// approximate reciprocal/square-root are replaced by exact ones so the CPU
    /// reference and the Metal pass agree. Alpha is not produced by EASU; the
    /// presenter composites on opaque black, so the reference emits 255.
    static func fsr1Easu(_ pixels: [UInt8], width: Int, height: Int,
                         outputWidth: Int, outputHeight: Int) -> [UInt8] {
        guard width > 0, height > 0, outputWidth > 0, outputHeight > 0,
              pixels.count >= width * height * 4 else { return pixels }
        let iw = Double(width), ih = Double(height)
        let ow = Double(outputWidth), oh = Double(outputHeight)
        let con0 = SIMD4<Double>(iw / ow, ih / oh, 0.5 * iw / ow - 0.5, 0.5 * ih / oh - 0.5)
        let con1 = SIMD4<Double>(1 / iw, 1 / ih, 1 / iw, -1 / ih)
        let con2 = SIMD4<Double>(-1 / iw, 2 / ih, 1 / iw, 2 / ih)
        let con3 = SIMD4<Double>(0, 4 / ih, 0, 0)
        func sample(_ x: Double, _ y: Double, _ channel: Int) -> Double {
            let cx = min(width - 1, max(0, Int(floor(x))))
            let cy = min(height - 1, max(0, Int(floor(y))))
            return Double(pixels[(cy * width + cx) * 4 + channel]) / 255.0
        }
        func gather(_ p: SIMD2<Double>, _ channel: Int) -> SIMD4<Double> {
            let bx = floor(p.x * iw - 0.5), by = floor(p.y * ih - 0.5)
            return SIMD4(sample(bx, by, channel), sample(bx + 1, by, channel),
                         sample(bx, by + 1, channel), sample(bx + 1, by + 1, channel))
        }
        func accumulate(_ aC: inout SIMD3<Double>, _ aW: inout Double, _ off: SIMD2<Double>,
                        _ dir: SIMD2<Double>, _ len: SIMD2<Double>, _ lobe: Double,
                        _ clip: Double, _ color: SIMD3<Double>) {
            var v = SIMD2(off.x * dir.x + off.y * dir.y, off.x * (-dir.y) + off.y * dir.x)
            v *= len
            let d2 = min(v.x * v.x + v.y * v.y, clip)
            var wB = (2.0 / 5.0) * d2 - 1.0
            var wA = lobe * d2 - 1.0
            wB *= wB; wA *= wA
            wB = (25.0 / 16.0) * wB - (25.0 / 16.0 - 1.0)
            let weight = wB * wA
            aC += color * weight; aW += weight
        }
        func detect(_ dir: inout SIMD2<Double>, _ len: inout Double, _ pp: SIMD2<Double>,
                    _ s: Bool, _ t: Bool, _ u: Bool, _ v: Bool,
                    _ lA: Double, _ lB: Double, _ lC: Double, _ lD: Double, _ lE: Double) {
            var weight = 0.0
            if s { weight = (1 - pp.x) * (1 - pp.y) }
            if t { weight = pp.x * (1 - pp.y) }
            if u { weight = (1 - pp.x) * pp.y }
            if v { weight = pp.x * pp.y }
            let lenX = 1.0 / max(max(abs(lD - lC), abs(lC - lB)), 1e-30)
            let dirX = lD - lB
            dir.x += dirX * weight
            let lx = min(1.0, max(0.0, abs(dirX) * lenX))
            len += lx * lx * weight
            let lenY = 1.0 / max(max(abs(lE - lC), abs(lC - lA)), 1e-30)
            let dirY = lE - lA
            dir.y += dirY * weight
            let ly = min(1.0, max(0.0, abs(dirY) * lenY))
            len += ly * ly * weight
        }
        var output = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)
        for oy in 0..<outputHeight {
            for ox in 0..<outputWidth {
                var pp = SIMD2(Double(ox), Double(oy)) * SIMD2(con0.x, con0.y) + SIMD2(con0.z, con0.w)
                let fp = SIMD2(floor(pp.x), floor(pp.y))
                pp -= fp
                let p0 = fp * SIMD2(con1.x, con1.y) + SIMD2(con1.z, con1.w)
                let p1 = p0 + SIMD2(con2.x, con2.y)
                let p2 = p0 + SIMD2(con2.z, con2.w)
                let p3 = p0 + SIMD2(con3.x, con3.y)
                var bczz = [SIMD4<Double>](), ijfe = [SIMD4<Double>](), klhg = [SIMD4<Double>](), zzon = [SIMD4<Double>]()
                for channel in 0..<3 {
                    bczz.append(gather(p0, channel)); ijfe.append(gather(p1, channel))
                    klhg.append(gather(p2, channel)); zzon.append(gather(p3, channel))
                }
                func luma(_ v: [SIMD4<Double>]) -> SIMD4<Double> {
                    v[2] * 0.5 + (v[0] * 0.5 + v[1])
                }
                let bl = luma(bczz), il = luma(ijfe), kl = luma(klhg), zl = luma(zzon)
                var dir = SIMD2(0.0, 0.0), len = 0.0
                detect(&dir, &len, pp, true, false, false, false, bl.x, il.w, il.z, kl.w, il.y)
                detect(&dir, &len, pp, false, true, false, false, bl.y, il.z, kl.w, kl.z, kl.x)
                detect(&dir, &len, pp, false, false, true, false, il.z, il.x, il.y, kl.x, zl.w)
                detect(&dir, &len, pp, false, false, false, true, kl.w, il.y, kl.x, kl.y, zl.z)
                let dir2 = dir * dir
                let dirR2 = dir2.x + dir2.y
                let zero = dirR2 < 1.0 / 32768.0
                let dirR = zero ? 1.0 : 1.0 / sqrt(max(dirR2, 1e-30))
                dir.x = zero ? 1.0 : dir.x
                dir *= dirR
                len *= 0.5; len *= len
                let stretch = (dir.x * dir.x + dir.y * dir.y) / max(max(abs(dir.x), abs(dir.y)), 1e-30)
                let len2 = SIMD2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len)
                let lobe = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len
                let clip = 1.0 / max(lobe, 1e-30)
                let min4 = SIMD3(min(min(ijfe[0].z, klhg[0].w, ijfe[0].y), klhg[0].x),
                                 min(min(ijfe[1].z, klhg[1].w, ijfe[1].y), klhg[1].x),
                                 min(min(ijfe[2].z, klhg[2].w, ijfe[2].y), klhg[2].x))
                let max4 = SIMD3(max(max(ijfe[0].z, klhg[0].w, ijfe[0].y), klhg[0].x),
                                 max(max(ijfe[1].z, klhg[1].w, ijfe[1].y), klhg[1].x),
                                 max(max(ijfe[2].z, klhg[2].w, ijfe[2].y), klhg[2].x))
                func tap(_ a: SIMD4<Double>, _ b: SIMD4<Double>, _ c: SIMD4<Double>, _ index: Int) -> SIMD3<Double> {
                    SIMD3(a[index], b[index], c[index])
                }
                var aC = SIMD3(0.0, 0.0, 0.0); var aW = 0.0
                accumulate(&aC, &aW, SIMD2(0, -1) - pp, dir, len2, lobe, clip, tap(bczz[0], bczz[1], bczz[2], 0))
                accumulate(&aC, &aW, SIMD2(1, -1) - pp, dir, len2, lobe, clip, tap(bczz[0], bczz[1], bczz[2], 1))
                accumulate(&aC, &aW, SIMD2(-1, 1) - pp, dir, len2, lobe, clip, tap(ijfe[0], ijfe[1], ijfe[2], 0))
                accumulate(&aC, &aW, SIMD2(0, 1) - pp, dir, len2, lobe, clip, tap(ijfe[0], ijfe[1], ijfe[2], 1))
                accumulate(&aC, &aW, SIMD2(0, 0) - pp, dir, len2, lobe, clip, tap(ijfe[0], ijfe[1], ijfe[2], 2))
                accumulate(&aC, &aW, SIMD2(-1, 0) - pp, dir, len2, lobe, clip, tap(ijfe[0], ijfe[1], ijfe[2], 3))
                accumulate(&aC, &aW, SIMD2(1, 1) - pp, dir, len2, lobe, clip, tap(klhg[0], klhg[1], klhg[2], 0))
                accumulate(&aC, &aW, SIMD2(2, 1) - pp, dir, len2, lobe, clip, tap(klhg[0], klhg[1], klhg[2], 1))
                accumulate(&aC, &aW, SIMD2(2, 0) - pp, dir, len2, lobe, clip, tap(klhg[0], klhg[1], klhg[2], 2))
                accumulate(&aC, &aW, SIMD2(1, 0) - pp, dir, len2, lobe, clip, tap(klhg[0], klhg[1], klhg[2], 3))
                accumulate(&aC, &aW, SIMD2(1, 2) - pp, dir, len2, lobe, clip, tap(zzon[0], zzon[1], zzon[2], 2))
                accumulate(&aC, &aW, SIMD2(0, 2) - pp, dir, len2, lobe, clip, tap(zzon[0], zzon[1], zzon[2], 3))
                let average = aC * (1.0 / max(aW, 1e-30))
                let pixel = SIMD3(min(max4.x, max(min4.x, average.x)),
                                  min(max4.y, max(min4.y, average.y)),
                                  min(max4.z, max(min4.z, average.z)))
                let offset = (oy * outputWidth + ox) * 4
                output[offset] = UInt8(min(255, max(0, (pixel.x * 255).rounded())))
                output[offset + 1] = UInt8(min(255, max(0, (pixel.y * 255).rounded())))
                output[offset + 2] = UInt8(min(255, max(0, (pixel.z * 255).rounded())))
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
