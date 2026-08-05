import Darwin
import Foundation

/// A path whose authority is its exact NUL-free filesystem bytes. Display URLs
/// may be derived from it, but publication plans never regenerate these bytes
/// from a Swift path string.
struct XMPExactFileSystemPath: Hashable, Sendable {
    enum PathError: LocalizedError {
        case invalidRepresentation
        case invalidChildName

        var errorDescription: String? {
            switch self {
            case .invalidRepresentation:
                return "The filesystem path cannot be represented exactly."
            case .invalidChildName:
                return "The directory entry has an unsafe filename."
            }
        }
    }

    let bytes: Data

    init(url: URL) throws {
        guard let captured = Self.captureBytes(url),
              !captured.isEmpty,
              !captured.contains(0) else {
            throw PathError.invalidRepresentation
        }
        let roundTripped = try Self.makeURL(bytes: captured)
        guard Self.captureBytes(roundTripped) == captured else {
            throw PathError.invalidRepresentation
        }
        bytes = captured
    }

    private init(validatedBytes: Data) {
        bytes = validatedBytes
    }

    var url: URL {
        // Every initializer proves this conversion and byte-for-byte round trip.
        try! Self.makeURL(bytes: bytes)
    }

    var lastComponentBytes: Data {
        guard let separator = bytes.lastIndex(of: UInt8(ascii: "/")) else {
            return bytes
        }
        return bytes[bytes.index(after: separator)...]
    }

    var parent: XMPExactFileSystemPath {
        guard let separator = bytes.lastIndex(of: UInt8(ascii: "/")),
              separator != bytes.startIndex else {
            return XMPExactFileSystemPath(validatedBytes: Data([UInt8(ascii: "/")]))
        }
        return XMPExactFileSystemPath(
            validatedBytes: bytes[..<separator]
        )
    }

    func appending(componentBytes: Data) throws -> XMPExactFileSystemPath {
        guard !componentBytes.isEmpty,
              !componentBytes.contains(0),
              !componentBytes.contains(UInt8(ascii: "/")),
              componentBytes != Data(".".utf8),
              componentBytes != Data("..".utf8) else {
            throw PathError.invalidChildName
        }
        var result = bytes
        if result.last != UInt8(ascii: "/") {
            result.append(UInt8(ascii: "/"))
        }
        result.append(componentBytes)
        let path = XMPExactFileSystemPath(validatedBytes: result)
        guard Self.captureBytes(path.url) == result else {
            throw PathError.invalidRepresentation
        }
        return path
    }

    func withFileSystemRepresentation<Result>(
        _ body: (UnsafePointer<CChar>) throws -> Result
    ) rethrows -> Result {
        var terminated = bytes
        terminated.append(0)
        return try terminated.withUnsafeBytes { rawBuffer in
            try body(rawBuffer.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    private static func captureBytes(_ url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { Data(bytes: $0, count: strlen($0)) }
        }
    }

    private static func makeURL(bytes: Data) throws -> URL {
        var terminated = bytes
        terminated.append(0)
        return try terminated.withUnsafeBytes { rawBuffer in
            guard let pointer = rawBuffer.bindMemory(to: CChar.self).baseAddress else {
                throw PathError.invalidRepresentation
            }
            return URL(
                fileURLWithFileSystemRepresentation: pointer,
                isDirectory: false,
                relativeTo: nil
            )
        }
    }
}
