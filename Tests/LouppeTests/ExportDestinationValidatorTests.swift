import XCTest
@testable import Louppe

final class ExportDestinationValidatorTests: XCTestCase {
    func testZeroImportantUsageCapacityFallsBackToFileSystemCapacity() {
        XCTAssertEqual(
            ExportDestinationValidator.effectiveAvailableCapacity(
                importantUsage: 0,
                fileSystem: 24_000_000_000
            ),
            24_000_000_000
        )
        XCTAssertNil(
            ExportDestinationValidator.effectiveAvailableCapacity(
                importantUsage: 0,
                fileSystem: nil
            ),
            "an ambiguous zero must not be reported as a full disk"
        )
        XCTAssertEqual(
            ExportDestinationValidator.effectiveAvailableCapacity(
                importantUsage: 0,
                fileSystem: 0
            ),
            0,
            "statfs zero is an independent confirmation that the disk is full"
        )
        XCTAssertEqual(
            ExportDestinationValidator.effectiveAvailableCapacity(
                importantUsage: 30_000_000_000,
                fileSystem: 10_000_000_000
            ),
            30_000_000_000,
            "positive important-usage capacity includes space macOS can reclaim"
        )
    }

    func testMoveRequiresEveryPhysicalFileOnOneKnownDestinationVolume() {
        let volumeA = AnyHashable("volume-a")
        let volumeB = AnyHashable("volume-b")

        XCTAssertTrue(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [volumeA, volumeA],
                destination: volumeA
            )
        )
        XCTAssertFalse(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [volumeA, volumeB],
                destination: volumeA
            )
        )
        XCTAssertFalse(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [volumeA, nil],
                destination: volumeA
            )
        )
        XCTAssertFalse(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [volumeA],
                destination: nil
            )
        )
        XCTAssertFalse(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [],
                destination: volumeA
            )
        )
    }
}
