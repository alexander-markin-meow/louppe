import CryptoKit
import Darwin
import Foundation

/// Sheet-local conditional default. A fresh value represents a newly opened
/// Export sheet; once the photographer changes it, later scope probes no
/// longer override that choice.
struct ExportXMPInclusionChoice: Equatable, Sendable {
    private(set) var isIncluded = false
    private(set) var wasManuallySet = false

    mutating func applyRecognizedPacketCount(_ count: Int) {
        guard !wasManuallySet else { return }
        isIncluded = count > 0
    }

    mutating func setManually(_ value: Bool) {
        isIncluded = value
        wasManuallySet = true
    }
}

struct XMPExportSourceInspection: Equatable, Sendable {
    let recognizedPacketCount: Int
    let excludedACRCompanionCount: Int
}

/// Value-semantic export snapshot captured before detached XMP preparation.
/// Rating changes after this point cannot silently alter the confirmed plan.
struct XMPExportPreparationInput: Sendable {
    let selectedItemCount: Int
    let selectedPhysicalFileCount: Int
    let selectedMediaPaths: Set<XMPExactFileSystemPath>
    let members: [XMPStemFamilyMember]

    init(
        selected: [PhotoItem],
        familyContextItems: [PhotoItem],
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool
    ) throws {
        selectedItemCount = selected.count
        let selectedFiles = selected.flatMap(\.individualFiles)
        selectedPhysicalFileCount = selectedFiles.count
        selectedMediaPaths = try Set(selectedFiles.map {
            try XMPExactFileSystemPath(url: $0.url)
        })
        members = try familyContextItems.flatMap { item in
            try item.individualFiles.map { file in
                try XMPStemFamilyMember(
                    mediaURL: file.url,
                    mediaKind: file.mediaKind,
                    metadata: XMPPublicationMetadata(
                        snapshot: file.metadataSnapshot,
                        profile: profile,
                        visibleDecisionKeywords: visibleDecisionKeywords,
                        allowExternalLabelRemoval:
                            allowExternalLabelReplacement
                    )
                )
            }
        }
    }
}

struct XMPExportApplicationPacket: Equatable, Sendable {
    let source: XMPExactFileSystemPath
    let ownerMediaPath: XMPExactFileSystemPath
    let identity: FileOperationJournal.FileIdentity
    let sourceDigest: Data
}

struct XMPExportPreparedFamily: Equatable, Sendable {
    let id: String
    let filenames: [String]
    let selectedMediaPaths: Set<XMPExactFileSystemPath>
    let allMediaPaths: Set<XMPExactFileSystemPath>
    let category: XMPPublicationCategory
    let message: String
    let changeCounts: XMPPublicationChangeCounts
    let bestEffortFilenames: [String]
    let excludedACRCompanionCount: Int
    let canonicalSourceWasPresent: Bool
    let recognizedApplicationPacketCount: Int
    let canonicalSource: XMPExactFileSystemPath?
    let canonicalSourceIdentity: FileOperationJournal.FileIdentity?
    let canonicalSourceDigest: Data?
    let finalPacket: Data?
    let applicationPackets: [XMPExportApplicationPacket]

    var allFamilyMediaSelected: Bool {
        allMediaPaths.isSubset(of: selectedMediaPaths)
    }

    var recognizedSourcePacketCount: Int {
        (canonicalSourceWasPresent ? 1 : 0)
            + recognizedApplicationPacketCount
    }
}

struct XMPExportPreparedPlan: Equatable, Sendable {
    let selectedItemCount: Int
    let physicalFileCount: Int
    let families: [XMPExportPreparedFamily]

    var existingRecognizedPacketCount: Int {
        families.reduce(0) { $0 + $1.recognizedSourcePacketCount }
    }

    var familyByMediaPath: [XMPExactFileSystemPath: XMPExportPreparedFamily] {
        var result: [XMPExactFileSystemPath: XMPExportPreparedFamily] = [:]
        for family in families {
            for path in family.selectedMediaPaths { result[path] = family }
        }
        return result
    }

    var changeCounts: XMPPublicationChangeCounts {
        families.reduce(XMPPublicationChangeCounts()) {
            $0 + $1.changeCounts
        }
    }

    var bestEffortFilenames: [String] {
        Array(Set(families.flatMap(\.bestEffortFilenames))).sorted()
    }

    var excludedACRCompanionCount: Int {
        families.reduce(0) { $0 + $1.excludedACRCompanionCount }
    }

    var applicationPacketCount: Int {
        families.reduce(0) { $0 + $1.applicationPackets.count }
    }

    var issueFamilies: [XMPExportPreparedFamily] {
        families.filter { !$0.category.canPublish }
    }

    func count(_ category: XMPPublicationCategory) -> Int {
        if category == .copyUnchangedApplicationPacket {
            return applicationPacketCount
        }
        return families.count(where: { $0.category == category })
    }
}

enum XMPExportPlanner {
    enum PlannerError: LocalizedError {
        case ambiguousApplicationPacket(String)

        var errorDescription: String? {
            switch self {
            case .ambiguousApplicationPacket(let name):
                return "Louppe could not associate \(name) with exactly one media file. Nothing was changed."
            }
        }
    }

    static func existingRecognizedPacketCount(
        selected: [PhotoItem],
        familyContextItems: [PhotoItem]
    ) throws -> Int {
        try inspectSources(
            selected: selected,
            familyContextItems: familyContextItems
        ).recognizedPacketCount
    }

    static func inspectSources(
        selected: [PhotoItem],
        familyContextItems: [PhotoItem]
    ) throws -> XMPExportSourceInspection {
        let selectedPaths = try Set(selected.flatMap(\.individualFiles).map {
            try XMPExactFileSystemPath(url: $0.url)
        })
        var recognizedPacketCount = 0
        var acrCompanions = Set<XMPExactFileSystemPath>()
        for family in try resolvedFamilies(
            contextItems: familyContextItems,
            profile: .universal,
            visibleDecisionKeywords: false,
            allowExternalLabelReplacement: false
        ) where family.members.contains(where: {
            selectedPaths.contains($0.mediaPath)
        }) {
            // Videos remain ordinary media exports, but the first XMP release
            // deliberately neither creates nor transfers video sidecars.
            guard family.disposition != .unsupportedMedia else { continue }
            if let canonical = family.canonicalSidecar,
               pathEntryExists(canonical) {
                recognizedPacketCount += 1
            }
            for packet in family.extensionQualifiedSidecars {
                guard let owner = try applicationPacketOwner(
                    packet,
                    members: family.members
                ), selectedPaths.contains(owner.mediaPath) else { continue }
                recognizedPacketCount += 1
            }
            for packet in family.excludedACRCompanions where try acrCompanion(
                packet,
                belongsToAny: selectedPaths,
                among: family.members
            ) {
                acrCompanions.insert(packet)
            }
        }
        return XMPExportSourceInspection(
            recognizedPacketCount: recognizedPacketCount,
            excludedACRCompanionCount: acrCompanions.count
        )
    }

    static func prepare(
        selected: [PhotoItem],
        familyContextItems: [PhotoItem],
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool
    ) async throws -> XMPExportPreparedPlan {
        try await prepare(XMPExportPreparationInput(
            selected: selected,
            familyContextItems: familyContextItems,
            profile: profile,
            visibleDecisionKeywords: visibleDecisionKeywords,
            allowExternalLabelReplacement: allowExternalLabelReplacement
        ))
    }

    static func prepare(
        _ input: XMPExportPreparationInput
    ) async throws -> XMPExportPreparedPlan {
        let selectedPaths = input.selectedMediaPaths
        let families = try resolvedFamilies(members: input.members).filter {
            family in
            family.members.contains { selectedPaths.contains($0.mediaPath) }
        }

        let store = XMPMetadataStore()
        var preparedFamilies: [XMPExportPreparedFamily] = []
        preparedFamilies.reserveCapacity(families.count)
        for family in families {
            try Task.checkCancellation()
            let names = family.members.map {
                $0.mediaPath.url.lastPathComponent
            }.sorted()
            let familySelectedPaths = Set(family.members.map(\.mediaPath))
                .intersection(selectedPaths)
            let allFamilyPaths = Set(family.members.map(\.mediaPath))
            let selectedMembers = family.members.filter {
                selectedPaths.contains($0.mediaPath)
            }
            let bestEffort = selectedMembers.compactMap { member in
                bestEffortExtensions.contains(
                    member.mediaPath.url.pathExtension.lowercased()
                ) ? member.mediaPath.url.lastPathComponent : nil
            }.sorted()
            let canonicalExists = family.canonicalSidecar.map(pathEntryExists)
                ?? false
            let selectedApplicationSidecars = try family
                .extensionQualifiedSidecars.filter { packet in
                    guard let owner = try applicationPacketOwner(
                        packet,
                        members: family.members
                    ) else { return false }
                    return selectedPaths.contains(owner.mediaPath)
                }
            let selectedACRCompanionCount = try family
                .excludedACRCompanions.count(where: {
                    try acrCompanion(
                        $0,
                        belongsToAny: selectedPaths,
                        among: family.members
                    )
                })
            let supportsSidecars = family.disposition != .unsupportedMedia
            let base = PreparedFamilyBase(
                id: familyID(family),
                filenames: names,
                selectedMediaPaths: familySelectedPaths,
                allMediaPaths: allFamilyPaths,
                bestEffortFilenames: bestEffort,
                excludedACRCompanionCount: selectedACRCompanionCount,
                canonicalSourceWasPresent:
                    supportsSidecars && canonicalExists,
                recognizedApplicationPacketCount:
                    supportsSidecars ? selectedApplicationSidecars.count : 0
            )
            let applicationPackets: [XMPExportApplicationPacket]
            do {
                applicationPackets = supportsSidecars
                    ? try selectedApplicationSidecars.compactMap {
                        packet -> XMPExportApplicationPacket? in
                        guard let owner = try applicationPacketOwner(
                            packet,
                            members: family.members
                        ) else { return nil }
                        return XMPExportApplicationPacket(
                            source: packet,
                            ownerMediaPath: owner.mediaPath,
                            identity: try FileOperationJournal.captureIdentity(
                                at: packet.url
                            ),
                            sourceDigest: try FileOperationJournal.contentDigest(
                                at: packet.url
                            )
                        )
                    }
                    : []
            } catch {
                preparedFamilies.append(base.family(
                    category: XMPPublicationPlanner.category(for: error),
                    message: error.localizedDescription
                ))
                continue
            }
            switch family.disposition {
            case .metadataConflict:
                preparedFamilies.append(base.family(
                    category: .sameStemMetadataConflict,
                    message: "Files sharing this stem have different Louppe metadata. Their shared XMP will be skipped.",
                    applicationPackets: applicationPackets
                ))
            case .filenameCollision:
                preparedFamilies.append(base.family(
                    category: .destinationCollision,
                    message: "More than one filesystem name resolves to this sidecar. Its shared XMP will be skipped.",
                    applicationPackets: applicationPackets
                ))
            case .unsupportedMedia:
                preparedFamilies.append(base.family(
                    category: .unsupportedMedia,
                    message: "Video media will export without XMP."
                ))
            case .publish:
                guard let canonical = family.canonicalSidecar,
                      let metadata = family.metadata else {
                    preparedFamilies.append(base.family(
                        category: .destinationCollision,
                        message: "Louppe could not determine one safe sidecar path. Its shared XMP will be skipped.",
                        applicationPackets: applicationPackets
                    ))
                    continue
                }
                do {
                    let prepared = try await store.prepareWrite(
                        path: canonical,
                        metadata: metadata
                    )
                    let sourceIdentity = prepared.action != .create
                        ? try FileOperationJournal.captureIdentity(at: canonical.url)
                        : nil
                    let sourceDigest = prepared.originalPacket.map {
                        Data(SHA256.hash(data: $0))
                    }
                    let category: XMPPublicationCategory
                    switch prepared.action {
                    case .create: category = .create
                    case .update: category = .update
                    case .alreadyCurrent: category = .alreadyCurrent
                    }
                    let changes = prepared.existingChangeSummary
                    preparedFamilies.append(base.family(
                        category: category,
                        message: category == .alreadyCurrent
                            ? "The destination packet will carry current Louppe metadata."
                            : "The destination packet is ready to \(category == .create ? "create" : "update").",
                        changeCounts: XMPPublicationChangeCounts(
                            stars: changes.stars ? 1 : 0,
                            colors: changes.color ? 1 : 0,
                            flags: changes.flag ? 1 : 0,
                            keywords: changes.keywords ? 1 : 0
                        ),
                        canonicalSource: prepared.action == .create
                            ? nil
                            : canonical,
                        canonicalSourceIdentity: sourceIdentity,
                        canonicalSourceDigest: sourceDigest,
                        finalPacket: prepared.finalPacket,
                        applicationPackets: applicationPackets
                    ))
                } catch {
                    preparedFamilies.append(base.family(
                        category: XMPPublicationPlanner.category(for: error),
                        message: error.localizedDescription,
                        applicationPackets: applicationPackets
                    ))
                }
            }
        }
        return XMPExportPreparedPlan(
            selectedItemCount: input.selectedItemCount,
            physicalFileCount: input.selectedPhysicalFileCount,
            families: preparedFamilies
        )
    }

    private struct PreparedFamilyBase {
        let id: String
        let filenames: [String]
        let selectedMediaPaths: Set<XMPExactFileSystemPath>
        let allMediaPaths: Set<XMPExactFileSystemPath>
        let bestEffortFilenames: [String]
        let excludedACRCompanionCount: Int
        let canonicalSourceWasPresent: Bool
        let recognizedApplicationPacketCount: Int

        func family(
            category: XMPPublicationCategory,
            message: String,
            changeCounts: XMPPublicationChangeCounts = .init(),
            canonicalSource: XMPExactFileSystemPath? = nil,
            canonicalSourceIdentity: FileOperationJournal.FileIdentity? = nil,
            canonicalSourceDigest: Data? = nil,
            finalPacket: Data? = nil,
            applicationPackets: [XMPExportApplicationPacket] = []
        ) -> XMPExportPreparedFamily {
            XMPExportPreparedFamily(
                id: id,
                filenames: filenames,
                selectedMediaPaths: selectedMediaPaths,
                allMediaPaths: allMediaPaths,
                category: category,
                message: message,
                changeCounts: changeCounts,
                bestEffortFilenames: bestEffortFilenames,
                excludedACRCompanionCount: excludedACRCompanionCount,
                canonicalSourceWasPresent: canonicalSourceWasPresent,
                recognizedApplicationPacketCount:
                    recognizedApplicationPacketCount,
                canonicalSource: canonicalSource,
                canonicalSourceIdentity: canonicalSourceIdentity,
                canonicalSourceDigest: canonicalSourceDigest,
                finalPacket: finalPacket,
                applicationPackets: applicationPackets
            )
        }
    }

    private static let bestEffortExtensions: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "dng", "heic", "heif", "png",
    ]

    private static func resolvedFamilies(
        contextItems: [PhotoItem],
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool
    ) throws -> [XMPSidecarFamilyPlan] {
        let members = try contextItems.flatMap { item in
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
        return try resolvedFamilies(members: members)
    }

    private static func resolvedFamilies(
        members: [XMPStemFamilyMember]
    ) throws -> [XMPSidecarFamilyPlan] {
        let grouped = Dictionary(grouping: members, by: { $0.mediaPath.parent })
        return try grouped.keys
            .sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
            .flatMap { try XMPSidecarResolver.resolve(members: grouped[$0] ?? []) }
    }

    private static func familyID(_ family: XMPSidecarFamilyPlan) -> String {
        family.members.first?.mediaPath.bytes.base64EncodedString()
            ?? UUID().uuidString
    }

    private static func applicationPacketOwner(
        _ packet: XMPExactFileSystemPath,
        members: [XMPStemFamilyMember]
    ) throws -> XMPStemFamilyMember? {
        guard packet.lastComponentBytes.count > 4 else {
            throw PlannerError.ambiguousApplicationPacket(
                packet.url.lastPathComponent
            )
        }
        let ownerBytes = Data(packet.lastComponentBytes.dropLast(4))
        let caseSensitive = try packet.parent.url.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames ?? true
        let matches = members.filter {
            namesEqual(
                $0.mediaPath.lastComponentBytes,
                ownerBytes,
                caseSensitive: caseSensitive
            )
        }
        guard matches.count <= 1 else {
            throw PlannerError.ambiguousApplicationPacket(
                packet.url.lastPathComponent
            )
        }
        return matches.first
    }

    private static func acrCompanion(
        _ packet: XMPExactFileSystemPath,
        belongsToAny selectedPaths: Set<XMPExactFileSystemPath>,
        among members: [XMPStemFamilyMember]
    ) throws -> Bool {
        guard packet.lastComponentBytes.count > 4 else { return false }
        let ownerBytes = Data(packet.lastComponentBytes.dropLast(4))
        let caseSensitive = try packet.parent.url.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames ?? true
        return members.contains { member in
            guard selectedPaths.contains(member.mediaPath) else { return false }
            return namesEqual(
                member.mediaPath.lastComponentBytes,
                ownerBytes,
                caseSensitive: caseSensitive
            ) || namesEqual(
                deletingFinalExtension(member.mediaPath.lastComponentBytes),
                ownerBytes,
                caseSensitive: caseSensitive
            )
        }
    }

    private static func namesEqual(
        _ lhs: Data,
        _ rhs: Data,
        caseSensitive: Bool
    ) -> Bool {
        guard let left = String(data: lhs, encoding: .utf8),
              let right = String(data: rhs, encoding: .utf8) else {
            return lhs == rhs
        }
        let normalizedLeft = left.precomposedStringWithCanonicalMapping
        let normalizedRight = right.precomposedStringWithCanonicalMapping
        return caseSensitive
            ? normalizedLeft == normalizedRight
            : normalizedLeft.lowercased() == normalizedRight.lowercased()
    }

    private static func deletingFinalExtension(_ filename: Data) -> Data {
        guard let dot = filename.lastIndex(of: UInt8(ascii: ".")),
              dot != filename.startIndex else { return filename }
        return filename[..<dot]
    }

    private static func pathEntryExists(
        _ path: XMPExactFileSystemPath
    ) -> Bool {
        var info = Darwin.stat()
        return path.withFileSystemRepresentation {
            Darwin.lstat($0, &info) == 0
        }
    }
}
