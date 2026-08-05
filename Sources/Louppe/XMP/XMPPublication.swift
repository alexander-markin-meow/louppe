import Darwin
import Foundation

enum XMPPublicationCategory: String, CaseIterable, Sendable {
    case create
    case update
    case alreadyCurrent
    case copyUnchangedApplicationPacket
    case unsupportedMedia
    case sameStemMetadataConflict
    case destinationCollision
    case malformedXMP
    case readOnlyPermissionFailure
    case unsafeFileType
    case externalModificationConflict

    var label: String {
        switch self {
        case .create: return "Create"
        case .update: return "Update"
        case .alreadyCurrent: return "Already current"
        case .copyUnchangedApplicationPacket:
            return "Copy unchanged application packet"
        case .unsupportedMedia: return "Unsupported media"
        case .sameStemMetadataConflict: return "Same-stem metadata conflict"
        case .destinationCollision: return "Destination collision"
        case .malformedXMP: return "Malformed XMP"
        case .readOnlyPermissionFailure: return "Read-only or permission failure"
        case .unsafeFileType: return "Symlink or unsafe file type"
        case .externalModificationConflict: return "External modification conflict"
        }
    }

    var canPublish: Bool {
        self == .create || self == .update || self == .alreadyCurrent
    }

    var isConflict: Bool {
        self == .sameStemMetadataConflict
            || self == .destinationCollision
            || self == .externalModificationConflict
    }

    var isFailure: Bool {
        self == .malformedXMP
            || self == .readOnlyPermissionFailure
            || self == .unsafeFileType
    }
}

struct XMPPublicationChangeCounts: Equatable, Sendable {
    var stars = 0
    var colors = 0
    var flags = 0
    var keywords = 0

    static func + (
        lhs: XMPPublicationChangeCounts,
        rhs: XMPPublicationChangeCounts
    ) -> XMPPublicationChangeCounts {
        XMPPublicationChangeCounts(
            stars: lhs.stars + rhs.stars,
            colors: lhs.colors + rhs.colors,
            flags: lhs.flags + rhs.flags,
            keywords: lhs.keywords + rhs.keywords
        )
    }
}

struct XMPPublicationPlanEntry: Equatable, Sendable, Identifiable {
    let id: String
    let filenames: [String]
    let canonicalSidecar: XMPExactFileSystemPath?
    let metadata: XMPPublicationMetadata?
    let category: XMPPublicationCategory
    let message: String
    let fingerprint: XMPPreflightFingerprint?
    let changeCounts: XMPPublicationChangeCounts
    let bestEffortFilenames: [String]
    let applicationPacketCount: Int
    let excludedACRCompanionCount: Int
}

struct XMPPublicationPlan: Equatable, Sendable {
    let id: UUID
    let profile: XMPApplicationProfile
    let visibleDecisionKeywords: Bool
    let allowExternalLabelReplacement: Bool
    let selectedItemCount: Int
    let physicalFileCount: Int
    let entries: [XMPPublicationPlanEntry]

    var publishableCount: Int {
        entries.count(where: { $0.category.canPublish })
    }

    var bestEffortFilenames: [String] {
        Array(Set(entries.flatMap(\.bestEffortFilenames))).sorted()
    }

    var applicationPacketCount: Int {
        entries.reduce(0) { $0 + $1.applicationPacketCount }
    }

    var excludedACRCompanionCount: Int {
        entries.reduce(0) { $0 + $1.excludedACRCompanionCount }
    }

    var changeCounts: XMPPublicationChangeCounts {
        entries.reduce(XMPPublicationChangeCounts()) {
            $0 + $1.changeCounts
        }
    }

    func count(_ category: XMPPublicationCategory) -> Int {
        entries.count(where: { $0.category == category })
    }
}

struct XMPPublicationResult: Equatable, Sendable {
    let created: Int
    let updated: Int
    let alreadyCurrent: Int
    let skipped: Int
    let conflicts: Int
    let failed: Int
    let cancelled: Bool
    let details: [XMPPublicationPlanEntry]

    var completed: Int { created + updated + alreadyCurrent }
    var isClean: Bool {
        !cancelled && skipped == 0 && conflicts == 0 && failed == 0
    }
}

struct XMPPublicationInput: Sendable {
    let selectedItemCount: Int
    let selectedPhysicalFileCount: Int
    let selectedMediaPaths: Set<XMPExactFileSystemPath>
    let members: [XMPStemFamilyMember]
    let profile: XMPApplicationProfile
    let visibleDecisionKeywords: Bool
    let allowExternalLabelReplacement: Bool

    init(
        items: [PhotoItem],
        familyContextItems: [PhotoItem]? = nil,
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool = false
    ) throws {
        selectedItemCount = items.count
        let selectedFiles = items.flatMap(\.individualFiles)
        selectedPhysicalFileCount = selectedFiles.count(where: {
            $0.mediaKind == .photo
        })
        selectedMediaPaths = try Set(selectedFiles.map {
            try XMPExactFileSystemPath(url: $0.url)
        })
        self.profile = profile
        self.visibleDecisionKeywords = visibleDecisionKeywords
        self.allowExternalLabelReplacement = allowExternalLabelReplacement
        // A stem sidecar describes every same-stem physical file, including a
        // sibling currently excluded by the compact Export predicate. Capture
        // the whole live session as immutable conflict context, then retain
        // only families intersecting the selected paths during planning.
        let context = familyContextItems ?? items
        members = try context.flatMap { item in
            try item.individualFiles.map { file in
                try XMPStemFamilyMember(
                    mediaURL: file.url,
                    mediaKind: file.mediaKind,
                    metadata: XMPPublicationMetadata(
                        snapshot: file.metadataSnapshot,
                        profile: profile,
                        visibleDecisionKeywords: visibleDecisionKeywords,
                        allowExternalLabelRemoval: allowExternalLabelReplacement
                    )
                )
            }
        }
    }
}

final class XMPPublicationCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

enum XMPPublicationPlanner {
    typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void
    static let concurrencyLimit = 3

    private struct Job: Sendable {
        let order: Int
        let family: XMPSidecarFamilyPlan
    }

    private actor JobQueue {
        private let jobs: [Job]
        private var nextIndex = 0

        init(_ jobs: [Job]) { self.jobs = jobs }

        func next() -> Job? {
            guard jobs.indices.contains(nextIndex) else { return nil }
            defer { nextIndex += 1 }
            return jobs[nextIndex]
        }
    }

    private final class ThrottledProgress: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Int
        private let callback: Progress
        private var done = 0
        private var lastReport: UInt64 = 0

        init(total: Int, callback: @escaping Progress) {
            self.total = total
            self.callback = callback
        }

        func advance() {
            lock.lock()
            done += 1
            let currentDone = done
            let now = DispatchTime.now().uptimeNanoseconds
            let shouldReport = currentDone == total
                || now &- lastReport >= 50_000_000
            if shouldReport { lastReport = now }
            lock.unlock()
            if shouldReport { callback(currentDone, total) }
        }
    }

    static func preflight(
        _ input: XMPPublicationInput,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping Progress
    ) async -> XMPPublicationPlan? {
        if isCancelled() { return nil }
        let families = resolveFamilies(input.members).filter { family in
            family.members.contains {
                input.selectedMediaPaths.contains($0.mediaPath)
            }
        }
        let reporter = ThrottledProgress(total: families.count, callback: progress)
        let jobs = families.enumerated().map {
            Job(order: $0.offset, family: $0.element)
        }
        let queue = JobQueue(jobs)
        var preparedEntries: [(Int, XMPPublicationPlanEntry)] = []
        await withTaskGroup(of: [(Int, XMPPublicationPlanEntry)].self) { group in
            let workers = min(concurrencyLimit, max(jobs.count, 1))
            for _ in 0..<workers {
                group.addTask {
                    let store = XMPMetadataStore()
                    var local: [(Int, XMPPublicationPlanEntry)] = []
                    while !isCancelled(), let job = await queue.next() {
                        local.append((
                            job.order,
                            await preflightEntry(job.family, store: store)
                        ))
                        reporter.advance()
                    }
                    return local
                }
            }
            for await local in group { preparedEntries.append(contentsOf: local) }
        }
        guard !isCancelled(), preparedEntries.count == families.count else {
            return nil
        }
        return XMPPublicationPlan(
            id: UUID(),
            profile: input.profile,
            visibleDecisionKeywords: input.visibleDecisionKeywords,
            allowExternalLabelReplacement: input.allowExternalLabelReplacement,
            selectedItemCount: input.selectedItemCount,
            physicalFileCount: input.selectedPhysicalFileCount,
            entries: preparedEntries.sorted { $0.0 < $1.0 }.map(\.1)
        )
    }

    private static func resolveFamilies(
        _ members: [XMPStemFamilyMember]
    ) -> [XMPSidecarFamilyPlan] {
        let grouped = Dictionary(
            grouping: members,
            by: { $0.mediaPath.parent }
        )
        return grouped.keys
            .sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
            .flatMap { directory in
                let directoryMembers = grouped[directory] ?? []
                do {
                    return try XMPSidecarResolver.resolve(members: directoryMembers)
                } catch {
                    return directoryMembers.map { member in
                        XMPSidecarFamilyPlan(
                            members: [member],
                            canonicalSidecar: nil,
                            extensionQualifiedSidecars: [],
                            excludedACRCompanions: [],
                            metadata: nil,
                            disposition: .filenameCollision
                        )
                    }
                }
            }
    }

    private static func preflightEntry(
        _ family: XMPSidecarFamilyPlan,
        store: XMPMetadataStore
    ) async -> XMPPublicationPlanEntry {
        let filenames = family.members.map {
            $0.mediaPath.url.lastPathComponent
        }.sorted()
        let id = family.members.first?.mediaPath.bytes.base64EncodedString()
            ?? UUID().uuidString
        let bestEffort = family.members.compactMap { member in
            bestEffortExtensions.contains(
                member.mediaPath.url.pathExtension.lowercased()
            ) ? member.mediaPath.url.lastPathComponent : nil
        }.sorted()
        let base = BaseEntry(
            id: id,
            filenames: filenames,
            bestEffortFilenames: bestEffort,
            applicationPacketCount: family.extensionQualifiedSidecars.count,
            excludedACRCompanionCount: family.excludedACRCompanions.count
        )
        switch family.disposition {
        case .unsupportedMedia:
            return base.entry(
                category: .unsupportedMedia,
                message: "Video files do not support XMP publication."
            )
        case .metadataConflict:
            return base.entry(
                sidecar: family.canonicalSidecar,
                category: .sameStemMetadataConflict,
                message: "Files sharing this stem have different Louppe metadata and will be skipped."
            )
        case .filenameCollision:
            return base.entry(
                category: .destinationCollision,
                message: "More than one filesystem name resolves to this sidecar; nothing will be overwritten."
            )
        case .publish:
            guard let path = family.canonicalSidecar,
                  let metadata = family.metadata else {
                return base.entry(
                    category: .destinationCollision,
                    message: "Louppe could not determine one safe sidecar path."
                )
            }
            do {
                let prepared = try await store.prepareWrite(
                    path: path,
                    metadata: metadata
                )
                if prepared.action != .alreadyCurrent {
                    try await store.requireWritable(prepared)
                }
                let category: XMPPublicationCategory
                switch prepared.action {
                case .create: category = .create
                case .update: category = .update
                case .alreadyCurrent: category = .alreadyCurrent
                }
                let changes = prepared.existingChangeSummary
                return base.entry(
                    sidecar: path,
                    metadata: metadata,
                    category: category,
                    message: category == .alreadyCurrent
                        ? "The sidecar already contains the selected Louppe metadata."
                        : "The sidecar is ready to \(category == .create ? "create" : "update").",
                    fingerprint: prepared.preflightFingerprint,
                    changeCounts: XMPPublicationChangeCounts(
                        stars: changes.stars ? 1 : 0,
                        colors: changes.color ? 1 : 0,
                        flags: changes.flag ? 1 : 0,
                        keywords: changes.keywords ? 1 : 0
                    )
                )
            } catch {
                return base.entry(
                    sidecar: path,
                    metadata: metadata,
                    category: category(for: error),
                    message: error.localizedDescription
                )
            }
        }
    }

    private struct BaseEntry {
        let id: String
        let filenames: [String]
        let bestEffortFilenames: [String]
        let applicationPacketCount: Int
        let excludedACRCompanionCount: Int

        func entry(
            sidecar: XMPExactFileSystemPath? = nil,
            metadata: XMPPublicationMetadata? = nil,
            category: XMPPublicationCategory,
            message: String,
            fingerprint: XMPPreflightFingerprint? = nil,
            changeCounts: XMPPublicationChangeCounts = .init()
        ) -> XMPPublicationPlanEntry {
            XMPPublicationPlanEntry(
                id: id,
                filenames: filenames,
                canonicalSidecar: sidecar,
                metadata: metadata,
                category: category,
                message: message,
                fingerprint: fingerprint,
                changeCounts: changeCounts,
                bestEffortFilenames: bestEffortFilenames,
                applicationPacketCount: applicationPacketCount,
                excludedACRCompanionCount: excludedACRCompanionCount
            )
        }
    }

    private static let bestEffortExtensions: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "dng", "heic", "heif", "png",
    ]

    static func category(for error: Error) -> XMPPublicationCategory {
        if let mapping = error as? XMPFieldMappingError {
            switch mapping {
            case .ownershipConflict:
                return .externalModificationConflict
            case .invalidPacket, .serialization, .verification, .propertyMissing:
                return .malformedXMP
            }
        }
        if let store = error as? XMPMetadataStore.StoreError {
            switch store {
            case .unsafeFileType, .missingParent:
                return .unsafeFileType
            case .fileChanged:
                return .externalModificationConflict
            case .permissionDenied:
                return .readOnlyPermissionFailure
            case .couldNotOpen(let code), .couldNotInspect(let code),
                 .couldNotRead(let code):
                return code == EACCES || code == EPERM || code == EROFS
                    ? .readOnlyPermissionFailure
                    : .malformedXMP
            case .packetTooLarge:
                return .malformedXMP
            }
        }
        return .readOnlyPermissionFailure
    }
}

enum XMPPublicationWorker {
    typealias Progress = XMPPublicationPlanner.Progress

    private actor EntryQueue {
        private let entries: [XMPPublicationPlanEntry]
        private var nextIndex = 0

        init(_ entries: [XMPPublicationPlanEntry]) { self.entries = entries }

        func next() -> XMPPublicationPlanEntry? {
            guard entries.indices.contains(nextIndex) else { return nil }
            defer { nextIndex += 1 }
            return entries[nextIndex]
        }
    }

    private struct Partial: Sendable {
        var created = 0
        var updated = 0
        var alreadyCurrent = 0
        var details: [XMPPublicationPlanEntry] = []
    }

    static func publish(
        _ plan: XMPPublicationPlan,
        cancelFlag: XMPPublicationCancelFlag,
        progress: @escaping Progress
    ) async -> XMPPublicationResult {
        let publishable = plan.entries.filter(\.category.canPublish)
        let queue = EntryQueue(publishable)
        let reporter = XMPPublicationPlanner.ThrottledProgressForWorker(
            total: publishable.count,
            callback: progress
        )
        var partials: [Partial] = []
        await withTaskGroup(of: Partial.self) { group in
            let workers = min(
                XMPPublicationPlanner.concurrencyLimit,
                max(publishable.count, 1)
            )
            for _ in 0..<workers {
                group.addTask {
                    let store = XMPMetadataStore()
                    var partial = Partial()
                    while !cancelFlag.isSet, let entry = await queue.next() {
                        guard let path = entry.canonicalSidecar,
                              let metadata = entry.metadata,
                              let fingerprint = entry.fingerprint else {
                            partial.details.append(runtimeFailure(
                                entry,
                                category: .unsafeFileType,
                                message: "The immutable publication plan is incomplete."
                            ))
                            reporter.advance()
                            continue
                        }
                        do {
                            let prepared = try await store.prepareWrite(
                                path: path,
                                metadata: metadata
                            )
                            guard prepared.preflightFingerprint == fingerprint else {
                                throw XMPMetadataStore.StoreError.fileChanged
                            }
                            if cancelFlag.isSet { break }
                            let result = try await store.commit(
                                prepared,
                                testHooks: XMPMetadataStoreTestHooks(
                                    beforeFinalValidation: {
                                        if cancelFlag.isSet {
                                            throw CancellationError()
                                        }
                                    }
                                )
                            )
                            switch result.action {
                            case .create: partial.created += 1
                            case .update: partial.updated += 1
                            case .alreadyCurrent: partial.alreadyCurrent += 1
                            }
                        } catch is CancellationError {
                            break
                        } catch {
                            partial.details.append(runtimeFailure(
                                entry,
                                category: XMPPublicationPlanner.category(for: error),
                                message: error.localizedDescription
                            ))
                        }
                        reporter.advance()
                    }
                    return partial
                }
            }
            for await partial in group { partials.append(partial) }
        }

        let preflightIssues = plan.entries.filter { !$0.category.canPublish }
        let runtimeIssues = partials.flatMap(\.details)
        let details = preflightIssues + runtimeIssues
        let conflicts = details.count(where: { $0.category.isConflict })
        let failed = details.count(where: { $0.category.isFailure })
        let skipped = details.count - conflicts - failed
        return XMPPublicationResult(
            created: partials.reduce(0) { $0 + $1.created },
            updated: partials.reduce(0) { $0 + $1.updated },
            alreadyCurrent: partials.reduce(0) { $0 + $1.alreadyCurrent },
            skipped: skipped,
            conflicts: conflicts,
            failed: failed,
            cancelled: cancelFlag.isSet,
            details: details
        )
    }

    private static func runtimeFailure(
        _ entry: XMPPublicationPlanEntry,
        category: XMPPublicationCategory,
        message: String
    ) -> XMPPublicationPlanEntry {
        XMPPublicationPlanEntry(
            id: entry.id,
            filenames: entry.filenames,
            canonicalSidecar: entry.canonicalSidecar,
            metadata: entry.metadata,
            category: category,
            message: message,
            fingerprint: entry.fingerprint,
            changeCounts: entry.changeCounts,
            bestEffortFilenames: entry.bestEffortFilenames,
            applicationPacketCount: entry.applicationPacketCount,
            excludedACRCompanionCount: entry.excludedACRCompanionCount
        )
    }
}

private extension XMPPublicationPlanner {
    final class ThrottledProgressForWorker: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Int
        private let callback: Progress
        private var done = 0
        private var lastReport: UInt64 = 0

        init(total: Int, callback: @escaping Progress) {
            self.total = total
            self.callback = callback
        }

        func advance() {
            lock.lock()
            done += 1
            let currentDone = done
            let now = DispatchTime.now().uptimeNanoseconds
            let shouldReport = currentDone == total
                || now &- lastReport >= 50_000_000
            if shouldReport { lastReport = now }
            lock.unlock()
            if shouldReport { callback(currentDone, total) }
        }
    }
}
