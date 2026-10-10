import SwiftUI

struct MediaView: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var media: MediaController
    @State private var scrub = 0.0
    @State private var scrubbing = false

    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.closeVideo() } label: { Label(model.text("back"), systemImage: "chevron.left") }
                Text(model.activeVideo?.lastPathComponent ?? "").font(.headline).lineLimit(1)
                Spacer()
            }.padding(12)
            Divider()
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    Color.black
                    if let frame = media.frame {
                        Image(decorative: frame, scale: 1).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    if !media.subtitleText.isEmpty {
                        Text(media.subtitleText).font(.system(size: 24, weight: .semibold))
                            .multilineTextAlignment(.center).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.7)).padding(.horizontal, 24).padding(.bottom, 24)
                            .accessibilityLabel(media.subtitleText)
                    }
                }
            }
            VStack(spacing: 12) {
                HStack {
                    Text(time(scrubbing ? scrub : media.position)).monospacedDigit().frame(width: 60)
                    Slider(value: Binding(get: { scrubbing ? scrub : min(media.duration, max(0, media.position)) },
                                          set: { scrub = $0; if !scrubbing { media.seek(to: $0) } }), in: 0...max(0.001, media.duration)) { editing in
                        if editing { scrub = media.position; scrubbing = true }
                        else { scrubbing = false; media.seek(to: scrub) }
                    }.disabled(!media.seekable).accessibilityLabel(model.text("videoPosition"))
                    Text(time(media.duration)).monospacedDigit().frame(width: 60)
                }
                HStack(spacing: 18) {
                    Button { media.togglePlayback() } label: {
                        Label(model.text(media.playing ? "pause" : media.ended ? "replay" : "videoPlay"),
                              systemImage: media.playing ? "pause.fill" : "play.fill")
                    }.keyboardShortcut(.space, modifiers: [])
                    Button { media.seek(to: media.position - 10) } label: { Image(systemName: "gobackward.10") }
                        .disabled(!media.seekable).help(model.text("backward10"))
                    Button { media.seek(to: media.position + 10) } label: { Image(systemName: "goforward.10") }
                        .disabled(!media.seekable).help(model.text("forward10"))
                    Picker(model.text("videoRate"), selection: Binding(get: { media.rate }, set: { media.setRate($0) })) {
                        ForEach([0.5, 1, 1.25, 1.5, 2.0], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                    }.frame(width: 150)
                    Image(systemName: "speaker.wave.2.fill")
                    Slider(value: Binding(get: { media.volume }, set: { media.setVolume($0) }), in: 0...1)
                        .frame(width: 100).accessibilityLabel(model.text("volume"))
                    Spacer()
                    Picker(model.text("subtitles"), selection: Binding(get: { media.selectedSubtitle }, set: { media.selectSubtitle($0) })) {
                        Text(model.text("subtitlesOff")).tag("off")
                        ForEach(media.subtitles) { Text($0.label).tag($0.id) }
                    }.frame(maxWidth: 300)
                }
            }.padding(16)
        }
        .onChange(of: media.failureMessage) { message in
            if let message { model.closeVideo(); model.error = message }
        }
        .onChange(of: media.subtitleError) { message in
            if let message { model.error = message; media.subtitleError = nil }
        }
    }
}
