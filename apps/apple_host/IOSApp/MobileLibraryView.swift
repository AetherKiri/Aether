import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct MobileDocumentPicker: UIViewControllerRepresentable {
    let selected: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:[.folder,.zip],asCopy:false)
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
    private var language: ShellLanguage {shell.language}
    let play: (LibraryGame) -> Void
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
            ForEach(model.games) { game in
                NavigationLink {
                    MobileGameDetailView(model:model, id:game.id, language:language, play:play)
                } label: {
                    HStack {
                        MobileCoverThumbnail(url:model.coverURL(game)).frame(width:48,height:64)
                        Text(game.displayTitle).lineLimit(3)
                    }.frame(minHeight:64)
                }
                .swipeActions { Button(language.text("remove"),role:.destructive) { remove=game }.disabled(model.isImporting) }
            }
        }
        .overlay { if model.games.isEmpty && !model.isImporting { ContentUnavailableView(language.text("library"),systemImage:"books.vertical",description:Text(language.text("mobileImportKiriHelp"))) } }
        .navigationTitle(language.text("library"))
        .toolbar { ToolbarItemGroup(placement:.topBarTrailing) {
            Menu {
                Picker(language.text("language"),selection:$shell.language) {
                    ForEach(ShellLanguage.allCases) {Text($0.name).tag($0)}
                }
            } label: {Label(language.text("language"),systemImage:"globe").frame(minWidth:44,minHeight:44)}
            Button { picker=true } label: { Label(language.text("import"),systemImage:"plus").frame(minWidth:44,minHeight:44) }
                .disabled(model.isImporting || !model.writable)
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
    let id: UUID
    let language: ShellLanguage
    let play: (LibraryGame)->Void
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
                        Button(language.text("play")) {play(game)}.frame(minHeight:44).disabled(model.isImporting || !model.available.contains(game.id))
                        if !model.available.contains(game.id) {Text(language.text("mobileImportKiriHelp")).font(.caption)}
                    }
                    Section {
                        Button(language.text("rename")) {title=game.title;rename=true}.frame(minHeight:44).disabled(model.isImporting || !model.writable)
                    }
                }.navigationTitle(game.displayTitle)
            } else {ContentUnavailableView(language.text("library"),systemImage:"books.vertical")}
        }
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
