import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import Combine

/// Limits encoded bytes and decode dimensions before producing a durable thumbnail.
enum MobileCoverImage {
    static let maximumBytes = 16 * 1024 * 1024
    static func normalized(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              Int64(width) * Int64(height) <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CoverSearchError.invalidResponse }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CoverSearchError.invalidResponse
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder), output.length <= maximumBytes else { throw CoverSearchError.invalidResponse }
        return output as Data
    }
    static func read(_ url: URL, control: MobileImportControl? = nil) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        let coordinator=NSFileCoordinator()
        control?.bindCoordinationCancellation {coordinator.cancel()}
        defer {control?.bindCoordinationCancellation(nil)}
        try control?.check()
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result {
                guard try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isSymbolicLink != true else {
                    throw CoverSearchError.invalidResponse
                }
                let descriptor=source.path.withCString {open($0,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)}
                guard descriptor >= 0 else {throw CoverSearchError.invalidResponse}
                let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
                defer { try? handle.close() }
                var status=stat()
                guard fstat(descriptor,&status)==0, (status.st_mode & S_IFMT)==S_IFREG else {throw CoverSearchError.invalidResponse}
                try Task.checkCancellation(); try control?.check()
                let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                return try normalized(data)
            }
        }
        try control?.check()
        if let coordinationError { throw coordinationError }
        guard let result else { throw CoverSearchError.invalidResponse }
        return try result.get()
    }
}

struct MobileCoverImageLoader: CoverImageLoading {
    func load(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw CoverSearchError.invalidResponse }
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme?.lowercased() == "https",
              response.expectedContentLength <= MobileCoverImage.maximumBytes else { throw CoverSearchError.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < MobileCoverImage.maximumBytes else { throw CoverSearchError.invalidResponse }
            data.append(byte)
        }
        return data
    }
}

@MainActor
final class MobileCoverEditor: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var applied = false
    @Published private(set) var candidates: [CoverCandidate] = []
    @Published var errorKey: String?
    private let model: MobileLibraryState
    private let gameID: UUID
    private let search: any CoverSearchProviding
    private let loader: any CoverImageLoading
    @Published private var active = true
    private var generation = UUID()
    private var task: Task<Void, Never>?
    init(model: MobileLibraryState, gameID: UUID,
         search: any CoverSearchProviding = VNDBCoverSearch(), loader: any CoverImageLoading = MobileCoverImageLoader()) {
        self.model = model; self.gameID = gameID; self.search = search; self.loader = loader
    }
    var canEdit: Bool { active && model.writable && !model.isImporting && !busy && model.games.contains { $0.id == gameID && !$0.isExternal } }
    func activate() { active = true }
    func deactivate() { active = false; cancel() }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        if busy { model.isEditingCover = false }
        busy = false; candidates = []
    }
    private func begin() -> UUID? {
        guard canEdit, !model.isEditingCover else { return nil }
        errorKey = nil; applied = false; generation = UUID(); busy = true; model.isEditingCover = true
        return generation
    }
    private func finish(_ request: UUID) {
        guard generation == request else { return }
        busy = false; model.isEditingCover = false; task = nil
    }
    func searchOnline() {
        guard let title = model.games.first(where: { $0.id == gameID })?.displayTitle, let request = begin() else { return }
        candidates = []
        task = Task {
            defer { finish(request) }
            do {
                let results = try await search.search(title: title)
                guard generation == request, !Task.isCancelled else { return }
                candidates = results.filter { $0.imageURL.scheme?.lowercased() == "https" }
                if candidates.isEmpty { errorKey = "coverSearchEmpty" }
            } catch { if generation == request, !Task.isCancelled { errorKey = "coverSearchFailed" } }
        }
    }
    func selectFile(_ url: URL) {
        guard let request = begin() else { return }
        task = Task {
            defer { finish(request) }
            do {
                let control=MobileImportControl()
                let worker = Task.detached(priority: .userInitiated) { try MobileCoverImage.read(url,control:control) }
                let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel(); _ = control.cancel() }
                try await apply(data, request: request)
            } catch { if generation == request, !Task.isCancelled { errorKey = "messageCoverFileMissing" } }
        }
    }
    func selectCandidate(_ candidate: CoverCandidate) {
        guard candidates.contains(candidate), let request = begin() else { return }
        task = Task {
            defer { finish(request) }
            do {
                let data = try await loader.load(candidate.imageURL)
                let normalized = try await Task.detached(priority: .userInitiated) { try MobileCoverImage.normalized(data) }.value
                try await apply(normalized, request: request)
            } catch { if generation == request, !Task.isCancelled { errorKey = "coverSearchFailed" } }
        }
    }
    private func apply(_ data: Data, request: UUID) async throws {
        guard generation == request, !Task.isCancelled else { return }
        let directory = model.library.root.appendingPathComponent("Covers", isDirectory: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: url) } }
        guard generation == request, !Task.isCancelled,
              model.games.contains(where: { $0.id == gameID && !$0.isExternal }) else { return }
        try model.publishCover(gameID, url: url)
        published = true; applied = true; candidates = []
    }
    func clear() {
        guard canEdit, !model.isEditingCover else { return }
        cancel()
        do { try model.clearCover(gameID) } catch { errorKey = "messageCoverFileMissing" }
    }
}
