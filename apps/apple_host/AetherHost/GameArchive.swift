import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Extracts regular files itself; archive paths are never passed to a disk writer.
struct GameArchive {
    struct Limits {
        var entries = 100_000
        var bytes: Int64 = 32 * 1024 * 1024 * 1024
    }
    enum Failure: LocalizedError {
        case invalid, unsafe, tooLarge, ambiguous
        var errorDescription: String? {
            switch self {
            case .invalid: return "The ZIP is damaged, encrypted, or uses an unsupported encoding."
            case .unsafe: return "The ZIP contains unsafe paths, links, or conflicting filenames."
            case .tooLarge: return "The ZIP exceeds the import size or file count limit."
            case .ambiguous: return "The ZIP contains multiple game folders. Extract it and import one folder."
            }
        }
    }
    static func extract(_ source: URL, to destination: URL, limits: Limits = Limits(), checkCancellation: (() throws -> Void)? = nil,
                        progress: ((Int64, Int64) -> Void)? = nil) throws {
        let descriptor=source.path.withCString { open($0,O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw Failure.invalid }
        defer { close(descriptor) }
        var sourceStat=stat()
        guard fstat(descriptor,&sourceStat)==0, (sourceStat.st_mode & S_IFMT)==S_IFREG else { throw Failure.unsafe }
        guard let reader = archive_read_new() else { throw Failure.invalid }
        defer { archive_read_free(reader) }
        guard archive_read_support_format_zip(reader) == 0,
              archive_read_open_fd(reader, descriptor, 64 * 1024) == 0 else { throw Failure.invalid }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var names = Set<String>()
        var spellings: [String: String] = [:]
        var count = 0
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try checkCancellation?()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == 1 { break } // ARCHIVE_EOF
            guard status == 0, let entry,
                  let namePointer = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
                  let name = String(validatingUTF8: namePointer), !name.isEmpty else { throw Failure.invalid }
            count += 1
            guard count <= limits.entries else { throw Failure.tooLarge }
            let parts = name.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !parts.contains(".."), !parts.isEmpty,
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil else { throw Failure.unsafe }
            guard archive_entry_is_encrypted(entry) == 0 else { throw Failure.invalid }
            let path = parts.joined(separator: "/")
            for depth in 1...parts.count {
                let prefix = parts.prefix(depth).joined(separator: "/")
                let key = prefix.precomposedStringWithCanonicalMapping.lowercased()
                if let prior = spellings[key], prior != prefix { throw Failure.unsafe }
                spellings[key] = prefix
            }
            // APFS commonly ignores case and canonical Unicode differences.
            guard names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw Failure.unsafe }
            let type = archive_entry_filetype(entry)
            let target = destination.appendingPathComponent(path)
            if type == 0o040000 {
                guard archive_entry_size(entry) == 0 else { throw Failure.unsafe }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard type == 0o100000 else { throw Failure.unsafe }
            let declared = archive_entry_size(entry)
            guard declared >= 0, declared <= limits.bytes - total else { throw Failure.tooLarge }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: nil) else { throw Failure.unsafe }
            let file = try FileHandle(forWritingTo: target)
            do {
                var written: Int64 = 0
                while true {
                    try checkCancellation?()
                    let size = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                    guard size >= 0 else { throw Failure.invalid }
                    if size == 0 { break }
                    guard Int64(size) <= limits.bytes - total else { throw Failure.tooLarge }
                    total += Int64(size); written += Int64(size)
                    try file.write(contentsOf: Data(buffer.prefix(size)))
                    progress?(total, 0)
                }
                guard written == declared else { throw Failure.invalid }
                try file.close()
            } catch { try? file.close(); throw error }
        }
        guard count > 0 else { throw Failure.invalid }
    }
}
