import SwiftUI

private struct CollectionPositions: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Keep the top visible item when the detail page replaces the collection.
struct LibraryCollection<Item: Identifiable, Row: View>: View where Item.ID == UUID {
    let items: [Item]
    let list: Bool
    let coordinateName: String
    let remembered: () -> UUID?
    let remember: (UUID?) -> Void
    @ViewBuilder let row: (Item) -> Row
    @State private var restoring = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: list ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 24, alignment: .top)],
                          alignment: .leading, spacing: list ? 10 : 24) {
                    ForEach(items) { item in
                        row(item).id(item.id)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: CollectionPositions.self,
                                    value: [item.id: geometry.frame(in: .named(coordinateName)).minY])
                            })
                    }
                }.padding(.vertical, 16)
            }
            .coordinateSpace(name: coordinateName)
            .onPreferenceChange(CollectionPositions.self) { positions in
                guard !restoring else { return }
                let nearest = positions.min {
                    abs($0.value) == abs($1.value) ? $0.key.uuidString < $1.key.uuidString : abs($0.value) < abs($1.value)
                }?.key
                if let nearest { remember(nearest) }
            }
            .onAppear {
                let saved = remembered()
                if let saved { proxy.scrollTo(saved, anchor: .top) }
                DispatchQueue.main.async { restoring = false }
            }
            .onChange(of: list) { _ in
                if let saved = remembered() { proxy.scrollTo(saved, anchor: .top) }
            }
        }
    }
}

struct CollectionHeader: View {
    let title: String
    let count: String
    let searchLabel: String
    @Binding var query: String
    @Binding var list: Bool
    let model: ShellModel
    let video: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.bold())
                    Text(count).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button(video ? model.text("importVideo") : model.text("import")) {
                        if video { model.chooseVideo() } else { model.chooseImport() }
                    }.buttonStyle(.borderedProminent).disabled(video ? !model.canOpenVideo : !model.canImport)
                    if !video {
                        Button(model.text("linkGame")) { model.chooseImport(external: true) }
                            .disabled(!model.canImport).help(model.text("linkHelp"))
                    }
                }

            }
            HStack {
                TextField(searchLabel, text: $query).textFieldStyle(.roundedBorder)
                    .focused($searchFocused).accessibilityLabel(searchLabel)
                    .onExitCommand { if !query.isEmpty { query = "" } else { searchFocused = false } }
                Picker(model.text("collectionLayout"), selection: $list) {
                    Label(model.text("coverGrid"), systemImage: "square.grid.2x2").tag(false)
                    Label(model.text("compactList"), systemImage: "list.bullet").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Menu {
                    Text(model.text(video ? "emptyVideosHelp" : "archiveImportHelp"))
                    if !video {
                        Button(model.text("linkGame")) { model.chooseImport(external: true) }.disabled(!model.canImport)
                    }
                } label: { Label(model.text("collectionImportHelp"), systemImage: "questionmark.circle") }.fixedSize()
                Button(model.text("refresh")) { model.refreshLibrary() }.disabled(!model.canNavigateShell)
            }
            Button(searchLabel) { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden().frame(height: 0)
        }
    }
}

struct CollectionEmptyView: View {
    let title: String
    let message: String
    let icon: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }
}
