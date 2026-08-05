import Darwin
import CryptoKit
import Foundation

struct XMPFileRevision: Equatable, Sendable {
    struct Timestamp: Equatable, Sendable {
        let seconds: Int64
        let nanoseconds: Int64
    }

    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modificationTime: Timestamp
    let statusChangeTime: Timestamp
    let birthTime: Timestamp

    fileprivate init(_ info: Darwin.stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        mode = UInt16(info.st_mode & mode_t(S_IFMT))
        size = info.st_size
        modificationTime = Timestamp(
            seconds: Int64(info.st_mtimespec.tv_sec),
            nanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
        statusChangeTime = Timestamp(
            seconds: Int64(info.st_ctimespec.tv_sec),
            nanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
        birthTime = Timestamp(
            seconds: Int64(info.st_birthtimespec.tv_sec),
            nanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
    }
}

struct XMPPreparedWrite: Sendable {
    enum Action: Equatable, Sendable {
        case create
        case update
        case alreadyCurrent
    }

    let path: XMPExactFileSystemPath
    let metadata: XMPPublicationMetadata
    let action: Action
    let finalPacket: Data
    let originalPacket: Data?
    let originalRevision: XMPFileRevision?

    var preflightFingerprint: XMPPreflightFingerprint {
        XMPPreflightFingerprint(
            action: action,
            originalRevision: originalRevision,
            originalDigest: originalPacket.map {
                Data(SHA256.hash(data: $0))
            }
        )
    }

    var existingChangeSummary: XMPFieldMapping.ExistingChangeSummary {
        guard action == .update, let originalPacket else { return .none }
        return (try? XMPFieldMapping.inspectExistingChanges(
            packet: originalPacket,
            metadata: metadata
        )) ?? .none
    }
}

struct XMPPreflightFingerprint: Equatable, Sendable {
    let action: XMPPreparedWrite.Action
    let originalRevision: XMPFileRevision?
    let originalDigest: Data?
}

struct XMPWriteResult: Equatable, Sendable {
    let path: XMPExactFileSystemPath
    let action: XMPPreparedWrite.Action
    let committedRevision: XMPFileRevision
}

struct XMPMetadataStoreTestHooks: @unchecked Sendable {
    var beforeFinalValidation: (() throws -> Void)?

    static let none = XMPMetadataStoreTestHooks()
}

actor XMPMetadataStore {
    enum StoreError: LocalizedError {
        case missingParent
        case unsafeFileType
        case packetTooLarge
        case fileChanged
        case couldNotOpen(Int32)
        case couldNotInspect(Int32)
        case couldNotRead(Int32)
        case permissionDenied(Int32)

        var errorDescription: String? {
            switch self {
            case .missingParent:
                return "The sidecar's parent folder is missing or unsafe."
            case .unsafeFileType:
                return "The XMP path is not a regular file."
            case .packetTooLarge:
                return "The XMP packet exceeds Louppe's 64 MiB safety limit."
            case .fileChanged:
                return "The XMP packet changed after preflight. Retry to merge the newer file."
            case .couldNotOpen(let code):
                return "The XMP packet could not be opened (\(code))."
            case .couldNotInspect(let code):
                return "The XMP path could not be inspected (\(code))."
            case .couldNotRead(let code):
                return "The XMP packet could not be read (\(code))."
            case .permissionDenied(let code):
                return "The XMP packet or its folder is read-only (\(code))."
            }
        }
    }

    private struct Snapshot {
        let data: Data
        let revision: XMPFileRevision
    }

    func prepareWrite(
        path: XMPExactFileSystemPath,
        metadata: XMPPublicationMetadata
    ) throws -> XMPPreparedWrite {
        try requireSafeParent(of: path)
        if let info = try lstat(path) {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw StoreError.unsafeFileType
            }
            let original = try readSnapshot(path)
            if (try? XMPFieldMapping.verify(
                packet: original.data,
                metadata: metadata
            )) != nil {
                return XMPPreparedWrite(
                    path: path,
                    metadata: metadata,
                    action: .alreadyCurrent,
                    finalPacket: original.data,
                    originalPacket: original.data,
                    originalRevision: original.revision
                )
            }
            let merged = try XMPFieldMapping.merge(
                packet: original.data,
                metadata: metadata
            )
            try XMPFieldMapping.verify(packet: merged, metadata: metadata)
            return XMPPreparedWrite(
                path: path,
                metadata: metadata,
                action: .update,
                finalPacket: merged,
                originalPacket: original.data,
                originalRevision: original.revision
            )
        }

        let created = try XMPFieldMapping.merge(
            packet: nil,
            metadata: metadata
        )
        try XMPFieldMapping.verify(packet: created, metadata: metadata)
        return XMPPreparedWrite(
            path: path,
            metadata: metadata,
            action: .create,
            finalPacket: created,
            originalPacket: nil,
            originalRevision: nil
        )
    }

    func commit(
        _ prepared: XMPPreparedWrite,
        testHooks: XMPMetadataStoreTestHooks = .none
    ) throws -> XMPWriteResult {
        try Task.checkCancellation()
        switch prepared.action {
        case .alreadyCurrent:
            let snapshot = try readSnapshot(prepared.path)
            guard snapshot.data == prepared.originalPacket,
                  snapshot.revision == prepared.originalRevision else {
                throw StoreError.fileChanged
            }
            try XMPFieldMapping.verify(
                packet: snapshot.data,
                metadata: prepared.metadata
            )
            return XMPWriteResult(
                path: prepared.path,
                action: .alreadyCurrent,
                committedRevision: snapshot.revision
            )

        case .create:
            try DurableFileIO.atomicCreate(
                prepared.finalPacket,
                at: prepared.path.url,
                fullSync: true
            ) {
                try testHooks.beforeFinalValidation?()
                try Task.checkCancellation()
                guard try self.lstat(prepared.path) == nil else {
                    throw StoreError.fileChanged
                }
                try self.requireSafeParent(of: prepared.path)
            }

        case .update:
            guard let expectedData = prepared.originalPacket,
                  let expectedRevision = prepared.originalRevision else {
                throw StoreError.fileChanged
            }
            try DurableFileIO.atomicWrite(
                prepared.finalPacket,
                to: prepared.path.url,
                fullSync: true
            ) {
                try testHooks.beforeFinalValidation?()
                try Task.checkCancellation()
                let live = try self.readSnapshot(prepared.path)
                guard live.revision == expectedRevision,
                      live.data == expectedData else {
                    throw StoreError.fileChanged
                }
            }
        }

        let committed = try readSnapshot(prepared.path)
        guard committed.data == prepared.finalPacket else {
            throw StoreError.fileChanged
        }
        try XMPFieldMapping.verify(
            packet: committed.data,
            metadata: prepared.metadata
        )
        return XMPWriteResult(
            path: prepared.path,
            action: prepared.action,
            committedRevision: committed.revision
        )
    }

    /// Advisory preflight only. The exact lstat/read/CAS boundary in `commit`
    /// remains authoritative because permissions may change after review.
    func requireWritable(_ prepared: XMPPreparedWrite) throws {
        let target = prepared.action == .create
            ? prepared.path.parent
            : prepared.path
        var failure: Int32 = 0
        let status = target.withFileSystemRepresentation { pointer in
            let result = Darwin.access(pointer, W_OK)
            if result != 0 { failure = errno }
            return result
        }
        guard status == 0 else {
            throw StoreError.permissionDenied(failure)
        }
    }

    private func requireSafeParent(
        of path: XMPExactFileSystemPath
    ) throws {
        guard let info = try lstat(path.parent),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw StoreError.missingParent
        }
    }

    private func readSnapshot(
        _ path: XMPExactFileSystemPath
    ) throws -> Snapshot {
        var openFailure: Int32 = 0
        let descriptor = path.withFileSystemRepresentation { pointer in
            var result: Int32
            repeat {
                result = Darwin.open(
                    pointer,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            } while result < 0 && errno == EINTR
            if result < 0 { openFailure = errno }
            return result
        }
        guard descriptor >= 0 else {
            if openFailure == ELOOP { throw StoreError.unsafeFileType }
            throw StoreError.couldNotOpen(openFailure)
        }
        defer { Darwin.close(descriptor) }

        let before = try descriptorStat(descriptor)
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw StoreError.unsafeFileType
        }
        guard before.st_size >= 0,
              before.st_size <= Int64(XMPFieldMapping.maximumPacketBytes) else {
            throw StoreError.packetTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw StoreError.couldNotRead(errno)
            }
            guard count <= XMPFieldMapping.maximumPacketBytes - data.count else {
                throw StoreError.packetTooLarge
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }

        let after = try descriptorStat(descriptor)
        let revision = XMPFileRevision(before)
        guard XMPFileRevision(after) == revision,
              let live = try lstat(path),
              XMPFileRevision(live) == revision else {
            throw StoreError.fileChanged
        }
        return Snapshot(data: data, revision: revision)
    }

    private func descriptorStat(_ descriptor: Int32) throws -> Darwin.stat {
        var info = Darwin.stat()
        var status: Int32
        repeat {
            status = Darwin.fstat(descriptor, &info)
        } while status != 0 && errno == EINTR
        guard status == 0 else {
            throw StoreError.couldNotInspect(errno)
        }
        return info
    }

    private func lstat(
        _ path: XMPExactFileSystemPath
    ) throws -> Darwin.stat? {
        var info = Darwin.stat()
        var failure: Int32 = 0
        let status = path.withFileSystemRepresentation { pointer in
            var result: Int32
            repeat {
                result = Darwin.lstat(pointer, &info)
            } while result != 0 && errno == EINTR
            if result != 0 { failure = errno }
            return result
        }
        if status == 0 { return info }
        if failure == ENOENT || failure == ENOTDIR { return nil }
        throw StoreError.couldNotInspect(failure)
    }
}
