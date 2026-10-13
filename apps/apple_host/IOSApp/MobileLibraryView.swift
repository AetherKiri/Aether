import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct MobileDocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder, .zip]
    let selected: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:types,asCopy:false)
        picker.allowsMultipleSelection=false; picker.delegate=context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL?) -> Void
        init(_ selected: @escaping (URL?) -> Void) { self.selected=selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { selected(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { selected(nil) }
    }
}

struct MobileLibraryView: View {
    @ObservedObject var model: MobileLibraryState
    @ObservedObject var shell: MobileShellState
    @ObservedObject var preferences: MobilePreferencesState
    @Environment(\.shellPalette) private var palette
    private var language: ShellLanguage {shell.language}
    let play: (LibraryGame) -> Void
    private var visibleGames: [LibraryGame] {model.games.filter {query.isEmpty || $0.displayTitle.localizedStandardContains(query)}}
    @State private var query=""
    @State private var picker=false
    @State private var remove: LibraryGame?
    var body: some View {
        List {
            if model.isImporting {
                VStack(alignment:.leading) {
                    Text(language.text("importing"))
                    if let fraction=model.fraction { ProgressView(value:fraction) } else { ProgressView() }
                    Text(ByteCountFormatter.string(fromByteCount:model.bytes,countStyle:.file)).font(.caption)
                    Button(language.text("cancel")) { model.cancelImport() }.disabled(model.cancelling)
                }
            }
            ForEach(visibleGames) { game in
                NavigationLink {
                    MobileGameDetailView(model:model, id:game.id, language:language, play:play)
                } label: {
                    HStack {
                        MobileCoverThumbnail(url:model.coverURL(game)).frame(width:48,height:64)
                        Text(game.displayTitle).lineLimit(3)
                    }.frame(minHeight:64).padding(.vertical,preferences.settings.verticalPadding)
                }
                .listRowBackground(palette.surface.color)
                .swipeActions { Button(language.text("remove"),role:.destructive) { remove=game }.disabled(model.isImporting || model.isEditingCover) }
            }
        }
        .overlay {
            if !model.isImporting {
                if model.games.isEmpty {ContentUnavailableView(language.text("library"),systemImage:"books.vertical",description:Text(language.text("mobileImportKiriHelp")))}
                else if visibleGames.isEmpty {ContentUnavailableView.search(text:query)}
            }
        }
        .scrollContentBackground(.hidden).background(palette.background.color)
        .navigationTitle(language.text("library"))
        .searchable(text:$query, prompt:language.text("mobileLibrarySearch"))
        .toolbar { ToolbarItemGroup(placement:.topBarTrailing) {
            Menu {
                Picker(language.text("language"),selection:Binding(get:{shell.language},set:{preferences.quickLanguage($0)})) {
                    ForEach(ShellLanguage.allCases) {Text($0.name).tag($0)}
                }
            } label: {Label(language.text("language"),systemImage:"globe").frame(minWidth:44,minHeight:44)}
            Button { picker=true } label: { Label(language.text("import"),systemImage:"plus").frame(minWidth:44,minHeight:44) }
                .disabled(model.isImporting || model.isEditingCover || !model.writable)
        } }
        .sheet(isPresented:$picker) { MobileDocumentPicker { url in
            picker=false
            if let url { Task { await model.importURL(url) } }
        } }
        .confirmationDialog(language.text("remove"),isPresented:Binding(get:{remove != nil},set:{if !$0 {remove=nil}})) {
            Button(language.text("remove"),role:.destructive) { if let item=remove {model.remove(item.id)};remove=nil }
            Button(language.text("cancel"),role:.cancel) {remove=nil}
        } message: {Text(language.text("removeHelp"))}
        .alert(language.text("error"),isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {
            Button(language.text("ok")) {model.error=nil}
        } message: {Text(model.errorKey.map(language.text) ?? model.error ?? "")}
    }
}
struct MobileGameDetailView: View {
    @ObservedObject var model: MobileLibraryState
    @Environment(\.shellPalette) private var palette
    let id: UUID
    let language: ShellLanguage
    let play: (LibraryGame)->Void
    @StateObject private var cover: MobileCoverEditor
    @State private var coverPicker=false
    @State private var online=false
    init(model: MobileLibraryState, id: UUID, language: ShellLanguage, play: @escaping (LibraryGame)->Void) {
        self.model=model; self.id=id; self.language=language; self.play=play
        _cover=StateObject(wrappedValue:MobileCoverEditor(model:model,gameID:id))
    }
    @State private var rename=false
    @State private var title=""
    var body: some View {
        Group {
            if let game=model.games.first(where:{$0.id==id}) {
                Form {
                    Section {
                        MobileCoverThumbnail(url:model.coverURL(game)).frame(height:160)
                        Text(game.displayTitle).font(.title2)
                        Text("KiriKiri").foregroundStyle(.secondary)
                        Button(language.text("play")) {play(game)}.frame(minHeight:44).disabled(model.isImporting || model.isEditingCover || !model.available.contains(game.id))
                        if !model.available.contains(game.id) {Text(language.text("mobileImportKiriHelp")).font(.caption)}
                    }.listRowBackground(palette.surface.color)
                    Section {
                        Button(language.text("setCover")) {coverPicker=true}.disabled(!cover.canEdit)
                        Button(language.text("clearCover")) {cover.clear()}.disabled(!cover.canEdit || game.coverPath == nil)
                        Button(language.text("coverSearch")) {online=true}.disabled(!cover.canEdit)
                        Text(language.text("mobileCoverCopyHelp")).font(.caption).foregroundStyle(.secondary)
                        if cover.busy {ProgressView(); Button(language.text("cancel")) {cover.cancel()}}
                    }.listRowBackground(palette.surface.color)
                    Section {
                        Button(language.text("rename")) {title=game.title;rename=true}.frame(minHeight:44).disabled(model.isImporting || model.isEditingCover || !model.writable)
                    }.listRowBackground(palette.surface.color)
                }.listRowBackground(palette.surface.color).scrollContentBackground(.hidden).background(palette.background.color).navigationTitle(game.displayTitle)
            } else {ContentUnavailableView(language.text("library"),systemImage:"books.vertical")}
        }
        .sheet(isPresented:$coverPicker) {MobileDocumentPicker(types:[.image]) {url in
            coverPicker=false
            if let url {cover.selectFile(url)}
        }}
        .sheet(isPresented:$online,onDismiss:{cover.cancel()}) {
            NavigationStack {
                List {
                    Text(language.text("coverSearchHelp")).font(.callout)
                    Button(language.text("coverSearch")) {cover.searchOnline()}.disabled(cover.busy)
                    if cover.busy {ProgressView(); Button(language.text("cancel")) {cover.cancel()}}
                    ForEach(cover.candidates) {candidate in
                        Button {cover.selectCandidate(candidate)} label: {
                            HStack {
                                MobileRemoteCoverThumbnail(url:candidate.thumbnailURL).frame(width:64,height:88)
                                Text(candidate.title).lineLimit(3)
                            }
                        }.disabled(cover.busy)
                    }
                    if let key=cover.errorKey {Text(language.text(key)).foregroundStyle(.secondary)}
                }.navigationTitle(language.text("coverSearch"))
                .toolbar {ToolbarItem(placement:.cancellationAction) {Button(language.text("cancel")) {cover.cancel(); online=false}}}
            }
        }
        .onChange(of:cover.applied) {_, applied in if applied {online=false}}
        .onAppear {cover.activate()}
        .onDisappear {cover.deactivate()}
        .alert(language.text("error"),isPresented:Binding(get:{cover.errorKey != nil && !online},set:{if !$0 {cover.errorKey=nil}})) {
            Button(language.text("ok")) {cover.errorKey=nil}
        } message: {Text(language.text(cover.errorKey ?? "messageCoverFileMissing"))}
        .alert(language.text("rename"),isPresented:$rename) {
            TextField(language.text("gameTitle"),text:$title)
            Button(language.text("ok")) {model.rename(id,title:title)}
            Button(language.text("cancel"),role:.cancel) {}
        }
    }
}
struct MobileCoverThumbnail: View {
    let url: URL?
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {Image(uiImage:image).resizable().scaledToFit()}
            else {Image(systemName:"book.closed").resizable().scaledToFit().foregroundStyle(.secondary).padding(8)}
        }.task(id:url) {
            image=nil
            guard let url else {return}
            let thumbnail=await Task.detached(priority:.utility) {
                guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
                      let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:256,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else {return nil as UIImage?}
                return UIImage(cgImage:cg)
            }.value
            if !Task.isCancelled {image=thumbnail}
        }
    }
}

/// Fetches previews only after an explicit search, with the same byte/decode limits.
private struct MobileRemoteCoverThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {Image(uiImage:image).resizable().scaledToFit()}
            else {Image(systemName:"photo").foregroundStyle(.secondary)}
        }.task(id:url) {
            image=nil
            do {
                let data=try await MobileCoverImageLoader().load(url)
                let normalized=try await Task.detached(priority:.utility) {try MobileCoverImage.normalized(data)}.value
                if !Task.isCancelled {image=UIImage(data:normalized)}
            } catch { /* A failed preview never changes the selected cover. */ }
        }
    }
}
