import SwiftUI

struct GameLibraryView: View {
    @Environment(\.shellPalette) private var palette
    @ObservedObject var model: ShellModel
    var body: some View {
        if let game = model.games.first(where: { $0.id == model.gameDetailID }) {
            GameDetailView(model: model, game: game)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                CollectionHeader(title: model.text("library"), count: String(format: model.text("gamesCount"), model.games.count),
                                 searchLabel: model.text("searchGames"), query: $model.gameQuery, list: $model.gameListLayout, model: model, video: false)
                if model.visibleGames.isEmpty {
                    CollectionEmptyView(title: model.text(model.games.isEmpty ? "empty" : "noSearchResults"),
                                        message: model.text(model.games.isEmpty ? "emptyHelp" : "searchHelp"), icon: "books.vertical")
                } else {
                    LibraryCollection(items: model.visibleGames, list: model.gameListLayout, coordinateName: "games",
                                      remembered: { model.gameScrollAnchor }, remember: { model.gameScrollAnchor = $0 }) { game in
                        Button { model.openGameDetails(game) } label: {
                            if model.gameListLayout {
                                HStack(spacing: 16) {
                                    GameCover(model: model, game: game).frame(width: 48, height: 64)
                                    identity(game)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(palette.secondary.color)
                                }.padding(12).background(palette.surface.color, in: RoundedRectangle(cornerRadius: 12))
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    GameCover(model: model, game: game).aspectRatio(0.72, contentMode: .fit)
                                    identity(game)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.buttonStyle(.plain).accessibilityLabel(game.displayTitle)
                            .contextMenu {
                                Button(model.text("rename")) { model.beginRename(game) }
                                Button(model.text("remove"), role: .destructive) { model.removeGame = game }
                            }
                    }
                }
            }.padding(28).frame(maxWidth: 1240).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func identity(_ game: LibraryGame) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(game.displayTitle).font(.headline).foregroundStyle(palette.primary.color).lineLimit(2)
            Text(model.text(game.isExternal ? "externalStorage" : "managedStorage")).font(.caption).foregroundStyle(palette.secondary.color)
            if let date = game.lastPlayedAt { Text(date, style: .date).font(.caption).foregroundStyle(palette.secondary.color) }
        }
    }
}

struct GameCover: View {
    @Environment(\.shellPalette) private var palette
    @ObservedObject var model: ShellModel
    let game: LibraryGame
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(palette.accent.color.opacity(palette.dark ? 0.16 : 0.10))
            if let image = model.coverImage(for: game) {
                GeometryReader { geometry in
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else { Image(systemName: "gamecontroller.fill").font(.system(size: 40)).foregroundStyle(.tint) }
        }.clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}

struct GameDetailView: View {
    @Environment(\.shellPalette) private var palette
    @ObservedObject var model: ShellModel
    let game: LibraryGame
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button { model.showGameCollection() } label: { Label(model.text("openLibrary"), systemImage: "chevron.left") }
                    .keyboardShortcut(.cancelAction)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 32) {
                        coverEditor.frame(width: 240)
                        information.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .top, spacing: 24) {
                            coverEditor.frame(width: 160)
                            summary.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        metadata
                    }
                }
            }.padding(32).frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
        }
    }
    private var coverEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            GameCover(model: model, game: game).aspectRatio(0.72, contentMode: .fit)
            Button(model.text("setCover")) { model.chooseCover() }.disabled(!model.canEditCover)
            if model.coverImage(for: game) != nil {
                Button(model.text("clearCover")) { model.clearSelectedCover() }.disabled(!model.canEditCover)
            }
        }
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 24) {
            summary
            metadata
        }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(game.displayTitle).font(.largeTitle.bold()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button { model.play() } label: { Label(model.text("play"), systemImage: "play.fill") }
                .lumenPrimaryAction().controlSize(.large).disabled(!model.canPlay)
        }
    }
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.repository.gameURL(game).path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    LabeledContent(model.text("imported")) { Text(game.importedAt, style: .date) }
                    LabeledContent(model.text("played")) {
                        if let date = game.lastPlayedAt { Text(date, style: .date) } else { Text(model.text("never")) }
                    }
                    if game.playDurationSeconds > 0 {
                        LabeledContent(model.text("playTime")) {
                            Text(String(format: model.text("dashPlayedLabel"), PlayStats.duration(game.playDurationSeconds)))
                        }
                    }
                    Text(model.text(game.isExternal ? "externalStorage" : "managedStorage")).foregroundStyle(palette.secondary.color)
                    if game.isExternal { Text(model.text("linkHelp")).font(.caption).foregroundStyle(palette.secondary.color) }
                    if !FileManager.default.fileExists(atPath: model.repository.gameURL(game).path) {
                        Text(model.text("missing")).foregroundStyle(palette.danger.color)
                    }
                }.padding(12)
            }
            HStack(spacing: 12) {
                Button(model.text("folder")) { NSWorkspace.shared.activateFileViewerSelecting([model.repository.gameURL(game)]) }
                Button(model.text("rename")) { model.beginRename(game) }.disabled(!model.canImport)
                Button(model.text("remove"), role: .destructive) { model.removeGame = game }.disabled(!model.canImport)
            }
        }
    }
}
