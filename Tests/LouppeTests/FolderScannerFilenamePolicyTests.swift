import Foundation
import XCTest
@testable import Louppe

final class FolderScannerFilenamePolicyTests: XCTestCase {
    func testAccentedAndUnaccentedNamesNeverPair() {
        let files = [
            mediaURL("cafe.NEF"),
            mediaURL("café.JPG"),
        ]

        for caseSensitiveNames in [true, false] {
            let pairs = FolderScanner.pairFiles(
                files,
                pairingMode: .together,
                filenamePolicy: .init(
                    caseSensitiveNames: caseSensitiveNames
                )
            )

            XCTAssertEqual(pairs.count, 2)
            XCTAssertTrue(pairs.allSatisfy { $0.paired == nil })
        }
    }

    func testCanonicallyEquivalentUnicodeSpellingsRemainSeparate() {
        let composedRAW = rawMediaURL("caf\u{00E9}.NEF")
        let decomposedJPEG = rawMediaURL("cafe\u{0301}.JPG")

        for caseSensitiveNames in [true, false] {
            let pairs = FolderScanner.pairFiles(
                [decomposedJPEG, composedRAW],
                pairingMode: .together,
                filenamePolicy: .init(
                    caseSensitiveNames: caseSensitiveNames
                )
            )

            XCTAssertEqual(pairs.count, 2)
            XCTAssertTrue(pairs.allSatisfy { $0.paired == nil })
        }
    }

    func testCaseOnlyNamesFollowExplicitVolumePolicy() throws {
        let raw = mediaURL("SHOT.NEF")
        let jpeg = mediaURL("shot.JPG")

        let sensitive = FolderScanner.pairFiles(
            [jpeg, raw],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: true)
        )
        XCTAssertEqual(sensitive.count, 2)
        XCTAssertTrue(sensitive.allSatisfy { $0.paired == nil })

        let insensitive = FolderScanner.pairFiles(
            [jpeg, raw],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: false)
        )
        let pair = try XCTUnwrap(insensitive.only)
        XCTAssertEqual(pair.primary.lastPathComponent, "SHOT.NEF")
        XCTAssertEqual(pair.paired?.lastPathComponent, "shot.JPG")
    }

    func testNonASCIICaseFoldingCannotMergeDistinctNames() {
        let pairs = FolderScanner.pairFiles(
            [mediaURL("straße.NEF"), mediaURL("STRASSE.JPG")],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: false)
        )

        XCTAssertEqual(pairs.count, 2)
        XCTAssertTrue(pairs.allSatisfy { $0.paired == nil })
    }

    func testPairingAcrossSubfoldersRequiresOneUnambiguousPair() throws {
        let root = URL(fileURLWithPath: "/Photos", isDirectory: true)
        let raw = root
            .appendingPathComponent("RAW", isDirectory: true)
            .appendingPathComponent("SHOT.NEF")
        let jpeg = root
            .appendingPathComponent("JPEG", isDirectory: true)
            .appendingPathComponent("shot.JPG")

        let pairs = FolderScanner.pairFiles(
            [raw, jpeg],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: false)
        )

        let pair = try XCTUnwrap(pairs.only)
        XCTAssertEqual(pair.primary, raw)
        XCTAssertEqual(pair.paired, jpeg)

        let duplicateJPEG = root
            .appendingPathComponent("Edited", isDirectory: true)
            .appendingPathComponent("SHOT.jpeg")
        let ambiguous = FolderScanner.pairFiles(
            [raw, jpeg, duplicateJPEG],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: false)
        )
        XCTAssertEqual(ambiguous.count, 3)
        XCTAssertTrue(ambiguous.allSatisfy { $0.paired == nil })
    }

    func testUnknownVolumeCapabilityDefaultsToCaseSensitive() {
        let policy = FolderScanner.PairingFilenamePolicy(
            volumeSupportsCaseSensitiveNames: nil
        )
        XCTAssertTrue(policy.caseSensitiveNames)

        let pairs = FolderScanner.pairFiles(
            [mediaURL("SHOT.NEF"), mediaURL("shot.JPG")],
            pairingMode: .together,
            filenamePolicy: policy
        )
        XCTAssertEqual(pairs.count, 2)
        XCTAssertTrue(pairs.allSatisfy { $0.paired == nil })
    }

    func testPairingOrderRemainsIndependentOfInputOrder() {
        let files = [
            mediaURL("zeta.JPG"),
            mediaURL("ALPHA.NEF"),
            mediaURL("alpha.JPG"),
            mediaURL("cafe.NEF"),
            mediaURL("café.JPG"),
        ]
        let policy = FolderScanner.PairingFilenamePolicy(
            caseSensitiveNames: false
        )

        let forward = FolderScanner.pairFiles(
            files,
            pairingMode: .together,
            filenamePolicy: policy
        )
        let reversed = FolderScanner.pairFiles(
            Array(files.reversed()),
            pairingMode: .together,
            filenamePolicy: policy
        )

        XCTAssertEqual(signature(forward), signature(reversed))
    }

    func testAmbiguousRawOrJPEGGroupsNeverPairArbitrarily() {
        let twoRAWs = FolderScanner.pairFiles(
            [
                mediaURL("SHOT.CR2"),
                mediaURL("SHOT.NEF"),
                mediaURL("SHOT.JPG"),
            ],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: true)
        )
        XCTAssertEqual(twoRAWs.count, 3)
        XCTAssertTrue(twoRAWs.allSatisfy { $0.paired == nil })

        let twoJPEGs = FolderScanner.pairFiles(
            [
                mediaURL("FRAME.NEF"),
                mediaURL("FRAME.JPG"),
                mediaURL("FRAME.JPEG"),
            ],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: true)
        )
        XCTAssertEqual(twoJPEGs.count, 3)
        XCTAssertTrue(twoJPEGs.allSatisfy { $0.paired == nil })
    }

    func testByteExactIdentitySurvivesProjectionAndRatingLookup() throws {
        let root = rawDirectoryURL("/Photos")
        let composedURL = rawMediaURL("caf\u{00E9}.NEF")
        let decomposedURL = rawMediaURL("cafe\u{0301}.NEF")
        let composedID = FolderScanner.relativeFileIdentity(
            of: composedURL,
            under: root
        )
        let decomposedID = FolderScanner.relativeFileIdentity(
            of: decomposedURL,
            under: root
        )
        XCTAssertNotEqual(composedID, decomposedID)

        let composed = PhotoItem(
            id: composedID,
            primaryURL: composedURL,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1,
            rating: .yes
        )
        let decomposed = PhotoItem(
            id: decomposedID,
            primaryURL: decomposedURL,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1,
            rating: .no
        )
        let projection = try FolderScanner.projectPairingMode(
            .separate,
            from: [composed, decomposed],
            root: root
        )
        XCTAssertEqual(projection.items.count, 2)
        XCTAssertEqual(Set(projection.items.map(\.id)).count, 2)
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: projection.items.map {
                    ($0.id, $0.rating)
                }
            ),
            [composedID: .yes, decomposedID: .no]
        )

        let persisted = SessionFile(
            version: 3,
            sourcePath: root.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: composedID,
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil
                ),
                SessionEntry(
                    filename: decomposedID,
                    pairedFilename: nil,
                    rating: Rating.no.rawValue,
                    ratedAt: nil
                ),
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let decoded = try JSONDecoder().decode(
            SessionFile.self,
            from: JSONEncoder().encode(persisted)
        )
        let ratings = SessionRatingIndex(session: decoded)
        XCTAssertEqual(
            ratings.value(for: projection.items[0].individualFiles[0])?.rating,
            projection.items[0].rating
        )
        XCTAssertEqual(
            ratings.value(for: projection.items[1].individualFiles[0])?.rating,
            projection.items[1].rating
        )
    }

    func testExactSidecarNeverFallsBackToCollidingLegacyAlias() {
        let exactID = "caf%25C3%25A9.NEF"
        let collidingLegacyID = "caf%C3%A9.NEF"
        let literalPercentFile = PhotoFile(
            id: exactID,
            url: mediaURL("caf%C3%A9.NEF"),
            displayRelativePath: collidingLegacyID,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
        let exactSession = SessionFile(
            version: 3,
            sourcePath: "/Photos",
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: collidingLegacyID,
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil
                ),
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )

        XCTAssertNil(
            SessionRatingIndex(session: exactSession)
                .value(for: literalPercentFile),
            "an exact sidecar entry for another file must not match a legacy decoded alias"
        )

        var legacySession = exactSession
        legacySession.fileIDEncoding = nil
        XCTAssertEqual(
            SessionRatingIndex(session: legacySession)
                .value(for: literalPercentFile)?.rating,
            .yes,
            "unmarked older sidecars should retain their one-way migration fallback"
        )
    }

    func testLegacySidecarAppliesByteDistinctUnicodeRatingsIndependently() {
        let composedName = "caf\u{00E9}.NEF"
        let decomposedName = "cafe\u{0301}.NEF"
        let composedFile = PhotoFile(
            id: "caf%C3%A9.NEF",
            url: mediaURL("composed.NEF"),
            displayRelativePath: composedName,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
        let decomposedFile = PhotoFile(
            id: "cafe%CC%81.NEF",
            url: mediaURL("decomposed.NEF"),
            displayRelativePath: decomposedName,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
        let legacySession = SessionFile(
            version: 2,
            sourcePath: "/Photos",
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: composedName,
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil
                ),
                SessionEntry(
                    filename: decomposedName,
                    pairedFilename: nil,
                    rating: Rating.no.rawValue,
                    ratedAt: nil
                ),
            ]
        )
        let ratings = SessionRatingIndex(session: legacySession)

        XCTAssertEqual(ratings.value(for: composedFile)?.rating, .yes)
        XCTAssertEqual(ratings.value(for: decomposedFile)?.rating, .no)
    }

    func testSchemaFourIdentityUsesVolumeUUIDAcrossRemountsAndIgnoresCTime() {
        let expected = fileIdentity(
            volumeRootPath: "/Volumes/CARD",
            volumeUUIDString: "card-uuid",
            systemNumber: 11,
            fileNumber: 42,
            statusChangeSeconds: 100
        )
        let remounted = fileIdentity(
            volumeRootPath: "/Volumes/CARD 1",
            volumeUUIDString: "card-uuid",
            systemNumber: 999,
            fileNumber: 42,
            statusChangeSeconds: 200
        )

        XCTAssertTrue(
            SessionRatingIndex.persistedIdentityMatches(
                expected: expected,
                actual: remounted
            ),
            "a stable volume UUID must supersede mount path, st_dev, and ctime"
        )
        XCTAssertTrue(
            FileOperationJournal.identitiesMatch(
                expected: expected,
                actual: remounted,
                includeStatusChange: false
            ),
            "recovery must keep recognizing the planned inode after a remount"
        )

        let changedContent = fileIdentity(
            volumeRootPath: "/Volumes/CARD 1",
            volumeUUIDString: "card-uuid",
            systemNumber: 999,
            fileNumber: 42,
            modificationSeconds: 101,
            statusChangeSeconds: 200
        )
        XCTAssertFalse(
            SessionRatingIndex.persistedIdentityMatches(
                expected: expected,
                actual: changedContent
            )
        )
        XCTAssertFalse(
            FileOperationJournal.identitiesMatch(
                expected: expected,
                actual: changedContent,
                includeStatusChange: false
            )
        )
    }

    func testSchemaFourLookupDistinguishesNewPathFromIdentityConflict() {
        let expected = fileIdentity(fileNumber: 41)
        let replacement = fileIdentity(fileNumber: 42)
        let session = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: "/Photos",
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.JPG",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil,
                    fileIdentity: expected
                )
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let index = SessionRatingIndex(session: session)
        let conflictingFile = PhotoFile(
            id: "A.JPG",
            url: mediaURL("A.JPG"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 12,
            scannedIdentity: replacement
        )
        let newFile = PhotoFile(
            id: "B.JPG",
            url: mediaURL("B.JPG"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 12,
            scannedIdentity: replacement
        )

        guard case .identityConflict = index.lookup(for: conflictingFile) else {
            return XCTFail("a same-path replacement must be reported as a conflict")
        }
        XCTAssertEqual(index.lookup(for: newFile), .absent)
    }

    func testScanRejectsReplacementAfterMetadataBeforeReturningItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LouppeScanIdentity-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("PHOTO.png")
        let original = try Data(
            contentsOf: URL(
                fileURLWithPath: "AppIcon/AppIcon.iconset/icon_16x16.png"
            )
        )
        try original.write(to: photo)
        let replacement = Data("replacement after metadata".utf8)

        XCTAssertThrowsError(
            try FolderScanner.scan(
                root,
                beforeFinalIdentityValidation: {
                    try FileManager.default.removeItem(at: photo)
                    try replacement.write(
                        to: photo,
                        options: .withoutOverwriting
                    )
                }
            ) { _ in }
        ) { error in
            XCTAssertTrue(error is FolderScanner.ScanError)
        }
        XCTAssertEqual(try Data(contentsOf: photo), replacement)
    }

    private func fileIdentity(
        volumeRootPath: String = "/Volumes/CARD",
        volumeUUIDString: String? = "card-uuid",
        systemNumber: UInt64 = 11,
        fileNumber: UInt64 = 42,
        modificationSeconds: Int64 = 100,
        statusChangeSeconds: Int64 = 100
    ) -> FileOperationJournal.FileIdentity {
        FileOperationJournal.FileIdentity(
            volumeRootPath: volumeRootPath,
            volumeUUIDString: volumeUUIDString,
            systemNumber: systemNumber,
            fileNumber: fileNumber,
            logicalSize: 12,
            modificationTime: .init(
                seconds: modificationSeconds,
                nanoseconds: 1
            ),
            statusChangeTime: .init(
                seconds: statusChangeSeconds,
                nanoseconds: 2
            ),
            birthTime: .init(seconds: 50, nanoseconds: 3)
        )
    }

    private func mediaURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/Photos", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func rawMediaURL(_ name: String) -> URL {
        let bytes = Array("/Photos/\(name)".utf8)
            .map(Int8.init(bitPattern:)) + [0]
        return bytes.withUnsafeBufferPointer { buffer in
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: false,
                relativeTo: nil
            )
        }
    }

    private func rawDirectoryURL(_ path: String) -> URL {
        let bytes = Array(path.utf8).map(Int8.init(bitPattern:)) + [0]
        return bytes.withUnsafeBufferPointer { buffer in
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: true,
                relativeTo: nil
            )
        }
    }

    private func signature(
        _ pairs: [(primary: URL, paired: URL?)]
    ) -> [String] {
        pairs.map {
            "\(FolderScanner.fileSystemIdentityPath(for: $0.primary))|\($0.paired.map(FolderScanner.fileSystemIdentityPath) ?? "unpaired")"
        }
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
