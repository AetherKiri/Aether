import SwiftUI

struct GameSurfaceView: View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var engine: EngineController
    var language: ShellLanguage = .system
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
            if engine.useMetalPresentation,
               let presenter = engine.metalPresenter,
               let texture = engine.nativeFrameTexture {
                MetalFrameView(presenter: presenter, image: nil,
                               nativeTexture: texture, nativeLease: engine.nativeFrameLease,
                               onFailure: engine.presentationFailed)
            } else if let image = engine.frameImage {
                if engine.useMetalPresentation, let presenter = engine.metalPresenter {
                    MetalFrameView(presenter: presenter, image: image,
                                   onFailure: engine.presentationFailed)
                } else {
                    Image(decorative: image, scale: 1)
                        .interpolation(.low)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                Text("无画面").foregroundStyle(.white.opacity(0.6))
            }
            GameInputView(
                contentSize: engine.frameSize,
                presentationSize: engine.outputFrameSize,
                onPointer: { type, x, y, dx, dy, button, modifiers in
                    engine.sendPointer(
                        type: type, x: x, y: y, dx: dx, dy: dy,
                        button: button, modifiers: modifiers)
                },
                onKey: { pressed, keyCode, modifiers, unicode in
                    engine.sendKey(
                        pressed: pressed, keyCode: keyCode,
                        modifiers: modifiers, unicode: unicode)
                },
                imeActiveProvider: { engine.gameTextInput.wantsHostIME },
                onComposeIME: { text, range in
                    engine.sendIMEPreedit(markedText: text, selectedRange: range)
                },
                onCommitText: { engine.commitComposedText($0) },
                caretCanvasPointProvider: { engine.gameTextCaretPoint }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            RuntimeMovieView(movie: engine.runtimeMovie, canvas: engine.frameSize,
                             skipLabel: language.text("skipMovie"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { reportDisplay(geometry.size) }
                .onChange(of: geometry.size) { reportDisplay($0) }
                .onChange(of: displayScale) { _ in reportDisplay(geometry.size) }
        })
    }

    private func reportDisplay(_ size: CGSize) {
        let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        DispatchQueue.main.async { engine.updateDisplayPixels(pixels) }
    }

}
