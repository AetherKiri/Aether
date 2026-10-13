import Foundation
import Combine

final class MobileImportControl: @unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    private var publishing=false
    private var finished=false
    private var lastProgress=0.0
    private var cancelCoordination: (() -> Void)?
    func cancel() -> Bool {
        lock.lock()
        guard !publishing, !finished else { lock.unlock(); return false }
        cancelled=true; let callback=cancelCoordination; lock.unlock()
        callback?(); return true
    }
    func bindCoordinationCancellation(_ callback: (() -> Void)?) {
        lock.lock(); cancelCoordination=callback; let invoke=cancelled; lock.unlock()
        if invoke {callback?()}
    }
    func check() throws {
        lock.lock(); let value=cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func publish(_ body: () throws -> Void) throws {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        publishing=true; lock.unlock()
        defer { lock.lock(); finished=true; lock.unlock() }
        try body()
    }
    func shouldReport() -> Bool {
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        guard now-lastProgress >= 0.25 else { return false }
        lastProgress=now; return true
    }
}

@MainActor
final class MobileLibraryState: ObservableObject {
    @Published private(set) var games: [LibraryGame] = []
    @Published private(set) var isImporting=false
    @Published private(set) var cancelling=false
    @Published private(set) var fraction: Double?
    @Published private(set) var bytes: Int64=0
    @Published var error: String?
    @Published private(set) var writable=true
    @Published private(set) var available: Set<UUID> = []
    private(set) var errorKey: String?
    let library: GameLibrary
    private var control: MobileImportControl?
    init(supportRoot: URL, gamesRoot: URL, initialLoad: Bool = true) {
        library=GameLibrary(root:supportRoot,managedGamesRoot:gamesRoot,supportedRuntimes:[.kirikiri],autoDiscoverCovers:true)
        if initialLoad {reload()}
    }
    func reload() {
        do { games=try library.backfillDefaultCovers(library.load(),includeExternal:false); refreshAvailability(); writable=true }
        catch { recordError(error); writable=false }
    }
    func cancelImport() { if control?.cancel() == true { cancelling=true } }
    func importURL(_ url: URL) async {
        guard writable, !isImporting else { return }
        let token=MobileImportControl(); control=token
        isImporting=true; cancelling=false; fraction=nil; bytes=0; error=nil; errorKey=nil
        let library=self.library, existing=games
        defer { if control === token { control=nil; isImporting=false; cancelling=false } }
        do {
            let result = try await Task.detached(priority:.userInitiated) { [weak self] in
                let scoped=url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try token.check()
                try FileManager.default.createDirectory(at:library.root,withIntermediateDirectories:true)
                let available=try? library.root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey,.volumeAvailableCapacityKey])
                let free=available?.volumeAvailableCapacityForImportantUsage ?? available?.volumeAvailableCapacity.map(Int64.init)
                let budget=free.map { max(0,$0-32*1024*1024) } ?? 32*1024*1024*1024
                var coordinatedError: NSError?
                var outcome: Result<[LibraryGame],Error>?
                let coordinator=NSFileCoordinator()
                token.bindCoordinationCancellation {coordinator.cancel()}
                defer {token.bindCoordinationCancellation(nil)}
                try token.check()
                coordinator.coordinate(readingItemAt:url,options:.withoutChanges,error:&coordinatedError) { source in
                    outcome=Result {
                        let progress: (Int64,Int64)->Void = { bytes,total in
                            guard token.shouldReport() else { return }
                            Task { @MainActor [weak self] in
                                guard let self, self.control === token else { return }
                                self.bytes=bytes; self.fraction=total>0 ? min(1,Double(bytes)/Double(total)) : nil
                            }
                        }
                        let imported: [LibraryGame]
                        if source.pathExtension.lowercased()=="zip" {
                            imported=try library.importArchive(source,existing:existing,
                                limits:.init(bytes:min(32*1024*1024*1024,budget/2)),
                                checkCancellation:token.check,progress:progress,publication:token.publish).games
                        } else {
                            imported=try library.importDirectory(source,existing:existing,
                                checkCancellation:token.check,progress:progress,maximumBytes:budget,
                                publication:token.publish).games
                        }
                        return imported
                    }
                }
                try token.check()
                if let coordinatedError { throw coordinatedError }
                guard let outcome else { throw CocoaError(.fileReadUnknown) }
                return try outcome.get()
            }.value
            games=result; refreshAvailability()
        } catch is CancellationError { /* Explicit cancellation leaves the index unchanged. */ }
        catch { recordError(error) }
    }
    private func refreshAvailability() {
        available=Set(games.filter { !$0.isExternal && ((try? library.isGame(library.gameURL($0))) == true) }.map(\.id))
    }
    func coverURL(_ game: LibraryGame) -> URL? {
        guard !game.isExternal, let url=library.coverURL(game) else {return nil}
        let path=url.resolvingSymlinksInPath().standardizedFileURL.path
        let containers=[library.root, library.gameURL(game)]
        return containers.contains { path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") } ? url : nil
    }
    private func recordError(_ error: Error) {
        if let failure=error as? GameLibrary.Failure {
            switch failure {
            case .unsupported: errorKey="mobileImportKiriHelp"
            case .invalidTitle: errorKey="invalidTitle"
            case .unsafeSource: errorKey="unsafeSource"
            case .symbolicLink: errorKey="symbolicLink"
            case .invalidManifest: errorKey="invalidIndex"
            }
        } else if let failure=error as? GameArchive.Failure {
            switch failure {
            case .invalid: errorKey="archiveInvalid"
            case .unsafe: errorKey="archiveUnsafe"
            case .tooLarge: errorKey="archiveLarge"
            case .ambiguous: errorKey="archiveAmbiguous"
            }
        } else if error is DecodingError {errorKey="invalidIndex"}
        else {errorKey=nil}
        self.error=error.localizedDescription
    }
    func rename(_ id: UUID, title: String) {
        guard writable, !isImporting else { return }
        do { games=try library.rename(id,title:title,existing:games) } catch { recordError(error) }
    }
    func remove(_ id: UUID) {
        guard writable, !isImporting else { return }
        do { games=try library.remove(id,existing:games) } catch { recordError(error) }
    }
}
