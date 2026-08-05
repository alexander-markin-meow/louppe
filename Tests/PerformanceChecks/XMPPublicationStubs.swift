#if LOUPPE_TESTING
import Foundation

/// The dependency-free performance harness compiles SessionStore directly
/// instead of linking the Objective-C++ XMPCore target. These inert shapes
/// preserve SessionStore's production lifecycle API; performance coverage for
/// the real planner/worker lives in XCTest where the full package is linked.
enum XMPApplicationProfile: Sendable {
    case universal
}

struct XMPExactFileSystemPath: Hashable, Sendable {
    let url: URL

    init(url: URL) throws {
        self.url = url
    }
}

struct XMPExportApplicationPacket: Equatable, Sendable {
    let source: XMPExactFileSystemPath
    let ownerMediaPath: XMPExactFileSystemPath
    let identity: FileOperationJournal.FileIdentity
    let sourceDigest: Data
}

enum XMPPublicationCategory: Equatable, Sendable {
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

struct XMPExportPreparedFamily: Equatable, Sendable {
    let id: String
    let selectedMediaPaths: Set<XMPExactFileSystemPath>
    let allMediaPaths: Set<XMPExactFileSystemPath>
    let category: XMPPublicationCategory
    let canonicalSource: XMPExactFileSystemPath?
    let canonicalSourceIdentity: FileOperationJournal.FileIdentity?
    let canonicalSourceDigest: Data?
    let finalPacket: Data?
    let applicationPackets: [XMPExportApplicationPacket]

    var allFamilyMediaSelected: Bool {
        allMediaPaths.isSubset(of: selectedMediaPaths)
    }
}

struct XMPExportPreparedPlan: Equatable, Sendable {
    let families: [XMPExportPreparedFamily]

    var issueFamilies: [XMPExportPreparedFamily] {
        families.filter { !$0.category.canPublish }
    }

    var familyByMediaPath: [XMPExactFileSystemPath: XMPExportPreparedFamily] {
        var result: [XMPExactFileSystemPath: XMPExportPreparedFamily] = [:]
        for family in families {
            for path in family.selectedMediaPaths { result[path] = family }
        }
        return result
    }
}

struct XMPPublicationPlan: Equatable, Sendable {
    let id = UUID()
    let publishableCount = 0
}

struct XMPPublicationResult: Equatable, Sendable {
    let cancelled = false
}

struct XMPPublicationInput: Sendable {
    let members: [Int]
    let selectedPhysicalFileCount: Int
    let selectedMediaPaths: Set<Int>

    init(
        items: [PhotoItem],
        familyContextItems: [PhotoItem]? = nil,
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool = false
    ) throws {
        selectedPhysicalFileCount = items.reduce(0) {
            $0 + $1.individualFiles.count(where: { $0.mediaKind == .photo })
        }
        members = Array(0..<selectedPhysicalFileCount)
        selectedMediaPaths = Set(members)
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

    static func preflight(
        _ input: XMPPublicationInput,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping Progress
    ) async -> XMPPublicationPlan? {
        isCancelled() ? nil : XMPPublicationPlan()
    }
}

enum XMPPublicationWorker {
    typealias Progress = XMPPublicationPlanner.Progress

    static func publish(
        _ plan: XMPPublicationPlan,
        cancelFlag: XMPPublicationCancelFlag,
        progress: @escaping Progress
    ) async -> XMPPublicationResult {
        XMPPublicationResult()
    }
}
#endif
