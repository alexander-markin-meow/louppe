import Darwin
import Foundation

// Darwin imports `struct statfs` under the same Swift name as statfs(2), so
// spell the C function explicitly while retaining exact filesystem paths.
@_silgen_name("statfs")
private func louppeStatFS(
    _ path: UnsafePointer<CChar>,
    _ information: UnsafeMutablePointer<Darwin.statfs>
) -> Int32

/// Read-only export preflight. It rejects destinations that would make copied
/// or moved media reappear inside the active session, and catches basic
/// permission/capacity problems before a long filesystem operation starts.
enum ExportDestinationValidator {
    enum ValidationError: LocalizedError, Equatable {
        case missingSourceFolder
        case sourceFolder
        case insideSourceFolder
        case crossVolumeMove
        case notDirectory
        case notWritable
        case insufficientSpace(required: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .missingSourceFolder:
                return "The source folder is no longer open."
            case .sourceFolder:
                return "Choose a destination outside the folder you are reviewing."
            case .insideSourceFolder:
                return "Choose a destination outside the folder you are reviewing. Exporting into one of its subfolders would make the exported media appear in this session again."
            case .crossVolumeMove:
                return "Move is currently limited to folders on the same storage volume. Choose Copy when exporting to another drive or card so Louppe never risks stranding an original during an interrupted transfer."
            case .notDirectory:
                return "The selected destination is not a folder."
            case .notWritable:
                return "Louppe does not have permission to write to that destination."
            case .insufficientSpace(let required, let available):
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let requiredText = formatter.string(fromByteCount: required)
                let availableText = formatter.string(fromByteCount: available)
                return "The destination does not have enough free space. \(requiredText) is required, but only \(availableText) is available."
            }
        }
    }

    @discardableResult
    static func validate(
        sourceFolder: URL?,
        destination: URL,
        items: [PhotoItem],
        mode: ExportMode
    ) throws -> URL {
        guard let sourceFolder else {
            throw ValidationError.missingSourceFolder
        }

        guard let resolvedSource = try? FileOperationJournal
            .resolvingSymlinksExactly(sourceFolder),
              let sourcePath = FileOperationJournal.exactPathBytes(
                for: resolvedSource
              ) else {
            throw ValidationError.missingSourceFolder
        }
        // Freeze the symlink-resolved directory selected during preflight.
        // Workers receive this exact path, so retargeting the original alias
        // after the dialog closes cannot redirect an export into the source
        // tree or onto a different volume.
        guard let validatedDestination = try? FileOperationJournal
            .resolvingSymlinksExactly(destination),
              let destinationPath = FileOperationJournal.exactPathBytes(
                for: validatedDestination
              ) else {
            throw ValidationError.notDirectory
        }
        if destinationPath == sourcePath
            || directoriesReferToSameEntry(
                resolvedSource,
                validatedDestination
            ) {
            throw ValidationError.sourceFolder
        }
        var sourcePrefix = sourcePath
        if sourcePrefix.count > 1 {
            sourcePrefix.append(UInt8(ascii: "/"))
        }
        if destinationPath.starts(with: sourcePrefix) {
            throw ValidationError.insideSourceFolder
        }

        let values = try? validatedDestination.resourceValues(forKeys: [
            .isDirectoryKey,
            .volumeIdentifierKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard values?.isDirectory == true else {
            throw ValidationError.notDirectory
        }
        guard isWritableDirectory(validatedDestination) else {
            throw ValidationError.notWritable
        }

        let required = items.reduce(Int64(0)) { partial, item in
            let (sum, overflowed) = partial.addingReportingOverflow(item.totalFileSize)
            return overflowed ? Int64.max : sum
        }
        let canRenameWithinVolume = mode == .move
            && moveCanUseAtomicRename(
                items: items,
                destinationVolumeIdentifier:
                    values?.volumeIdentifier as? AnyHashable
            )
        if mode == .move, !canRenameWithinVolume {
            throw ValidationError.crossVolumeMove
        }
        let importantUsageCapacity: Int64? =
            values?.volumeAvailableCapacityForImportantUsage
        let availableCapacity = effectiveAvailableCapacity(
            importantUsage: importantUsageCapacity,
            fileSystem: fileSystemAvailableCapacity(at: validatedDestination)
        )
        if !canRenameWithinVolume,
           required > 0,
           let available = availableCapacity,
           available < required {
            throw ValidationError.insufficientSpace(
                required: required,
                available: available
            )
        }
        return validatedDestination
    }

    /// `volumeAvailableCapacityForImportantUsage` can transiently report zero
    /// for File Provider-managed folders even while the underlying volume has
    /// ample space. A positive value is authoritative; zero is cross-checked
    /// against statfs. If neither API can provide a usable answer, Copy is
    /// allowed to proceed and the filesystem remains the final authority.
    static func effectiveAvailableCapacity(
        importantUsage: Int64?,
        fileSystem: Int64?
    ) -> Int64? {
        if let importantUsage, importantUsage > 0 {
            return importantUsage
        }
        if let fileSystem, fileSystem >= 0 {
            return fileSystem
        }
        return nil
    }

    private static func fileSystemAvailableCapacity(at url: URL) -> Int64? {
        var information = Darwin.statfs()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return louppeStatFS(path, &information)
        }
        guard result == 0 else { return nil }
        let (bytes, overflowed) = UInt64(information.f_bavail)
            .multipliedReportingOverflow(by: UInt64(information.f_bsize))
        return overflowed ? Int64.max : Int64(clamping: bytes)
    }

    static func directoriesReferToSameEntry(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = directoryIdentity(at: lhs),
              let right = directoryIdentity(at: rhs) else {
            return false
        }
        return left.device == right.device && left.inode == right.inode
    }

    private static func directoryIdentity(
        at url: URL
    ) -> (device: UInt64, inode: UInt64)? {
        var info = Darwin.stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.fstatat(AT_FDCWD, path, &info, 0)
        }
        guard result == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return nil
        }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private static func isWritableDirectory(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.access(path, W_OK) == 0
        }
    }

    /// Move currently relies on inode-preserving renames. Unknown or mixed
    /// volume identity fails closed; Copy remains available everywhere.
    static func moveCanUseAtomicRename(
        items: [PhotoItem],
        destination: URL
    ) -> Bool {
        return moveCanUseAtomicRename(
            items: items,
            destinationVolumeIdentifier: volumeIdentifier(at: destination)
        )
    }

    static func volumeIdentifiersAllowAtomicMove(
        source: [AnyHashable?],
        destination: AnyHashable?
    ) -> Bool {
        guard !source.isEmpty, let destination else { return false }
        return source.allSatisfy { $0 == destination }
    }

    private static func moveCanUseAtomicRename(
        items: [PhotoItem],
        destinationVolumeIdentifier: AnyHashable?
    ) -> Bool {
        let sourceIdentifiers = items
            .flatMap(\.allURLs)
            .map { volumeIdentifier(at: $0) }
        return volumeIdentifiersAllowAtomicMove(
            source: sourceIdentifiers,
            destination: destinationVolumeIdentifier
        )
    }

    private static func volumeIdentifier(at url: URL) -> AnyHashable? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeIdentifierKey]
        ),
        let identifier = values.volumeIdentifier else {
            return nil
        }
        return identifier as? AnyHashable
    }
}
