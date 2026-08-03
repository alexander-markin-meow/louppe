import Foundation
import XCTest
@testable import Louppe

final class MediaNumericSafetyTests: XCTestCase {
    func testDurationFormattingRejectsInvalidAndUnrepresentableValues() {
        let invalid: [TimeInterval] = [
            .nan,
            .infinity,
            -.infinity,
            -1,
            Double(Int.max),
            .greatestFiniteMagnitude,
        ]

        for value in invalid {
            XCTAssertEqual(MediaDurationFormat.display(value), "--:--")
            XCTAssertEqual(
                MediaDurationFormat.accessibility(value),
                "Unknown duration"
            )
            XCTAssertNil(VideoMetadataExtractor.sanitizedDuration(value))
        }
    }

    func testOrdinaryDurationFormattingIsUnchanged() {
        XCTAssertEqual(MediaDurationFormat.display(nil), "--:--")
        XCTAssertEqual(MediaDurationFormat.display(0), "0:00")
        XCTAssertEqual(MediaDurationFormat.display(65.4), "1:05")
        XCTAssertEqual(MediaDurationFormat.display(3_661), "1:01:01")
        XCTAssertEqual(
            MediaDurationFormat.accessibility(3_661),
            "1 hour, 1 minute, 1 second"
        )
        XCTAssertEqual(
            VideoMetadataExtractor.sanitizedDuration(65.4),
            65.4
        )
    }

    func testVideoDimensionBoundaryRejectsExtremeValues() {
        let invalid: [(CGFloat, CGFloat)] = [
            (.nan, 1080),
            (.infinity, 1080),
            (CGFloat(Double(Int.max)), 1080),
            (.greatestFiniteMagnitude, 1080),
            (0, 1080),
            (-1, 1080),
            (.leastNonzeroMagnitude, 1080),
        ]

        for (width, height) in invalid {
            XCTAssertNil(
                VideoMetadataExtractor.sanitizedDimensions(
                    width: width,
                    height: height
                )
            )
        }

        XCTAssertEqual(
            VideoMetadataExtractor.sanitizedDimensions(
                width: 1920,
                height: 1080
            ),
            CGSize(width: 1920, height: 1080)
        )
    }

    func testVideoFieldsOmitExtremeDimensionsWithoutTrapping() {
        let malformed = videoItem(
            duration: Double(Int.max),
            dimensions: CGSize(width: CGFloat.infinity, height: 1080)
        )
        let malformedFields = MetadataExtractor.fields(for: malformed)

        XCTAssertEqual(
            malformedFields.first { $0.label == "Duration" }?.value,
            "--:--"
        )
        XCTAssertNil(
            malformedFields.first { $0.label == "Dimensions" }
        )

        let ordinary = videoItem(
            duration: 65.4,
            dimensions: CGSize(width: 1920.4, height: 1080.4)
        )
        let ordinaryFields = MetadataExtractor.fields(for: ordinary)
        XCTAssertEqual(
            ordinaryFields.first { $0.label == "Duration" }?.value,
            "1:05"
        )
        XCTAssertEqual(
            ordinaryFields.first { $0.label == "Dimensions" }?.value,
            "1920 × 1080"
        )
    }

    func testShutterFormattingRejectsUnsafeValues() {
        let invalid: [Double] = [
            .nan,
            .infinity,
            -.infinity,
            0,
            -1,
            .leastNonzeroMagnitude,
            1 / Double(Int.max),
            Double(Int.max),
        ]

        for value in invalid {
            XCTAssertNil(MediaNumeric.shutterSpeed(value))
            XCTAssertEqual(MetadataFormat.shutter(value), "")
            XCTAssertEqual(MetadataExtractor.formatShutter(value), "—")
        }
    }

    func testOrdinaryShutterFormattingIsUnchanged() {
        XCTAssertEqual(MetadataFormat.shutter(1.0 / 250), "1/250")
        XCTAssertEqual(MetadataFormat.shutter(0.3), "0.3s")
        XCTAssertEqual(MetadataFormat.shutter(1), "1s")
        XCTAssertEqual(MetadataExtractor.formatShutter(1.0 / 250), "1/250s")
        XCTAssertEqual(MetadataExtractor.formatShutter(0.3), "1/3s")
        XCTAssertEqual(MetadataExtractor.formatShutter(1), "1.0s")
    }

    func testEXIFNumericBoundaryRejectsNonfiniteValues() {
        XCTAssertNil(
            MetadataExtractor.finiteNumericValue(
                NSNumber(value: Double.nan)
            )
        )
        XCTAssertNil(
            MetadataExtractor.finiteNumericValue(
                NSNumber(value: Double.infinity)
            )
        )
        XCTAssertNil(MetadataExtractor.finiteNumericValue("nan"))
        XCTAssertEqual(MetadataExtractor.finiteNumericValue("2.8"), 2.8)
    }

    func testFiniteButNonsensicalMetadataIsRejectedByField() {
        XCTAssertNil(MediaNumeric.aperture(.leastNonzeroMagnitude))
        XCTAssertNil(MediaNumeric.aperture(10_000))
        XCTAssertEqual(MediaNumeric.aperture(2.8), 2.8)

        XCTAssertNil(MediaNumeric.iso(.leastNonzeroMagnitude))
        XCTAssertNil(MediaNumeric.iso(1_000_000_000))
        XCTAssertEqual(MediaNumeric.iso(800), 800)

        XCTAssertNil(MediaNumeric.focalLength(.leastNonzeroMagnitude))
        XCTAssertNil(MediaNumeric.focalLength(1_000_000))
        XCTAssertEqual(MediaNumeric.focalLength(85), 85)

        XCTAssertNil(MediaNumeric.frameRate(.leastNonzeroMagnitude))
        XCTAssertNil(MediaNumeric.frameRate(10_000_000))
        XCTAssertEqual(MediaNumeric.frameRate(23.976), 23.976)

        XCTAssertNil(MediaNumeric.exposureCompensation(-1_000))
        XCTAssertNil(MediaNumeric.exposureCompensation(1_000))
        XCTAssertEqual(MediaNumeric.exposureCompensation(-2), -2)

        XCTAssertNil(MediaNumeric.latitude(.nan))
        XCTAssertNil(MediaNumeric.latitude(90.1))
        XCTAssertEqual(MediaNumeric.latitude(-90), -90)
        XCTAssertNil(MediaNumeric.longitude(.infinity))
        XCTAssertNil(MediaNumeric.longitude(-180.1))
        XCTAssertEqual(MediaNumeric.longitude(180), 180)
    }

    func testVideoFieldsOmitFiniteButNonsensicalFrameRate() {
        let malformed = videoItem(
            duration: 1,
            dimensions: nil,
            frameRate: 10_000_000
        )
        XCTAssertNil(
            MetadataExtractor.fields(for: malformed)
                .first { $0.label == "Frame rate" }
        )
    }

    func testDurationGroupingRejectsUnrepresentableBucket() {
        let item = videoItem(
            duration: Double(Int.max),
            dimensions: nil
        )
        XCTAssertEqual(
            PhotoSort.Key.duration.groupID(for: item),
            PhotoGroup.ID(
                key: .duration,
                value: .roundedDuration(nil)
            )
        )
    }

    private func videoItem(
        duration: TimeInterval?,
        dimensions: CGSize?,
        frameRate: Double? = nil
    ) -> PhotoItem {
        PhotoItem(
            id: "VIDEO.MOV",
            primaryURL: URL(fileURLWithPath: "/tmp/VIDEO.MOV"),
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            mediaKind: .video,
            duration: duration,
            videoDimensions: dimensions,
            videoFrameRate: frameRate,
            videoIsPlayable: true,
            fileSize: 1
        )
    }
}
