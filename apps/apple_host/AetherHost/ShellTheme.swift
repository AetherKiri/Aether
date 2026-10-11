import SwiftUI

extension ThemePalette.Ink {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}
private struct ShellPaletteKey: EnvironmentKey {
    static let defaultValue = ShellTheme.classic.palette
}
extension EnvironmentValues {
    var shellPalette: ThemePalette {
        get { self[ShellPaletteKey.self] }
        set { self[ShellPaletteKey.self] = newValue }
    }
}

struct LumenGroupBoxStyle: GroupBoxStyle {
    @Environment(\.shellPalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline).foregroundStyle(palette.primary.color)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(palette.surface.color, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                    palette.primary.color.opacity(contrast == .increased ? 0.4 : 0.12), lineWidth: 1))
        }
    }
}

/// Keeps native bordered button behavior, including keyboard focus and
/// disabled state. Its fill accounts for AppKit's white button labels.
struct LumenPrimaryAction: ViewModifier {
    @Environment(\.shellPalette) private var palette
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).tint(palette.controlAccent.color).foregroundStyle(.white)
    }
}
extension View {
    func lumenPrimaryAction() -> some View { modifier(LumenPrimaryAction()) }
}
