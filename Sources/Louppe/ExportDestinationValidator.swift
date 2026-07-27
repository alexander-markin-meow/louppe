import Foundation

/// Read-only export preflight. It rejects destinations that would make copied
/// or moved media reappear inside the active session, and catches basic
/// permission/capacity problems before a long filesystem operation starts.
enum ExportDestinationValidator {
    enum ValidationError: LocalizedError, Equatable {
        case missingSourceFolder
        case sourceFolder
        case insideSourceFolder
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

    static func validate(
        sourceFolder: URL?,
        destination: URL,
        items: [PhotoItem],
        mode: ExportMode
    ) throws {
        guard let sourceFolder else {
            throw ValidationError.missingSourceFolder
        }

        let sourcePath = canonicalPath(sourceFolder)
        let destinationPath = canonicalPath(destination)
        if destinationPath == sourcePath {
            throw ValidationError.sourceFolder
        }
        if destinationPath.hasPrefix(sourcePath + "/") {
            throw ValidationError.insideSourceFolder
        }

        let values = try? destination.resourceValues(forKeys: [
            .isDirectoryKey,
            .volumeIdentifierKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard values?.isDirectory == true else {
            throw ValidationError.notDirectory
        }
        guard FileManager.default.isWritableFile(atPath: destination.path) else {
            throw ValidationError.notWritable
        }

        let required = items.reduce(Int64(0)) { partial, item in
            let (sum, overflowed) = partial.addingReportingOverflow(item.totalFileSize)
            return overflowed ? Int64.max : sum
        }
        let sourceVolume = try? items.first?.primaryURL.resourceValues(
            forKeys: [.volumeIdentifierKey]
        ).volumeIdentifier
        let destinationVolume = values?.volumeIdentifier
        let canRenameWithinVolume = mode == .move
            && sourceVolume?.isEqual(destinationVolume) == true
        if !canRenameWithinVolume,
           required > 0,
           let available = values?.volumeAvailableCapacityForImportantUsage,
           available >= 0,
           Int64(available) < required {
            throw ValidationError.insufficientSpace(
                required: required,
                available: Int64(available)
            )
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
