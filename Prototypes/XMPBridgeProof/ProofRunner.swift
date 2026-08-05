import Foundation
import XMPBridge

private struct PropertyExpectation {
    let namespaceURI: String
    let path: String
    let value: String
    var preserveAfterMerge = true
}

private struct FixtureExpectation {
    let name: String
    let properties: [PropertyExpectation]
    let expectsWritablePacketPadding: Bool
}

private enum ProofFailure: Error, CustomStringConvertible {
    case usage
    case missingFixture(String)
    case bridge(String, String)
    case lostValue(String, String, String)
    case malformedAccepted
    case missingPadding(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: XMPBridgeProofRunner <fixture-directory>"
        case .missingFixture(let name):
            return "Missing fixture: \(name)"
        case .bridge(let name, let message):
            return "\(name): \(message)"
        case .lostValue(let name, let path, let value):
            return "\(name): \(path) changed or lost expected value '\(value)'"
        case .malformedAccepted:
            return "XMPCore unexpectedly accepted malformed.xmp"
        case .missingPadding(let name):
            return "\(name): serialized writable packet did not retain padding"
        }
    }
}

private let validFixtures = [
    FixtureExpectation(
        name: "universal-unknown.xmp",
        properties: [
            PropertyExpectation(
                namespaceURI: "https://example.invalid/xmp/foreign/1.0/",
                path: "Untouched",
                value: "Unknown namespace sentinel"
            ),
            PropertyExpectation(
                namespaceURI: "http://ns.adobe.com/xap/1.0/",
                path: "Label",
                value: "Client Violet",
                preserveAfterMerge: false
            ),
            PropertyExpectation(
                namespaceURI: "http://purl.org/dc/elements/1.1/",
                path: "subject[1]",
                value: "Existing universal keyword"
            ),
        ],
        expectsWritablePacketPadding: true
    ),
    FixtureExpectation(
        name: "lightroom-classic.xmp",
        properties: [
            PropertyExpectation(
                namespaceURI: "http://ns.adobe.com/camera-raw-settings/1.0/",
                path: "Exposure2012",
                value: "Lightroom edit sentinel 0.75"
            ),
            PropertyExpectation(
                namespaceURI: "http://purl.org/dc/elements/1.1/",
                path: "subject[1]",
                value: "Existing Lightroom Keyword"
            ),
            PropertyExpectation(
                namespaceURI: "http://ns.adobe.com/lightroom/1.0/",
                path: "hierarchicalSubject[1]",
                value: "Lightroom hierarchical sentinel"
            ),
        ],
        expectsWritablePacketPadding: false
    ),
    FixtureExpectation(
        name: "adobe-bridge.xmp",
        properties: [
            PropertyExpectation(
                namespaceURI: "http://ns.adobe.com/camera-raw-settings/1.0/",
                path: "Exposure2012",
                value: "Bridge Camera Raw sentinel -0.35"
            ),
            PropertyExpectation(
                namespaceURI: "http://purl.org/dc/elements/1.1/",
                path: "subject[1]",
                value: "Existing Bridge Keyword"
            ),
            PropertyExpectation(
                namespaceURI: "http://ns.adobe.com/photoshop/1.0/",
                path: "Urgency",
                value: "4"
            ),
        ],
        expectsWritablePacketPadding: false
    ),
    FixtureExpectation(
        name: "capture-one.xmp",
        properties: [
            PropertyExpectation(
                namespaceURI: "http://ns.phaseone.com/captureone/1.0/",
                path: "Untouched",
                value: "Capture One custom sentinel"
            ),
            PropertyExpectation(
                namespaceURI: "http://purl.org/dc/elements/1.1/",
                path: "subject[1]",
                value: "Existing Capture One Keyword"
            ),
            PropertyExpectation(
                namespaceURI: "http://ns.adobe.com/lightroom/1.0/",
                path: "hierarchicalSubject[1]",
                value: "Places|Coast|Møns Klint"
            ),
        ],
        expectsWritablePacketPadding: false
    ),
    FixtureExpectation(
        name: "darktable.xmp",
        properties: [
            PropertyExpectation(
                namespaceURI: "http://darktable.sf.net/",
                path: "history[1]/darktable:operation",
                value: "darktable history sentinel"
            ),
            PropertyExpectation(
                namespaceURI: "http://darktable.sf.net/",
                path: "history[1]/darktable:blendop_params",
                value: "darktable blend sentinel"
            ),
            PropertyExpectation(
                namespaceURI: "http://purl.org/dc/elements/1.1/",
                path: "subject[1]",
                value: "Existing darktable Keyword"
            ),
        ],
        expectsWritablePacketPadding: false
    ),
]

private func errorText(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "Unknown bridge error" }
    return String(cString: pointer)
}

private func roundTrip(_ data: Data, fixtureName: String) throws -> Data {
    var output = LouppeXMPBuffer(bytes: nil, length: 0)
    var error: UnsafeMutablePointer<CChar>?
    defer {
        LouppeXMPFreeBuffer(output)
        LouppeXMPFreeString(error)
    }

    let status = data.withUnsafeBytes { bytes in
        LouppeXMPRoundTrip(
            bytes.bindMemory(to: UInt8.self).baseAddress,
            bytes.count,
            &output,
            &error
        )
    }
    guard status == LouppeXMPStatusOK, let bytes = output.bytes else {
        throw ProofFailure.bridge(fixtureName, errorText(error))
    }
    return Data(bytes: bytes, count: output.length)
}

private func merge(_ data: Data, fixtureName: String) throws -> Data {
    var output = LouppeXMPBuffer(bytes: nil, length: 0)
    var error: UnsafeMutablePointer<CChar>?
    defer {
        LouppeXMPFreeBuffer(output)
        LouppeXMPFreeString(error)
    }

    let status = data.withUnsafeBytes { bytes in
        "Purple".withCString { color in
            "yes".withCString { decision in
                LouppeXMPMerge(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    LouppeXMPMetadata(
                        stars: 4,
                        colorLabel: color,
                        decision: decision
                    ),
                    &output,
                    &error
                )
            }
        }
    }
    guard status == LouppeXMPStatusOK, let bytes = output.bytes else {
        throw ProofFailure.bridge(fixtureName, errorText(error))
    }
    return Data(bytes: bytes, count: output.length)
}

private func readProperty(
    _ expectation: PropertyExpectation,
    from data: Data,
    fixtureName: String
) throws -> String {
    var value: UnsafeMutablePointer<CChar>?
    var error: UnsafeMutablePointer<CChar>?
    defer {
        LouppeXMPFreeString(value)
        LouppeXMPFreeString(error)
    }

    let status = data.withUnsafeBytes { bytes in
        expectation.namespaceURI.withCString { namespaceURI in
            expectation.path.withCString { propertyPath in
                LouppeXMPReadProperty(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    namespaceURI,
                    propertyPath,
                    &value,
                    &error
                )
            }
        }
    }
    guard status == LouppeXMPStatusOK, let value else {
        throw ProofFailure.bridge(
            "\(fixtureName) \(expectation.path)",
            errorText(error)
        )
    }
    return String(cString: value)
}

private func assertPreserved(
    _ expected: FixtureExpectation,
    in data: Data
) throws {
    guard let packet = String(data: data, encoding: .utf8) else {
        throw ProofFailure.bridge(expected.name, "Serialized packet is not UTF-8")
    }
    for property in expected.properties {
        let actual = try readProperty(
            property,
            from: data,
            fixtureName: expected.name
        )
        guard actual == property.value else {
            throw ProofFailure.lostValue(
                expected.name,
                property.path,
                property.value
            )
        }
    }

    if expected.expectsWritablePacketPadding {
        guard packet.contains("<?xpacket end=\"w\"?>") else {
            throw ProofFailure.missingPadding(expected.name)
        }
        let longestSpaceRun = packet
            .split(whereSeparator: { $0 != " " })
            .map(\.count)
            .max() ?? 0
        guard longestSpaceRun >= 100 else {
            throw ProofFailure.missingPadding(expected.name)
        }
    }
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw ProofFailure.usage
    }

    let fixtureDirectory = URL(
        fileURLWithPath: CommandLine.arguments[1],
        isDirectory: true
    )

    for expected in validFixtures {
        let fixtureURL = fixtureDirectory.appendingPathComponent(expected.name)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw ProofFailure.missingFixture(expected.name)
        }

        let original = try Data(contentsOf: fixtureURL)
        let roundTripped = try roundTrip(original, fixtureName: expected.name)
        try assertPreserved(expected, in: roundTripped)

        let merged = try merge(original, fixtureName: expected.name)
        try assertPreserved(
            FixtureExpectation(
                name: expected.name,
                properties: expected.properties.filter(\.preserveAfterMerge),
                expectsWritablePacketPadding: expected.expectsWritablePacketPadding
            ),
            in: merged
        )

        // A second pass proves that XMPCore can parse the exact bytes emitted by
        // the bridge and that setting the same owned fields is idempotent.
        _ = try merge(merged, fixtureName: expected.name)
    }

    let malformedURL = fixtureDirectory.appendingPathComponent("malformed.xmp")
    guard FileManager.default.fileExists(atPath: malformedURL.path) else {
        throw ProofFailure.missingFixture("malformed.xmp")
    }

    let malformed = try Data(contentsOf: malformedURL)
    do {
        _ = try roundTrip(malformed, fixtureName: "malformed.xmp")
        throw ProofFailure.malformedAccepted
    } catch ProofFailure.bridge {
        // Expected: the real parser rejects the invalid packet.
    }

    print("XMPCore bridge proof passed for \(validFixtures.count) valid fixtures; malformed XMP was rejected.")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("XMP bridge proof failed: \(error)\n".utf8))
    exit(1)
}
