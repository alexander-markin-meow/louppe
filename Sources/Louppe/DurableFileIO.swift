import Darwin
import Foundation

// Darwin exposes both `struct flock` and `flock(2)` under the same C name;
// Swift imports the struct but cannot spell the function unambiguously.
@_silgen_name("flock")
private func louppeFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Small POSIX durability boundary shared by session persistence and file
/// transactions. Foundation's `.atomic` option protects readers from partial
/// JSON, but it does not express the required file-sync -> rename ->
/// directory-sync ordering for sudden power loss.
enum DurableFileIO {
    enum IOError: LocalizedError {
        case system(operation: String, path: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .system(let operation, let path, let code):
                let message = String(cString: strerror(code))
                return "\(operation) failed for \(path) (\(code): \(message))."
            }
        }
    }

    /// Serializes a filesystem transaction across every Louppe process that
    /// uses the same lock-file path. The descriptor stays open for the entire
    /// body, so process exit also releases the advisory lock automatically.
    ///
    /// Keep the lock file outside the photographer's folder: a read-only card
    /// must still be able to serialize a fallback save in Application Support.
    static func withExclusiveFileLock<Result>(
        at lockFile: URL,
        beforeLock: () -> Void = {},
        perform body: () throws -> Result
    ) throws -> Result {
        let parent = lockFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let descriptor = try openLockFile(lockFile)
        defer { Darwin.close(descriptor) }
        try requireDescriptorType(
            descriptor,
            type: mode_t(S_IFREG),
            path: lockFile.path,
            operation: "verify persistence lock"
        )

        // This hook exists solely so the two-persistence-instance durability
        // test can prove that its second writer reached the actual lock wait.
        beforeLock()
        var lockResult: Int32
        repeat {
            lockResult = louppeFlock(descriptor, LOCK_EX)
        } while lockResult != 0 && errno == EINTR
        guard lockResult == 0 else {
            throw IOError.system(
                operation: "acquire persistence lock",
                path: lockFile.path,
                code: errno
            )
        }
        defer {
            while louppeFlock(descriptor, LOCK_UN) != 0 && errno == EINTR {}
        }
        return try body()
    }

    /// Writes a new file in the destination directory, flushes its contents,
    /// atomically replaces the destination, then flushes the directory entry.
    /// `fullSync` additionally asks macOS to push device write caches before
    /// returning; use it for commit records and photographer-visible state.
    static func atomicWrite(
        _ data: Data,
        to destination: URL,
        fullSync: Bool,
        validateBeforeReplace: () throws -> Void = {}
    ) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".louppe-write-\(UUID().uuidString.lowercased()).tmp"
        )
        var shouldRemoveTemporary = false
        defer {
            if shouldRemoveTemporary {
                try? unlinkRegularFile(at: temporary)
            }
        }

        let descriptor = try openFileForCreation(temporary)
        shouldRemoveTemporary = true
        var closeNeeded = true
        defer {
            if closeNeeded { Darwin.close(descriptor) }
        }
        do {
            try writeAll(data, descriptor: descriptor, path: temporary.path)
            try syncDescriptor(
                descriptor,
                path: temporary.path,
                fullSync: fullSync
            )
            let closeResult = Darwin.close(descriptor)
            let closeFailure = errno
            closeNeeded = false
            guard closeResult == 0 else {
                throw IOError.system(
                    operation: "close",
                    path: temporary.path,
                    code: closeFailure
                )
            }
        } catch {
            throw error
        }

        // Run compare-and-swap guards only after the potentially slow write
        // and hardware flush. This narrows an external-edit race to the final
        // validation/rename syscall boundary while still leaving the existing
        // destination untouched when validation fails.
        try validateBeforeReplace()
        try replaceByRename(from: temporary, to: destination)
        shouldRemoveTemporary = false
        try syncDirectory(parent, fullSync: fullSync)
    }

    static func syncFile(at url: URL, fullSync: Bool) throws {
        let descriptor = try openDescriptor(
            url,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW,
            operation: "open file for sync"
        )
        defer { Darwin.close(descriptor) }
        try requireDescriptorType(
            descriptor,
            type: mode_t(S_IFREG),
            path: url.path,
            operation: "verify regular file"
        )
        try syncDescriptor(
            descriptor,
            path: url.path,
            fullSync: fullSync
        )
    }

    static func syncDirectory(_ url: URL, fullSync: Bool = false) throws {
        let descriptor = try openDescriptor(
            url,
            flags: O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW,
            operation: "open directory for sync"
        )
        defer { Darwin.close(descriptor) }
        try requireDescriptorType(
            descriptor,
            type: mode_t(S_IFDIR),
            path: url.path,
            operation: "verify directory"
        )
        try syncDescriptor(
            descriptor,
            path: url.path,
            fullSync: fullSync
        )
    }

    /// Persists both directory-entry changes made by a successful rename.
    /// Call this immediately after the rename syscall and before checkpointing
    /// the new journal state.
    static func syncRenameDirectories(
        from source: URL,
        to destination: URL,
        fullSync: Bool = false
    ) throws {
        let sourceParent = source.deletingLastPathComponent()
        let destinationParent = destination.deletingLastPathComponent()
        if destinationParent.path(percentEncoded: true)
            == sourceParent.path(percentEncoded: true) {
            try syncDirectory(destinationParent, fullSync: fullSync)
        } else {
            // Make the new name durable before the old name's removal. If
            // sudden power loss lands between these flushes, two names are a
            // recoverable ambiguity; zero names could lose the only path to an
            // original photograph.
            try syncDirectory(destinationParent, fullSync: fullSync)
            try syncDirectory(sourceParent, fullSync: fullSync)
        }
    }

    static func syncRemoval(of url: URL, fullSync: Bool = false) throws {
        try syncDirectory(
            url.deletingLastPathComponent(),
            fullSync: fullSync
        )
    }

    /// Exclusive, same-volume rename syscall. Directory syncing stays
    /// separate so callers can record that the side effect happened even if a
    /// later flush fails.
    static func atomicExclusiveRename(from source: URL, to destination: URL) throws {
        var failure: Int32 = 0
        let result: Int32 = source.withUnsafeFileSystemRepresentation {
            sourcePath in
            destination.withUnsafeFileSystemRepresentation {
                destinationPath in
                guard let sourcePath, let destinationPath else {
                    failure = EINVAL
                    return Int32(-1)
                }
                var status: Int32
                repeat {
                    status = Darwin.renamex_np(
                        sourcePath,
                        destinationPath,
                        UInt32(RENAME_EXCL)
                    )
                } while status != 0 && errno == EINTR
                if status != 0 { failure = errno }
                return status
            }
        }
        guard result == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: failure) ?? .EIO
            )
        }
    }

    /// Reads a bounded regular file without following a leaf symlink. Journal
    /// recovery uses this instead of `Data(contentsOf:)` so a malformed entry
    /// cannot redirect the reader or allocate unbounded memory at launch.
    static func readRegularFile(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes >= 0 else {
            throw IOError.system(
                operation: "validate read limit",
                path: url.path,
                code: EINVAL
            )
        }
        let descriptor = try openDescriptor(
            url,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            operation: "open regular file for read"
        )
        defer { Darwin.close(descriptor) }
        let info = try requireDescriptorType(
            descriptor,
            type: mode_t(S_IFREG),
            path: url.path,
            operation: "verify regular file"
        )
        guard info.st_size >= 0,
              info.st_size <= Int64(maximumBytes) else {
            throw IOError.system(
                operation: "bound regular-file read",
                path: url.path,
                code: EFBIG
            )
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let result = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if result == 0 { return data }
            if result < 0 {
                if errno == EINTR { continue }
                throw IOError.system(
                    operation: "read",
                    path: url.path,
                    code: errno
                )
            }
            let count = Int(result)
            guard count <= maximumBytes - data.count else {
                throw IOError.system(
                    operation: "bound regular-file read",
                    path: url.path,
                    code: EFBIG
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    /// Removes exactly one regular-file directory entry. Unlike
    /// `FileManager.removeItem`, this can never recurse through a directory if
    /// a recovery candidate is swapped after it was first inspected.
    static func unlinkRegularFile(at url: URL) throws {
        var info = Darwin.stat()
        var status: Int32 = -1
        var failure: Int32 = 0
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return
            }
            repeat {
                status = Darwin.lstat(path, &info)
            } while status != 0 && errno == EINTR
            if status != 0 {
                failure = errno
                return
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                failure = EFTYPE
                status = -1
                return
            }
            repeat {
                status = Darwin.unlink(path)
            } while status != 0 && errno == EINTR
            if status != 0 { failure = errno }
        }
        guard status == 0 else {
            throw IOError.system(
                operation: "unlink regular file",
                path: url.path,
                code: failure
            )
        }
    }

    private static func openFileForCreation(_ url: URL) throws -> Int32 {
        var failure: Int32 = 0
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return Int32(-1)
            }
            var value: Int32
            repeat {
                value = Darwin.open(
                    path,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            } while value < 0 && errno == EINTR
            if value < 0 { failure = errno }
            return value
        }
        guard descriptor >= 0 else {
            throw IOError.system(
                operation: "create temporary file",
                path: url.path,
                code: failure
            )
        }
        return descriptor
    }

    private static func openLockFile(_ url: URL) throws -> Int32 {
        var failure: Int32 = 0
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return Int32(-1)
            }
            var value: Int32
            repeat {
                value = Darwin.open(
                    path,
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            } while value < 0 && errno == EINTR
            if value < 0 { failure = errno }
            return value
        }
        guard descriptor >= 0 else {
            throw IOError.system(
                operation: "open persistence lock",
                path: url.path,
                code: failure
            )
        }
        return descriptor
    }

    private static func openDescriptor(
        _ url: URL,
        flags: Int32,
        operation: String
    ) throws -> Int32 {
        var failure: Int32 = 0
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return Int32(-1)
            }
            var value: Int32
            repeat {
                value = Darwin.open(path, flags)
            } while value < 0 && errno == EINTR
            if value < 0 { failure = errno }
            return value
        }
        guard descriptor >= 0 else {
            throw IOError.system(
                operation: operation,
                path: url.path,
                code: failure
            )
        }
        return descriptor
    }

    @discardableResult
    private static func requireDescriptorType(
        _ descriptor: Int32,
        type: mode_t,
        path: String,
        operation: String
    ) throws -> Darwin.stat {
        var info = Darwin.stat()
        var result: Int32
        repeat {
            result = Darwin.fstat(descriptor, &info)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw IOError.system(
                operation: operation,
                path: path,
                code: errno
            )
        }
        guard info.st_mode & mode_t(S_IFMT) == type else {
            throw IOError.system(
                operation: operation,
                path: path,
                code: EFTYPE
            )
        }
        return info
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        path: String
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    let code = result == 0 ? EIO : errno
                    throw IOError.system(
                        operation: "write",
                        path: path,
                        code: code
                    )
                }
            }
        }
    }

    private static func syncDescriptor(
        _ descriptor: Int32,
        path: String,
        fullSync: Bool
    ) throws {
        if fullSync {
            var result: Int32
            repeat {
                result = Darwin.fcntl(descriptor, F_FULLFSYNC)
            } while result != 0 && errno == EINTR
            if result == 0 { return }
            let code = errno
            // Some filesystems and directory descriptors do not implement
            // F_FULLFSYNC. `fsync` is still the strongest available contract.
            if code != EINVAL && code != ENOTSUP && code != ENOTTY {
                throw IOError.system(
                    operation: "full sync",
                    path: path,
                    code: code
                )
            }
        }
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw IOError.system(
                operation: "sync",
                path: path,
                code: errno
            )
        }
    }

    private static func replaceByRename(from source: URL, to destination: URL) throws {
        var failure: Int32 = 0
        let result: Int32 = source.withUnsafeFileSystemRepresentation {
            sourcePath in
            destination.withUnsafeFileSystemRepresentation {
                destinationPath in
                guard let sourcePath, let destinationPath else {
                    failure = EINVAL
                    return Int32(-1)
                }
                var status: Int32
                repeat {
                    status = Darwin.rename(sourcePath, destinationPath)
                } while status != 0 && errno == EINTR
                if status != 0 { failure = errno }
                return status
            }
        }
        guard result == 0 else {
            throw IOError.system(
                operation: "atomic replace",
                path: destination.path,
                code: failure
            )
        }
    }
}
