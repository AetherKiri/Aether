import SwiftUI

struct RuntimeMovieView: View {
    @ObservedObject var movie: RuntimeMovieController
    let canvas: CGSize
    let skipLabel: String
    var body: some View {
        GeometryReader { geometry in
            if let request = movie.request {
                let rect = request.displayRectangle(canvas: canvas, viewport: geometry.size)
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Color.black
                        if let frame = movie.frame {
                            Image(decorative: frame, scale: 1).resizable().scaledToFit()
                        }
                    }.frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                    if request.skippable {
                        Button(skipLabel) { movie.skip() }.padding(18)
                    }
                }
            }
        }.clipped()
    }
}
