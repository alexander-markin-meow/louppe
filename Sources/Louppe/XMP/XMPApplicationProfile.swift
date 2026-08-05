import Foundation
import XMPBridge

enum XMPApplicationProfile: String, CaseIterable, Codable, Hashable, Sendable {
    case universal
    case lightroomClassic
    case bridge
    case captureOne
    case darktable

    var displayName: String {
        switch self {
        case .universal: return "Universal XMP"
        case .lightroomClassic: return "Adobe Lightroom Classic"
        case .bridge: return "Adobe Bridge"
        case .captureOne: return "Capture One"
        case .darktable: return "darktable"
        }
    }

    var usesVisibleDecisionKeywordsByDefault: Bool {
        switch self {
        case .bridge, .captureOne, .darktable: return true
        case .universal, .lightroomClassic: return false
        }
    }

    var bridgeValue: LouppeXMPProfile {
        switch self {
        case .universal: return LouppeXMPProfileUniversal
        case .lightroomClassic: return LouppeXMPProfileLightroomClassic
        case .bridge: return LouppeXMPProfileBridge
        case .captureOne: return LouppeXMPProfileCaptureOne
        case .darktable: return LouppeXMPProfileDarktable
        }
    }
}

struct XMPPublicationMetadata: Equatable, Hashable, Sendable {
    let decision: Rating
    let stars: StarRating?
    let colorLabel: PhotoColorLabel?
    let profile: XMPApplicationProfile
    let visibleDecisionKeywords: Bool
    let allowExternalLabelRemoval: Bool

    init(
        decision: Rating,
        stars: StarRating?,
        colorLabel: PhotoColorLabel?,
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool? = nil,
        allowExternalLabelRemoval: Bool = false
    ) {
        self.decision = decision
        self.stars = stars
        self.colorLabel = colorLabel
        self.profile = profile
        self.visibleDecisionKeywords = visibleDecisionKeywords
            ?? profile.usesVisibleDecisionKeywordsByDefault
        self.allowExternalLabelRemoval = allowExternalLabelRemoval
    }

    init(
        snapshot: PhotoFileMetadataSnapshot,
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool? = nil,
        allowExternalLabelRemoval: Bool = false
    ) {
        self.init(
            decision: snapshot.rating,
            stars: snapshot.starRating,
            colorLabel: snapshot.colorLabel,
            profile: profile,
            visibleDecisionKeywords: visibleDecisionKeywords,
            allowExternalLabelRemoval: allowExternalLabelRemoval
        )
    }

    var bridgeDecision: LouppeXMPDecision {
        switch decision {
        case .undecided: return LouppeXMPDecisionUndecided
        case .yes: return LouppeXMPDecisionYes
        case .no: return LouppeXMPDecisionNo
        }
    }

    func bridgeValue(
        colorLabel: UnsafePointer<CChar>?
    ) -> LouppeXMPMetadata {
        LouppeXMPMetadata(
            stars: Int32(stars?.rawValue ?? 0),
            colorLabel: colorLabel,
            decision: bridgeDecision,
            profile: profile.bridgeValue,
            visibleDecisionKeywords: visibleDecisionKeywords ? 1 : 0,
            allowExternalLabelRemoval: allowExternalLabelRemoval ? 1 : 0
        )
    }
}
