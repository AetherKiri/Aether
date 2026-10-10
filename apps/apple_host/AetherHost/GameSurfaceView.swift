import SwiftUI

struct GameSurfaceView: View {
    @ObservedObject var engine: EngineController
    var language: ShellLanguage = .system
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
            if engine.useMetalPresentation,
               let presenter = engine.metalPresenter,
               let texture = engine.nativeFrameTexture {
                MetalFrameView(presenter: presenter, image: nil,
                               nativeTexture: texture, onFailure: engine.presentationFailed)
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
                onPointer: { type, x, y, dx, dy, button, modifiers in
                    engine.sendPointer(
                        type: type, x: x, y: y, dx: dx, dy: dy,
                        button: button, modifiers: modifiers)
                },
                onKey: { pressed, keyCode, modifiers, unicode in
                    engine.sendKey(
                        pressed: pressed, keyCode: keyCode,
                        modifiers: modifiers, unicode: unicode)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            RuntimeMovieView(movie: engine.runtimeMovie, canvas: engine.frameSize,
                             skipLabel: language.text("skipMovie"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
