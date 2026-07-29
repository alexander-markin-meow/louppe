import AppKit
import XCTest
@testable import Louppe

final class HistogramTests: XCTestCase {
    func testAnalysisUsesTheSharedNearBlackAndNearWhiteRanges() throws {
        let image = try makeImage([
            (0, 0, 0),
            (5, 5, 5),
            (128, 128, 128),
            (250, 250, 250),
            (255, 255, 255),
        ])
        let analysis = try XCTUnwrap(
            ClippingWarningProcessor.analyze(image)
        )

        XCTAssertEqual(analysis.sampleCount, 5)
        XCTAssertEqual(analysis.bins[0], 1)
        XCTAssertEqual(analysis.bins[5], 1)
        XCTAssertEqual(analysis.bins[128], 1)
        XCTAssertEqual(analysis.bins[250], 1)
        XCTAssertEqual(analysis.bins[255], 1)
        XCTAssertEqual(analysis.shadowCount, 2)
        XCTAssertEqual(analysis.highlightCount, 2)
        XCTAssertEqual(analysis.shadowPercentage, 40, accuracy: 0.001)
        XCTAssertEqual(analysis.highlightPercentage, 40, accuracy: 0.001)
    }

    func testOnlyValuesAboveTenPercentAreHigh() {
        XCTAssertFalse(HistogramAnalysis.isHighPercentage(9.999))
        XCTAssertFalse(HistogramAnalysis.isHighPercentage(10))
        XCTAssertTrue(HistogramAnalysis.isHighPercentage(10.001))
        XCTAssertTrue(HistogramAnalysis.isHighPercentage(61))
    }

    func testOverlayMarksWarningsRedAndLeavesMidtonesUntouched() throws {
        let image = try makeImage([
            (0, 0, 0),
            (128, 128, 128),
            (255, 255, 255),
        ])
        let warned = try XCTUnwrap(
            ClippingWarningProcessor.overlay(on: image)
        )
        let pixels = try pixels(in: warned)

        XCTAssertGreaterThan(pixels[0].0, 170)
        XCTAssertLessThan(pixels[0].1, 10)
        XCTAssertLessThan(pixels[0].2, 10)
        XCTAssertEqual(pixels[1].0, 128, accuracy: 1)
        XCTAssertEqual(pixels[1].1, 128, accuracy: 1)
        XCTAssertEqual(pixels[1].2, 128, accuracy: 1)
        XCTAssertGreaterThan(pixels[2].0, 250)
        XCTAssertLessThan(pixels[2].1, 90)
        XCTAssertLessThan(pixels[2].2, 90)
    }

    func testHistogramPipelineIgnoresVideosWithoutReadingThem() async {
        let video = PhotoItem(
            id: "MISSING.MOV",
            primaryURL: URL(fileURLWithPath: "/tmp/MISSING.MOV"),
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            mediaKind: .video,
            duration: 1,
            videoIsPlayable: true,
            fileSize: 1
        )

        let result = await HistogramPipeline.shared.analysis(for: video)
        XCTAssertNil(result)
    }

    private func makeImage(
        _ pixels: [(UInt8, UInt8, UInt8)]
    ) throws -> CGImage {
        let bytes = pixels.flatMap { [$0.0, $0.1, $0.2, UInt8(255)] }
        let provider = try XCTUnwrap(
            CGDataProvider(data: Data(bytes) as CFData)
        )
        return try XCTUnwrap(
            CGImage(
                width: pixels.count,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixels.count * 4,
                space: CGColorSpace(
                    name: CGColorSpace.sRGB
                ) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }

    private func pixels(
        in image: CGImage
    ) throws -> [(Int, Int, Int)] {
        var bytes = Array(
            repeating: UInt8(0),
            count: image.width * image.height * 4
        )
        let rendered = bytes.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let address = rawBytes.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpace(
                        name: CGColorSpace.sRGB
                    ) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:
                        CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: image.width,
                    height: image.height
                )
            )
            return true
        }
        XCTAssertTrue(rendered)
        return stride(from: 0, to: bytes.count, by: 4).map {
            (Int(bytes[$0]), Int(bytes[$0 + 1]), Int(bytes[$0 + 2]))
        }
    }
}
