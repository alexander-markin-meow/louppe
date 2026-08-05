import Darwin
import Foundation
import XCTest
@testable import Louppe

final class XMPPhase5Tests: XCTestCase {
    private enum TestFailure: Error {
        case injectedWriteFailure
    }

    private let validFixtures = [
        "universal-unknown.xmp",
        "lightroom-classic.xmp",
        "adobe-bridge.xmp",
        "capture-one.xmp",
        "darktable.xmp",
    ]

    func testProductionXMPCoreRuntimeInitializes() {
        XCTAssertTrue(XMPFieldMapping.runtimeIsAvailable)
    }

    func testAllProfilesSerializeTypedOwnedFields() throws {
        for profile in XMPApplicationProfile.allCases {
            for color in PhotoColorLabel.allCases {
                let metadata = XMPPublicationMetadata(
                    decision: .yes,
                    stars: .five,
                    colorLabel: color,
                    profile: profile
                )
                let packet = try XMPFieldMapping.merge(
                    packet: nil,
                    metadata: metadata
                )
                try XMPFieldMapping.verify(packet: packet, metadata: metadata)
                XCTAssertEqual(
                    try property(
                        XMPFieldMapping.xmpNamespace,
                        "Rating",
                        in: packet
                    ),
                    "5"
                )
                XCTAssertEqual(
                    try property(
                        XMPFieldMapping.xmpNamespace,
                        "Label",
                        in: packet
                    ),
                    color.displayName
                )
                XCTAssertEqual(
                    try property(
                        XMPFieldMapping.louppeNamespace,
                        "Decision",
                        in: packet
                    ),
                    "yes"
                )
            }
        }
    }

    func testLightroomPickGoodMappingForEveryDecision() throws {
        let expectations: [(Rating, String, String?)] = [
            (.yes, "1", "True"),
            (.no, "-1", "False"),
            (.undecided, "0", nil),
        ]
        for (decision, pick, good) in expectations {
            let metadata = XMPPublicationMetadata(
                decision: decision,
                stars: .three,
                colorLabel: .blue,
                profile: .lightroomClassic
            )
            let packet = try XMPFieldMapping.merge(
                packet: nil,
                metadata: metadata
            )
            XCTAssertEqual(
                try property(
                    XMPFieldMapping.dynamicMediaNamespace,
                    "pick",
                    in: packet
                ),
                pick
            )
            if let good {
                XCTAssertEqual(
                    try property(
                        XMPFieldMapping.dynamicMediaNamespace,
                        "good",
                        in: packet
                    ),
                    good
                )
            } else {
                XCTAssertThrowsError(
                    try property(
                        XMPFieldMapping.dynamicMediaNamespace,
                        "good",
                        in: packet
                    )
                )
            }
        }
    }

    func testForeignFieldsAndApplicationEditsSurviveEveryFixture() throws {
        let sentinels: [String: [(String, String, String)]] = [
            "universal-unknown.xmp": [
                (
                    "https://example.invalid/xmp/foreign/1.0/",
                    "Untouched",
                    "Unknown namespace sentinel"
                ),
                (
                    XMPFieldMapping.dcNamespace,
                    "subject[1]",
                    "Existing universal keyword"
                ),
            ],
            "lightroom-classic.xmp": [
                (
                    "http://ns.adobe.com/camera-raw-settings/1.0/",
                    "Exposure2012",
                    "Lightroom edit sentinel 0.75"
                ),
            ],
            "adobe-bridge.xmp": [
                (
                    "http://ns.adobe.com/photoshop/1.0/",
                    "Urgency",
                    "4"
                ),
            ],
            "capture-one.xmp": [
                (
                    "http://ns.phaseone.com/captureone/1.0/",
                    "Untouched",
                    "Capture One custom sentinel"
                ),
            ],
            "darktable.xmp": [
                (
                    "http://darktable.sf.net/",
                    "history[1]/darktable:operation",
                    "darktable history sentinel"
                ),
                (
                    "http://darktable.sf.net/",
                    "history[1]/darktable:blendop_params",
                    "darktable blend sentinel"
                ),
            ],
        ]

        for name in validFixtures {
            let original = try fixture(name)
            let metadata = XMPPublicationMetadata(
                decision: .no,
                stars: .four,
                colorLabel: .purple,
                profile: profile(for: name),
                allowExternalLabelRemoval: name == "universal-unknown.xmp"
            )
            let merged = try XMPFieldMapping.merge(
                packet: original,
                metadata: metadata
            )
            try XMPFieldMapping.verify(packet: merged, metadata: metadata)
            for (namespace, path, expected) in sentinels[name] ?? [] {
                XCTAssertEqual(
                    try property(namespace, path, in: merged),
                    expected,
                    "\(name) lost \(path)"
                )
            }
            if name == "universal-unknown.xmp" {
                let text = try XCTUnwrap(String(data: merged, encoding: .utf8))
                XCTAssertTrue(text.contains("<?xpacket end=\"w\"?>"))
                XCTAssertGreaterThanOrEqual(
                    text.split(whereSeparator: { $0 != " " })
                        .map(\.count)
                        .max() ?? 0,
                    100
                )
            }
        }
    }

    func testReservedKeywordsReplaceOnlyLouppeEntries() throws {
        let original = try fixture("capture-one.xmp")
        let no = XMPPublicationMetadata(
            decision: .no,
            stars: nil,
            colorLabel: .red,
            profile: .captureOne
        )
        let noPacket = try XMPFieldMapping.merge(packet: original, metadata: no)
        XCTAssertTrue(
            try arrayValues(
                namespace: XMPFieldMapping.dcNamespace,
                path: "subject",
                packet: noPacket
            ).contains("Existing Capture One Keyword")
        )
        XCTAssertTrue(
            try arrayValues(
                namespace: XMPFieldMapping.dcNamespace,
                path: "subject",
                packet: noPacket
            ).contains(XMPFieldMapping.flatNoKeyword)
        )

        let yes = XMPPublicationMetadata(
            decision: .yes,
            stars: nil,
            colorLabel: .red,
            profile: .captureOne
        )
        let yesPacket = try XMPFieldMapping.merge(packet: noPacket, metadata: yes)
        let flat = try arrayValues(
            namespace: XMPFieldMapping.dcNamespace,
            path: "subject",
            packet: yesPacket
        )
        let hierarchical = try arrayValues(
            namespace: XMPFieldMapping.lightroomNamespace,
            path: "hierarchicalSubject",
            packet: yesPacket
        )
        XCTAssertTrue(flat.contains("Existing Capture One Keyword"))
        XCTAssertTrue(flat.contains(XMPFieldMapping.flatYesKeyword))
        XCTAssertFalse(flat.contains(XMPFieldMapping.flatNoKeyword))
        XCTAssertTrue(hierarchical.contains("Places|Coast|Møns Klint"))
        XCTAssertTrue(
            hierarchical.contains(XMPFieldMapping.hierarchicalYesKeyword)
        )
        XCTAssertFalse(
            hierarchical.contains(XMPFieldMapping.hierarchicalNoKeyword)
        )
    }

    func testExternalCustomLabelCannotBeSilentlyErasedOrReplaced() throws {
        let original = try fixture("universal-unknown.xmp")
        let metadata = XMPPublicationMetadata(
            decision: .yes,
            stars: nil,
            colorLabel: nil,
            profile: .universal
        )
        XCTAssertThrowsError(
            try XMPFieldMapping.merge(packet: original, metadata: metadata)
        ) { error in
            guard case XMPFieldMappingError.ownershipConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("Client Violet"))
        }

        let replacement = XMPPublicationMetadata(
            decision: .yes,
            stars: nil,
            colorLabel: .red,
            profile: .universal
        )
        XCTAssertThrowsError(
            try XMPFieldMapping.merge(packet: original, metadata: replacement)
        )

        let confirmed = XMPPublicationMetadata(
            decision: .yes,
            stars: nil,
            colorLabel: nil,
            profile: .universal,
            allowExternalLabelRemoval: true
        )
        let merged = try XMPFieldMapping.merge(
            packet: original,
            metadata: confirmed
        )
        XCTAssertThrowsError(
            try property(
                XMPFieldMapping.xmpNamespace,
                "Label",
                in: merged
            )
        )

        let confirmedReplacement = XMPPublicationMetadata(
            decision: .yes,
            stars: nil,
            colorLabel: .red,
            profile: .universal,
            allowExternalLabelRemoval: true
        )
        let replaced = try XMPFieldMapping.merge(
            packet: original,
            metadata: confirmedReplacement
        )
        XCTAssertEqual(
            try property(
                XMPFieldMapping.xmpNamespace,
                "Label",
                in: replaced
            ),
            "Red"
        )

        let packetWithMisleadingProvenance = String(
            data: original,
            encoding: .utf8
        )!
        .replacingOccurrences(
            of: "xmlns:foreign=",
            with: "xmlns:louppe=\"\(XMPFieldMapping.louppeNamespace)\" louppe:Decision=\"yes\" louppe:MetadataVersion=\"1\" xmlns:foreign="
        )
        XCTAssertThrowsError(
            try XMPFieldMapping.merge(
                packet: Data(packetWithMisleadingProvenance.utf8),
                metadata: metadata
            )
        ) { error in
            guard case XMPFieldMappingError.ownershipConflict = error else {
                return XCTFail("Custom label was trusted from broad provenance: \(error)")
            }
        }
    }

    func testMalformedPacketIsRejectedWithoutModification() async throws {
        let folder = try temporaryDirectory()
        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        let original = try fixture("malformed.xmp")
        try original.write(to: sidecar)
        let store = XMPMetadataStore()
        let metadata = sampleMetadata()
        do {
            _ = try await store.prepareWrite(
                path: XMPExactFileSystemPath(url: sidecar),
                metadata: metadata
            )
            XCTFail("Malformed XMP was accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
    }

    func testEmptyExistingPacketIsMalformedNotTreatedAsANewSidecar() async throws {
        let folder = try temporaryDirectory()
        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: sidecar.path,
            contents: Data()
        ))
        do {
            _ = try await XMPMetadataStore().prepareWrite(
                path: XMPExactFileSystemPath(url: sidecar),
                metadata: sampleMetadata()
            )
            XCTFail("An empty existing packet was treated as a new sidecar")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: sidecar), Data())
    }

    func testOversizedPacketIsRejectedWithoutReadingOrModification() async throws {
        let folder = try temporaryDirectory()
        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        XCTAssertTrue(FileManager.default.createFile(atPath: sidecar.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sidecar)
        try handle.truncate(atOffset: UInt64(XMPFieldMapping.maximumPacketBytes + 1))
        try handle.close()
        let before = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.size] as? NSNumber

        do {
            _ = try await XMPMetadataStore().prepareWrite(
                path: XMPExactFileSystemPath(url: sidecar),
                metadata: sampleMetadata()
            )
            XCTFail("Oversized XMP was accepted")
        } catch {}
        let after = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.size] as? NSNumber
        XCTAssertEqual(before, after)
    }

    func testAtomicCreateAndUpdateNeverTouchTheOriginalMedia() async throws {
        let folder = try temporaryDirectory()
        let media = folder.appendingPathComponent("IMG_0001.NEF")
        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        let mediaBytes = Data("original raw bytes".utf8)
        try mediaBytes.write(to: media)
        let store = XMPMetadataStore()
        let path = try XMPExactFileSystemPath(url: sidecar)

        let create = try await store.prepareWrite(
            path: path,
            metadata: sampleMetadata()
        )
        XCTAssertEqual(create.action, .create)
        let createResult = try await store.commit(create)
        XCTAssertEqual(createResult.action, .create)
        XCTAssertEqual(try Data(contentsOf: media), mediaBytes)

        let changed = XMPPublicationMetadata(
            decision: .no,
            stars: .two,
            colorLabel: .yellow,
            profile: .bridge
        )
        let update = try await store.prepareWrite(path: path, metadata: changed)
        XCTAssertEqual(update.action, .update)
        let updateResult = try await store.commit(update)
        XCTAssertEqual(updateResult.action, .update)
        XCTAssertEqual(try Data(contentsOf: media), mediaBytes)
        try XMPFieldMapping.verify(
            packet: Data(contentsOf: sidecar),
            metadata: changed
        )

        let current = try await store.prepareWrite(path: path, metadata: changed)
        XCTAssertEqual(current.action, .alreadyCurrent)
    }

    func testCASConflictPreservesExternalEdit() async throws {
        let folder = try temporaryDirectory()
        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        let initial = try XMPFieldMapping.merge(
            packet: nil,
            metadata: sampleMetadata()
        )
        try initial.write(to: sidecar)
        let store = XMPMetadataStore()
        let changed = XMPPublicationMetadata(
            decision: .no,
            stars: .one,
            colorLabel: .green,
            profile: .bridge
        )
        let prepared = try await store.prepareWrite(
            path: XMPExactFileSystemPath(url: sidecar),
            metadata: changed
        )
        let external = Data("external application edit".utf8)
        do {
            _ = try await store.commit(
                prepared,
                testHooks: XMPMetadataStoreTestHooks(
                    beforeFinalValidation: { try external.write(to: sidecar) }
                )
            )
            XCTFail("CAS conflict was not detected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: sidecar), external)
    }

    func testLateCreateCollisionNeverOverwritesTheOtherApplicationPacket() async throws {
        let folder = try temporaryDirectory()
        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        let store = XMPMetadataStore()
        let prepared = try await store.prepareWrite(
            path: XMPExactFileSystemPath(url: sidecar),
            metadata: sampleMetadata()
        )
        XCTAssertEqual(prepared.action, .create)
        let external = Data("created after Louppe preflight".utf8)
        do {
            _ = try await store.commit(
                prepared,
                testHooks: XMPMetadataStoreTestHooks(
                    beforeFinalValidation: { try external.write(to: sidecar) }
                )
            )
            XCTFail("Late create collision was not detected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: sidecar), external)
    }

    func testAtomicFailureLeavesExistingPacketUnchanged() async throws {
        let folder = try temporaryDirectory()
        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        let initial = try XMPFieldMapping.merge(
            packet: nil,
            metadata: sampleMetadata()
        )
        try initial.write(to: sidecar)
        let store = XMPMetadataStore()
        let changed = XMPPublicationMetadata(
            decision: .no,
            stars: .five,
            colorLabel: .purple,
            profile: .darktable
        )
        let prepared = try await store.prepareWrite(
            path: XMPExactFileSystemPath(url: sidecar),
            metadata: changed
        )
        do {
            _ = try await store.commit(
                prepared,
                testHooks: XMPMetadataStoreTestHooks(
                    beforeFinalValidation: { throw TestFailure.injectedWriteFailure }
                )
            )
            XCTFail("Injected failure did not abort")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: sidecar), initial)
    }

    func testSymlinkDirectoryAndFIFOAreRejected() async throws {
        let folder = try temporaryDirectory()
        let target = folder.appendingPathComponent("target.xmp")
        let targetBytes = try XMPFieldMapping.merge(
            packet: nil,
            metadata: sampleMetadata()
        )
        try targetBytes.write(to: target)
        let symlink = folder.appendingPathComponent("link.xmp")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: target
        )
        let directory = folder.appendingPathComponent("folder.xmp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fifo = folder.appendingPathComponent("pipe.xmp")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let store = XMPMetadataStore()
        for unsafe in [symlink, directory, fifo] {
            do {
                _ = try await store.prepareWrite(
                    path: XMPExactFileSystemPath(url: unsafe),
                    metadata: sampleMetadata()
                )
                XCTFail("Unsafe file type accepted: \(unsafe.lastPathComponent)")
            } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }

    func testUnixSocketAndUnreadablePacketAreRejected() async throws {
        let folder = try shortTemporaryDirectory()
        let socketURL = folder.appendingPathComponent("service.xmp")
        let socketDescriptor = try makeUnixSocket(at: socketURL)
        defer { Darwin.close(socketDescriptor) }

        let unreadable = folder.appendingPathComponent("unreadable.xmp")
        try fixture("adobe-bridge.xmp").write(to: unreadable)
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        defer { _ = chmod(unreadable.path, 0o600) }

        let store = XMPMetadataStore()
        for unsafe in [socketURL, unreadable] {
            do {
                _ = try await store.prepareWrite(
                    path: XMPExactFileSystemPath(url: unsafe),
                    metadata: sampleMetadata()
                )
                XCTFail("Unsafe packet accepted: \(unsafe.lastPathComponent)")
            } catch {}
        }
    }

    func testIdentityReplacementIsDetectedWithoutOverwritingReplacement() async throws {
        let folder = try temporaryDirectory()
        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        let initial = try XMPFieldMapping.merge(
            packet: nil,
            metadata: sampleMetadata()
        )
        try initial.write(to: sidecar)
        let store = XMPMetadataStore()
        let changed = XMPPublicationMetadata(
            decision: .no,
            stars: .one,
            colorLabel: .red,
            profile: .captureOne
        )
        let prepared = try await store.prepareWrite(
            path: XMPExactFileSystemPath(url: sidecar),
            metadata: changed
        )
        let replacement = Data("same-name replacement".utf8)
        do {
            _ = try await store.commit(
                prepared,
                testHooks: XMPMetadataStoreTestHooks(
                    beforeFinalValidation: {
                        try FileManager.default.removeItem(at: sidecar)
                        try replacement.write(to: sidecar)
                    }
                )
            )
            XCTFail("Same-path identity replacement was not detected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: sidecar), replacement)
    }

    func testResolverSharesIdenticalStemAndRejectsDivergentMetadata() throws {
        let folder = try temporaryDirectory()
        let raw = folder.appendingPathComponent("IMG_0001.NEF")
        let jpeg = folder.appendingPathComponent("IMG_0001.JPG")
        let metadata = sampleMetadata()
        let identical = try XMPSidecarResolver.resolve(members: [
            XMPStemFamilyMember(mediaURL: raw, metadata: metadata),
            XMPStemFamilyMember(mediaURL: jpeg, metadata: metadata),
        ])
        XCTAssertEqual(identical.count, 1)
        XCTAssertEqual(identical[0].disposition, .publish)
        XCTAssertEqual(identical[0].canonicalSidecar?.url.lastPathComponent, "IMG_0001.xmp")

        let other = XMPPublicationMetadata(
            decision: .no,
            stars: .five,
            colorLabel: .red,
            profile: .bridge
        )
        let divergent = try XMPSidecarResolver.resolve(members: [
            XMPStemFamilyMember(mediaURL: raw, metadata: metadata),
            XMPStemFamilyMember(mediaURL: jpeg, metadata: other),
        ])
        XCTAssertEqual(divergent[0].disposition, .metadataConflict)
        XCTAssertNil(divergent[0].canonicalSidecar)
    }

    func testResolverPreservesExistingCaseAndExtensionQualifiedPacket() throws {
        let folder = try temporaryDirectory()
        let raw = folder.appendingPathComponent("IMG_0001.NEF")
        let canonical = folder.appendingPathComponent("IMG_0001.XMP")
        let application = folder.appendingPathComponent("IMG_0001.NEF.xmp")
        try Data("canonical".utf8).write(to: canonical)
        let applicationBytes = Data("darktable history".utf8)
        try applicationBytes.write(to: application)

        let plans = try XMPSidecarResolver.resolve(members: [
            XMPStemFamilyMember(mediaURL: raw, metadata: sampleMetadata()),
        ])
        XCTAssertEqual(plans[0].canonicalSidecar?.bytes, try XMPExactFileSystemPath(url: canonical).bytes)
        XCTAssertEqual(plans[0].extensionQualifiedSidecars, [
            try XMPExactFileSystemPath(url: application),
        ])
        XCTAssertEqual(try Data(contentsOf: application), applicationBytes)
    }

    func testResolverDetectsCaseAndUnicodeCollisions() throws {
        let folder = try temporaryDirectory()
        let upper = folder.appendingPathComponent("IMG_0001.NEF")
        let lower = folder.appendingPathComponent("img_0001.JPG")
        let upperMember = try XMPStemFamilyMember(
            mediaURL: upper,
            metadata: sampleMetadata()
        )
        let lowerMember = try XMPStemFamilyMember(
            mediaURL: lower,
            metadata: sampleMetadata()
        )
        let insensitive = try XMPSidecarResolver.resolve(
            members: [upperMember, lowerMember],
            directoryEntries: [],
            caseSensitiveNames: false
        )
        XCTAssertEqual(insensitive.count, 1)
        XCTAssertEqual(insensitive[0].disposition, .filenameCollision)

        let sensitive = try XMPSidecarResolver.resolve(
            members: [upperMember, lowerMember],
            directoryEntries: [],
            caseSensitiveNames: true
        )
        XCTAssertEqual(sensitive.count, 2)
        XCTAssertTrue(sensitive.allSatisfy { $0.disposition == .publish })

        let folderPath = try XMPExactFileSystemPath(url: folder)
        let composed = try folderPath.appending(
            componentBytes: Data("Café.NEF".utf8)
        )
        let decomposed = try folderPath.appending(
            componentBytes: Data("Cafe\u{301}.JPG".utf8)
        )
        let unicode = try XMPSidecarResolver.resolve(
            members: [
                XMPStemFamilyMember(mediaPath: composed, metadata: sampleMetadata()),
                XMPStemFamilyMember(mediaPath: decomposed, metadata: sampleMetadata()),
            ],
            directoryEntries: [],
            caseSensitiveNames: true
        )
        XCTAssertEqual(unicode.count, 1)
        XCTAssertEqual(unicode[0].disposition, .filenameCollision)

        let lowerSidecar = try folderPath.appending(
            componentBytes: Data("IMG_0001.xmp".utf8)
        )
        let upperSidecar = try folderPath.appending(
            componentBytes: Data("IMG_0001.XMP".utf8)
        )
        let duplicatePackets = try XMPSidecarResolver.resolve(
            members: [upperMember],
            directoryEntries: [lowerSidecar, upperSidecar],
            caseSensitiveNames: true
        )
        XCTAssertEqual(duplicatePackets[0].disposition, .filenameCollision)
    }

    private func sampleMetadata() -> XMPPublicationMetadata {
        XMPPublicationMetadata(
            decision: .yes,
            stars: .four,
            colorLabel: .blue,
            profile: .bridge
        )
    }

    private func profile(for fixture: String) -> XMPApplicationProfile {
        switch fixture {
        case "lightroom-classic.xmp": return .lightroomClassic
        case "adobe-bridge.xmp": return .bridge
        case "capture-one.xmp": return .captureOne
        case "darktable.xmp": return .darktable
        default: return .universal
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = tests.deletingLastPathComponent().deletingLastPathComponent()
        return try Data(
            contentsOf: repository
                .appendingPathComponent("Prototypes/XMPBridgeProof/Fixtures")
                .appendingPathComponent(name)
        )
    }

    private func property(
        _ namespace: String,
        _ path: String,
        in packet: Data
    ) throws -> String {
        try XMPFieldMapping.readProperty(
            namespace: namespace,
            path: path,
            packet: packet
        )
    }

    private func arrayValues(
        namespace: String,
        path: String,
        packet: Data
    ) throws -> [String] {
        var values: [String] = []
        for index in 1...1_000 {
            do {
                values.append(
                    try property(namespace, "\(path)[\(index)]", in: packet)
                )
            } catch XMPFieldMappingError.propertyMissing {
                break
            }
        }
        return values
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "louppe-xmp-phase5-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func shortTemporaryDirectory() throws -> URL {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        let url = URL(
            fileURLWithPath: "/private/tmp/lxmp-\(suffix)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeUnixSocket(at url: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = url.withUnsafeFileSystemRepresentation { source -> Bool in
            guard let source else { return false }
            let length = strlen(source)
            return withUnsafeMutableBytes(of: &address.sun_path) { destination in
                guard length < destination.count else { return false }
                destination.initializeMemory(as: UInt8.self, repeating: 0)
                destination.copyBytes(from: UnsafeRawBufferPointer(
                    start: source,
                    count: length
                ))
                return true
            }
        }
        guard copied else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        return descriptor
    }
}
