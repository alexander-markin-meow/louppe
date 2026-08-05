import Foundation
import XMPBridge

enum XMPFieldMappingError: LocalizedError, Equatable {
    case invalidPacket(String)
    case ownershipConflict(String)
    case serialization(String)
    case verification(String)
    case propertyMissing(String)

    var errorDescription: String? {
        switch self {
        case .invalidPacket(let message),
             .serialization(let message),
             .verification(let message),
             .propertyMissing(let message):
            return message
        case .ownershipConflict(let message):
            return "XMP ownership conflict: \(message)"
        }
    }
}

enum XMPFieldMapping {
    struct ExistingChangeSummary: Equatable, Sendable {
        let stars: Bool
        let color: Bool
        let flag: Bool
        let keywords: Bool

        static let none = ExistingChangeSummary(
            stars: false,
            color: false,
            flag: false,
            keywords: false
        )
    }
    static let maximumPacketBytes = 64 * 1024 * 1024
    static let louppeNamespace =
        "https://github.com/alexander-markin-meow/louppe/ns/1.0/"
    static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"
    static let dynamicMediaNamespace =
        "http://ns.adobe.com/xmp/1.0/DynamicMedia/"
    static let dcNamespace = "http://purl.org/dc/elements/1.1/"
    static let lightroomNamespace = "http://ns.adobe.com/lightroom/1.0/"

    static let flatYesKeyword = "Louppe Decision: Yes"
    static let flatNoKeyword = "Louppe Decision: No"
    static let hierarchicalYesKeyword =
        "Louppe Workflow|Louppe Decision: Yes"
    static let hierarchicalNoKeyword =
        "Louppe Workflow|Louppe Decision: No"

    /// Referenced from the app entry point so the safe parser core remains in
    /// release builds before Phase 6 exposes any publication action.
    static let runtimeIsAvailable: Bool = {
        guard LouppeXMPInitialize(nil) == LouppeXMPStatusOK else {
            return false
        }
        // Exercise only an in-memory packet. This proves the production merge
        // and semantic verification path is linked without touching a folder.
        let metadata = XMPPublicationMetadata(
            decision: .undecided,
            stars: nil,
            colorLabel: nil,
            profile: .universal
        )
        guard let packet = try? merge(packet: nil, metadata: metadata) else {
            return false
        }
        return (try? verify(packet: packet, metadata: metadata)) != nil
    }()

    static func merge(
        packet: Data?,
        metadata: XMPPublicationMetadata
    ) throws -> Data {
        if let packet, packet.isEmpty {
            throw XMPFieldMappingError.invalidPacket(
                "An existing XMP packet is empty and cannot be merged safely."
            )
        }
        let input = packet ?? Data()
        guard input.count <= maximumPacketBytes else {
            throw XMPFieldMappingError.invalidPacket(
                "The XMP packet exceeds Louppe's 64 MiB safety limit."
            )
        }

        return try withBridgeMetadata(metadata) { bridgeMetadata in
            var output = LouppeXMPBuffer(bytes: nil, length: 0)
            var error: UnsafeMutablePointer<CChar>?
            defer {
                LouppeXMPFreeBuffer(output)
                LouppeXMPFreeString(error)
            }

            let status = input.withUnsafeBytes { bytes in
                LouppeXMPMerge(
                    bytes.isEmpty
                        ? nil
                        : bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    bridgeMetadata,
                    &output,
                    &error
                )
            }
            guard status == LouppeXMPStatusOK, let bytes = output.bytes else {
                throw mappedError(status: status, message: errorText(error))
            }
            return Data(bytes: bytes, count: output.length)
        }
    }

    static func verify(
        packet: Data,
        metadata: XMPPublicationMetadata
    ) throws {
        guard !packet.isEmpty, packet.count <= maximumPacketBytes else {
            throw XMPFieldMappingError.invalidPacket(
                "The XMP packet is empty or exceeds Louppe's 64 MiB safety limit."
            )
        }
        try withBridgeMetadata(metadata) { bridgeMetadata in
            var error: UnsafeMutablePointer<CChar>?
            defer { LouppeXMPFreeString(error) }
            let status = packet.withUnsafeBytes { bytes in
                LouppeXMPVerify(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    bridgeMetadata,
                    &error
                )
            }
            guard status == LouppeXMPStatusOK else {
                throw mappedError(status: status, message: errorText(error))
            }
        }
    }

    static func readProperty(
        namespace: String,
        path: String,
        packet: Data
    ) throws -> String {
        var value: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        defer {
            LouppeXMPFreeString(value)
            LouppeXMPFreeString(error)
        }

        let status = packet.withUnsafeBytes { bytes in
            namespace.withCString { namespacePointer in
                path.withCString { pathPointer in
                    LouppeXMPReadProperty(
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count,
                        namespacePointer,
                        pathPointer,
                        &value,
                        &error
                    )
                }
            }
        }
        guard status == LouppeXMPStatusOK, let value else {
            throw mappedError(status: status, message: errorText(error))
        }
        return String(cString: value)
    }

    static func inspectExistingChanges(
        packet: Data,
        metadata: XMPPublicationMetadata
    ) throws -> ExistingChangeSummary {
        try withBridgeMetadata(metadata) { bridgeMetadata in
            var mask: UInt32 = 0
            var error: UnsafeMutablePointer<CChar>?
            defer { LouppeXMPFreeString(error) }
            let status = packet.withUnsafeBytes { bytes in
                LouppeXMPInspectChanges(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    bridgeMetadata,
                    &mask,
                    &error
                )
            }
            guard status == LouppeXMPStatusOK else {
                throw mappedError(status: status, message: errorText(error))
            }
            return ExistingChangeSummary(
                stars: mask & UInt32(LouppeXMPChangeStars.rawValue) != 0,
                color: mask & UInt32(LouppeXMPChangeColor.rawValue) != 0,
                flag: mask & UInt32(LouppeXMPChangeFlag.rawValue) != 0,
                keywords: mask & UInt32(LouppeXMPChangeKeywords.rawValue) != 0
            )
        }
    }

    private static func withBridgeMetadata<Result>(
        _ metadata: XMPPublicationMetadata,
        perform body: (LouppeXMPMetadata) throws -> Result
    ) throws -> Result {
        guard let color = metadata.colorLabel?.displayName else {
            return try body(metadata.bridgeValue(colorLabel: nil))
        }
        return try color.withCString { pointer in
            try body(metadata.bridgeValue(colorLabel: pointer))
        }
    }

    private static func errorText(
        _ pointer: UnsafeMutablePointer<CChar>?
    ) -> String {
        pointer.map { String(cString: $0) } ?? "Unknown XMPCore failure."
    }

    private static func mappedError(
        status: LouppeXMPStatus,
        message: String
    ) -> XMPFieldMappingError {
        switch status {
        case LouppeXMPStatusOwnershipConflict:
            return .ownershipConflict(message)
        case LouppeXMPStatusVerificationFailed:
            return .verification(message)
        case LouppeXMPStatusSerializationFailed:
            return .serialization(message)
        case LouppeXMPStatusPropertyMissing:
            return .propertyMissing(message)
        default:
            return .invalidPacket(message)
        }
    }
}
