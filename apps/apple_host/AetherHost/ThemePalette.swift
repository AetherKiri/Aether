import Foundation

enum ShellTheme: String, Codable, CaseIterable, Identifiable {
    case dark, classic, warmDark = "warm_dark", warmLight = "warm_light"
    var id: String { rawValue }
    var textKey: String { "theme_" + rawValue }
    var palette: ThemePalette {
        switch self {
        case .dark:
            return ThemePalette(dark: true, background: 0x0c0d10, raised: 0x121418, surface: 0x15171c,
                                primary: 0xf3f4f6, secondary: 0xa0a5b0, accent: 0xff6a3d,
                                accent2: 0xffb23e, accent3: 0xff3d7f, success: 0x3ddc97,
                                onAccent: 0x16110f, accentText: 0xff8a66, danger: 0xff5c5c)
        case .classic:
            return ThemePalette(dark: false, background: 0xf4f3ef, raised: 0xf9f8f5, surface: 0xffffff,
                                primary: 0x16161a, secondary: 0x5d5d66, accent: 0x2f4bff,
                                accent2: 0x00a6a6, accent3: 0xff5a5f, success: 0x1f9d55,
                                onAccent: 0xffffff, accentText: 0x2640e6, danger: 0xe03131)
        case .warmDark:
            return ThemePalette(dark: true, background: 0x110d0a, raised: 0x17120e, surface: 0x1b1510,
                                primary: 0xf7efe6, secondary: 0xb4a595, accent: 0xe9a23b,
                                accent2: 0xf26b38, accent3: 0xc2410c, success: 0x6fcf7c,
                                onAccent: 0x1a1108, accentText: 0xf0b862, danger: 0xf06a5a)
        case .warmLight:
            return ThemePalette(dark: false, background: 0xf8f2e9, raised: 0xfdf9f3, surface: 0xfffcf7,
                                primary: 0x201812, secondary: 0x6d5f53, accent: 0xc8553d,
                                accent2: 0xe9a23b, accent3: 0x8c5e3c, success: 0x2f8f4e,
                                onAccent: 0xfffaf4, accentText: 0xb34a33, danger: 0xc9352b)
        }
    }
}

/// The content palette comes from Godot's aether_design_tokens.gd. AppKit
/// retains control geometry, focus rings, menus, sheets and file panels.
struct ThemePalette {
    struct Ink: Equatable {
        let hex: UInt32
        var red: Double { Double((hex >> 16) & 255) / 255 }
        var green: Double { Double((hex >> 8) & 255) / 255 }
        var blue: Double { Double(hex & 255) / 255 }
        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        func contrast(with other: Ink) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
    }
    let dark: Bool
    let background, raised, surface, primary, accent, onAccent, accentText, danger: Ink
    /// Secondary signal colours from the Godot Lumen tokens, used by the
    /// dashboards' progress rings and stat cards.
    let accent2, accent3, success: Ink
    var secondary: Ink
    /// AppKit prominent buttons use white labels even when the content palette
    /// specifies dark ink on orange. Keep the hue, lower luminance for labels.
    var controlAccent: Ink {
        let white = Ink(hex: 0xffffff)
        var factor = 1.0
        var result = accent
        while white.contrast(with: result) < 5 {
            factor *= 0.9
            let red = UInt32((accent.red * factor * 255).rounded())
            let green = UInt32((accent.green * factor * 255).rounded())
            let blue = UInt32((accent.blue * factor * 255).rounded())
            result = Ink(hex: red << 16 | green << 8 | blue)
        }
        return result
    }
    func increasedContrast() -> ThemePalette {
        var result = self
        result.secondary = primary
        return result
    }
    init(dark: Bool, background: UInt32, raised: UInt32, surface: UInt32, primary: UInt32,
         secondary: UInt32, accent: UInt32, accent2: UInt32, accent3: UInt32, success: UInt32,
         onAccent: UInt32, accentText: UInt32, danger: UInt32) {
        self.dark = dark
        self.background = Ink(hex: background); self.raised = Ink(hex: raised); self.surface = Ink(hex: surface)
        self.primary = Ink(hex: primary); self.secondary = Ink(hex: secondary); self.accent = Ink(hex: accent)
        self.accent2 = Ink(hex: accent2); self.accent3 = Ink(hex: accent3); self.success = Ink(hex: success)
        self.onAccent = Ink(hex: onAccent); self.accentText = Ink(hex: accentText); self.danger = Ink(hex: danger)
    }
}
