import Foundation

/// Online cover lookup: request shape, response parsing and the injected
/// search/apply path on the model.
enum CoverSearchTests {
    private struct FakeSearch: CoverSearchProviding {
        let results: [CoverCandidate]
        func search(title: String) async throws -> [CoverCandidate] { results }
    }
    private struct FakeLoader: CoverImageLoading {
        let data: Data
        func load(_ url: URL) async throws -> Data { data }
    }
    private struct FailingLoader: CoverImageLoading {
        struct Boom: Error {}
        func load(_ url: URL) async throws -> Data { throw Boom() }
    }

    @MainActor static func run(root: URL) async throws {
        // The request carries only the title.
        let request = try VNDBCoverSearch.makeRequest(title: "  Demo  ")
        precondition(request.httpMethod == "POST")
        precondition(request.url?.absoluteString == "https://api.vndb.org/kana/vn")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        precondition((body["filters"] as? [String]) == ["search", "=", "Demo"])
        precondition(!String(describing: body).contains(root.path), "no local path may be sent")
        do { _ = try VNDBCoverSearch.makeRequest(title: "   "); preconditionFailure("empty title accepted") } catch {}

        // Parsing drops rows without an image.
        let json = #"{"results":[{"id":"v1","title":"Demo","image":{"url":"https://t.vndb.org/a.jpg","thumbnail":"https://t.vndb.org/at.jpg"}},{"id":"v2","title":"No Image"}]}"#
        let parsed = try VNDBCoverSearch.parse(Data(json.utf8))
        precondition(parsed.count == 1)
        precondition(parsed[0].id == "v1" && parsed[0].imageURL.absoluteString == "https://t.vndb.org/a.jpg")
        precondition(parsed[0].thumbnailURL.absoluteString == "https://t.vndb.org/at.jpg")

        // The model search/apply path, with injected fakes, caches the cover.
        let libraryRoot = root.appendingPathComponent("cover-library")
        let gameDir = libraryRoot.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let repository = GameLibrary(root: libraryRoot)
        let gameID = UUID()
        let game = LibraryGame(id: gameID, title: "Demo", directory: gameID.uuidString,
                               sourcePath: gameDir.path, importedAt: Date(), externalPath: gameDir.path)
        try repository.save([game])
        let model = ShellModel(root: libraryRoot)
        let candidate = parsed[0]
        model.coverSearch = FakeSearch(results: [candidate])
        model.coverImageLoader = FakeLoader(data: Data(repeating: 9, count: 32))
        await model.performCoverSearch()
        precondition(model.coverCandidates.count == 1 && !model.coverSearchBusy)
        let applied = await model.performCoverApply(candidate)
        precondition(applied)
        guard let cover = model.selectedGame?.coverPath else { preconditionFailure("cover not set") }
        precondition(cover.hasSuffix("vndb-v1.jpg"))
        precondition(FileManager.default.fileExists(atPath: cover))
        // A failing loader keeps the current cover and reports the failure.
        model.coverSearchError = nil
        model.coverImageLoader = FailingLoader()
        let failed = await model.performCoverApply(candidate)
        precondition(!failed)
        precondition(model.selectedGame?.coverPath == cover)
        print("PASS: online cover request shape, response parsing, injected search/apply and failure retention")
    }
}
