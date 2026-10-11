import SwiftUI

struct RenderingStatusView: View {
    @ObservedObject var engine: EngineController
    let language: ShellLanguage
    @Environment(\.shellPalette) private var palette
    var body: some View {
        if let effective = engine.renderState.effective, let presentation = engine.renderState.presentation {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: language.text("rendererStatus"), language.text(engine.renderState.requested.rawValue), language.text(effective.rawValue)))
                    .font(.caption).foregroundStyle(palette.secondary.color)
                Text(String(format: language.text("presentationStatus"), language.text(presentation == .metal ? "metalPresentation" : "imagePresentation")))
                    .font(.caption).foregroundStyle(palette.secondary.color)
                ForEach(Array(engine.renderState.fallbacks.enumerated()), id: \.offset) { _, fallback in
                    Label(language.text(fallback.reasonKey), systemImage: "exclamationmark.triangle")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    if !fallback.detail.isEmpty {
                        Text(fallback.detail).font(.caption).foregroundStyle(palette.secondary.color)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
