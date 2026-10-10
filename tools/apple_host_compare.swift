// Compare independent renderer captures, decoded into the same RGB space.
// Usage: xcrun swift tools/apple_host_compare.swift IMAGE_A IMAGE_B [MAX_DIFF]
import AppKit
let arguments = CommandLine.arguments
if arguments.count < 3 {
    fputs("Usage: apple_host_compare.swift IMAGE_A IMAGE_B [MAX_DIFF]\n", stderr)
    exit(2)
}
func bitmap(_ path: String) -> NSBitmapImageRep? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return NSBitmapImageRep(data: data)
}
guard let a = bitmap(arguments[1]),
      let b = bitmap(arguments[2]),
      a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
    fputs("FAIL: missing images or mismatched dimensions\n", stderr)
    exit(2)
}
var maximum = 0
var sum: UInt64 = 0
var changed = 0
var minX = a.pixelsWide, minY = a.pixelsHigh, maxX = -1, maxY = -1
for y in 0..<a.pixelsHigh {
    for x in 0..<a.pixelsWide {
        guard let ca = a.colorAt(x: x, y: y)?.usingColorSpace(NSColorSpace.deviceRGB),
              let cb = b.colorAt(x: x, y: y)?.usingColorSpace(NSColorSpace.deviceRGB) else {
            fputs("FAIL: cannot decode RGB pixel\n", stderr)
            exit(2)
        }
        var different = false
        for (va, vb) in [(ca.redComponent, cb.redComponent),
                         (ca.greenComponent, cb.greenComponent),
                         (ca.blueComponent, cb.blueComponent)] {
            let difference = abs(Int((va * 255).rounded()) - Int((vb * 255).rounded()))
            maximum = max(maximum, difference)
            sum += UInt64(difference)
            different = different || difference != 0
        }
        if different {
            changed += 1
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
}
let mean = Double(sum) / Double(a.pixelsWide * a.pixelsHigh * 3)
print("\(a.pixelsWide)x\(a.pixelsHigh): RGB max diff=\(maximum), mean=\(mean), changed pixels=\(changed)")
if changed > 0 { print("Changed bounds: (\(minX),\(minY))–(\(maxX),\(maxY))") }
let threshold = arguments.count > 3 ? Int(arguments[3]) ?? 0 : 0
exit(maximum <= threshold ? 0 : 1)
