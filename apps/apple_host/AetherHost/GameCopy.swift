import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bounded, cancellable managed copy. Source links and special files are denied;
/// final destination/index publication belongs to GameLibrary's transaction.
enum GameCopy {
    static func copy(_ source: URL, to destination: URL, maximumBytes: Int64?,
                     checkCancellation: (() throws -> Void)?, progress: ((Int64, Int64) -> Void)?) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        var failure: Error?
        guard let scan=fm.enumerator(at:source,includingPropertiesForKeys:Array(keys),errorHandler:{_,e in failure=e;return false}) else { throw GameLibrary.Failure.unsupported }
        var entries: [(URL,URLResourceValues)] = []
        var total: Int64=0
        for case let file as URL in scan {
            try checkCancellation?()
            let values=try file.resourceValues(forKeys:keys)
            guard values.isSymbolicLink != true else { throw GameLibrary.Failure.symbolicLink }
            guard values.isDirectory == true || values.isRegularFile == true else { throw GameLibrary.Failure.unsafeSource }
            if values.isRegularFile == true {
                let bytes=Int64(values.fileSize ?? 0)
                guard bytes >= 0, bytes <= Int64.max-total else { throw GameArchive.Failure.tooLarge }
                total += bytes
            }
            entries.append((file,values))
            guard entries.count <= 100_000 else { throw GameArchive.Failure.tooLarge }
        }
        if let failure { throw failure }
        if let maximumBytes, total > maximumBytes { throw GameArchive.Failure.tooLarge }
        try fm.createDirectory(at:destination,withIntermediateDirectories:true)
        let rootDescriptor=source.path.withCString { open($0,O_RDONLY | O_NOFOLLOW | O_DIRECTORY) }
        guard rootDescriptor >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        defer { close(rootDescriptor) }
        var written: Int64=0
        // Foundation can enumerate /private/var while standardizing its source
        // as /var. These aliases belong to the same selected root; keep child
        // spellings intact so openat/O_NOFOLLOW still rejects changed links.
        var aliases=[source.path,source.standardizedFileURL.path,source.resolvingSymlinksInPath().path]
        if let physical=source.path.withCString({realpath($0,nil)}) {
            aliases.append(String(cString:physical)); free(physical)
        }
        let prefixes=Set(aliases).map { $0.hasSuffix("/") ? $0 : $0+"/" }
        for (file,values) in entries {
            try checkCancellation?()
            guard let prefix=prefixes.first(where:{file.path.hasPrefix($0)}) else { throw GameLibrary.Failure.unsafeSource }
            let target=destination.appendingPathComponent(String(file.path.dropFirst(prefix.count)))
            if values.isDirectory == true {
                try fm.createDirectory(at:target,withIntermediateDirectories:true); continue
            }
            try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            let parts=String(file.path.dropFirst(prefix.count)).split(separator:"/").map(String.init)
            guard !parts.isEmpty, !parts.contains("..") else { throw GameLibrary.Failure.unsafeSource }
            var directory=dup(rootDescriptor)
            guard directory >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
            defer { close(directory) }
            for part in parts.dropLast() {
                let next=part.withCString { openat(directory,$0,O_RDONLY | O_NOFOLLOW | O_DIRECTORY) }
                guard next >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
                close(directory); directory=next
            }
            let descriptor=parts.last!.withCString { openat(directory,$0,O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
            guard descriptor >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
            let input=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
            defer { try? input.close() }
            var status=stat()
            guard fstat(descriptor,&status)==0, (status.st_mode & S_IFMT)==S_IFREG else { throw GameLibrary.Failure.unsafeSource }
            guard !fm.fileExists(atPath:target.path), fm.createFile(atPath:target.path,contents:nil) else { throw GameArchive.Failure.unsafe }
            let output=try FileHandle(forWritingTo:target)
            defer { try? output.close() }
            while true {
                try checkCancellation?()
                let data=try input.read(upToCount:256*1024) ?? Data()
                if data.isEmpty { break }
                guard Int64(data.count) <= (maximumBytes ?? Int64.max)-written else { throw GameArchive.Failure.tooLarge }
                try output.write(contentsOf:data); written += Int64(data.count)
                progress?(written,total)
            }
        }
        try checkCancellation?()
    }
}
