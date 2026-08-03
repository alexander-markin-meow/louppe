import Foundation
import XCTest
@testable import Louppe

final class DurableFileIOTests: XCTestCase {
    func testAtomicWriteReplacesFullyAndLeavesNoTemporaryFile() throws {
        let root = try makeTemporaryDirectory(named: "Replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("session.json")

        try DurableFileIO.atomicWrite(
            Data("first".utf8),
            to: destination,
            fullSync: true
        )
        let replacement = Data("second complete snapshot".utf8)
        try DurableFileIO.atomicWrite(
            replacement,
            to: destination,
            fullSync: true
        )

        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(contents.map(\.lastPathComponent), ["session.json"])
        let permissions = try FileManager.default.attributesOfItem(
            atPath: destination.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testFailedReplacePreservesTargetAndCleansTemporaryFile() throws {
        let root = try makeTemporaryDirectory(named: "FailureCleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(
            "existing-directory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try DurableFileIO.atomicWrite(
                Data("must not replace a directory".utf8),
                to: destination,
                fullSync: true
            )
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".louppe-write-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testLateValidationFailurePreservesExternallyChangedTarget() throws {
        let root = try makeTemporaryDirectory(named: "LateValidation")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("session.json")
        let external = Data("external edit".utf8)
        try Data("original".utf8).write(to: destination)

        XCTAssertThrowsError(
            try DurableFileIO.atomicWrite(
                Data("queued Louppe snapshot".utf8),
                to: destination,
                fullSync: true
            ) {
                try external.write(to: destination)
                throw CocoaError(.userCancelled)
            }
        )

        XCTAssertEqual(try Data(contentsOf: destination), external)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".louppe-write-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testBoundedReadRejectsOversizedFilesAndLeafSymlinks() throws {
        let root = try makeTemporaryDirectory(named: "BoundedRead")
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("record.json")
        let symlink = root.appendingPathComponent("redirected.json")
        let contents = Data("12345".utf8)
        try contents.write(to: regular)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: regular
        )

        XCTAssertEqual(
            try DurableFileIO.readRegularFile(
                at: regular,
                maximumBytes: contents.count
            ),
            contents
        )
        XCTAssertThrowsError(
            try DurableFileIO.readRegularFile(
                at: regular,
                maximumBytes: contents.count - 1
            )
        )
        XCTAssertThrowsError(
            try DurableFileIO.readRegularFile(
                at: symlink,
                maximumBytes: 1024
            )
        )
        XCTAssertEqual(try Data(contentsOf: regular), contents)
    }

    func testDirectorySyncRejectsLeafSymlink() throws {
        let root = try makeTemporaryDirectory(named: "DirectorySymlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("real", isDirectory: true)
        let symlink = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: directory
        )

        XCTAssertNoThrow(try DurableFileIO.syncDirectory(directory))
        XCTAssertThrowsError(try DurableFileIO.syncDirectory(symlink))
    }

    func testRegularFileUnlinkNeverRecursesOrFollowsSymlink() throws {
        let root = try makeTemporaryDirectory(named: "NonrecursiveUnlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("owned.partial")
        let directory = root.appendingPathComponent("replacement", isDirectory: true)
        let nested = directory.appendingPathComponent("irreplaceable.jpg")
        let symlink = root.appendingPathComponent("redirected.partial")
        try Data("owned copy".utf8).write(to: regular)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let nestedContents = Data("do not remove".utf8)
        try nestedContents.write(to: nested)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: nested
        )

        try DurableFileIO.unlinkRegularFile(at: regular)
        XCTAssertFalse(FileManager.default.fileExists(atPath: regular.path))
        XCTAssertThrowsError(try DurableFileIO.unlinkRegularFile(at: directory))
        XCTAssertThrowsError(try DurableFileIO.unlinkRegularFile(at: symlink))
        XCTAssertEqual(try Data(contentsOf: nested), nestedContents)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LouppeDurableFileIOTests-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
