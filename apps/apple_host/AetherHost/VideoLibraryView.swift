import SwiftUI

struct VideoLibraryView: View {
    @ObservedObject var model: ShellModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CollectionHeader(title: model.text("videoLibrary"), count: String(format: model.text("videosCount"), model.videos.count),
                             searchLabel: model.text("searchVideos"), query: $model.videoQuery, list: $model.videoListLayout, model: model, video: true)
            if model.visibleVideos.isEmpty {
                CollectionEmptyView(title: model.text(model.videos.isEmpty ? "emptyVideos" : "noSearchResults"),
                                    message: model.text(model.videos.isEmpty ? "emptyVideosHelp" : "searchHelp"), icon: "film")
            } else {
                LibraryCollection(items: model.visibleVideos, list: model.videoListLayout, coordinateName: "videos",
                                  remembered: { model.videoScrollAnchor }, remember: { model.videoScrollAnchor = $0 }) { video in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { model.openVideo(video.url) } label: {
                            if model.videoListLayout {
                                HStack(spacing: 16) {
                                    artwork.frame(width: 80, height: 48)
                                    identity(video)
                                    Spacer()
                                    Image(systemName: "play.circle").foregroundStyle(.secondary)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    artwork.aspectRatio(16 / 9, contentMode: .fit)
                                    identity(video)
                                }
                            }
                        }.buttonStyle(.plain).disabled(!model.canOpenVideo).accessibilityLabel(video.displayTitle)
                        progress(video)
                        HStack {
                            Button(model.text("videoPlay")) { model.openVideo(video.url) }.disabled(!model.canOpenVideo)
                            Spacer()
                            Button(model.text("removeVideo"), role: .destructive) { model.pendingVideoRemoval = video }
                        }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        .contextMenu {
                            Button(model.text("folder")) { NSWorkspace.shared.activateFileViewerSelecting([video.url]) }
                            Button(model.text("removeVideo"), role: .destructive) { model.pendingVideoRemoval = video }
                        }
                }
            }
        }.padding(28).frame(maxWidth: 1240).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
            Image(systemName: "film").font(.title).foregroundStyle(.tint)
        }.accessibilityHidden(true)
    }

    private func identity(_ video: LibraryVideo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(video.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(2)
            Text(video.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if !FileManager.default.fileExists(atPath: video.path) {
                Label(model.text("videoMissing"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func progress(_ video: LibraryVideo) -> some View {
        if let entry = model.videoProgressEntries[video.url.standardizedFileURL.path] {
            if let duration = entry.duration, duration.isFinite, duration > 0 {
                ProgressView(value: min(max(entry.seconds, 0), duration), total: duration)
                    .accessibilityLabel(model.text("videoPosition"))
                Text("\(clock(entry.seconds)) / \(clock(duration))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(model.text("videoPosition")): \(clock(entry.seconds))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func clock(_ seconds: Double) -> String {
        let value = Int(min(max(seconds.isFinite ? seconds : 0, 0), Double(Int32.max)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
