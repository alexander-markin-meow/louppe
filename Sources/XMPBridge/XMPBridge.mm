#include "XMPBridge.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#define XMP_StaticBuild 1
#define TXMP_STRING_TYPE std::string
#define XMP_INCLUDE_XMPFILES 0
#include "public/include/XMP.incl_cpp"

namespace {

constexpr const char *kLouppeNamespace =
    "https://github.com/alexander-markin-meow/louppe/ns/1.0/";
constexpr const char *kLightroomNamespace =
    "http://ns.adobe.com/lightroom/1.0/";
constexpr const char *kFlatYes = "Louppe Decision: Yes";
constexpr const char *kFlatNo = "Louppe Decision: No";
constexpr const char *kHierarchicalYes =
    "Louppe Workflow|Louppe Decision: Yes";
constexpr const char *kHierarchicalNo =
    "Louppe Workflow|Louppe Decision: No";

std::once_flag initializationFlag;
bool initializationSucceeded = false;

bool initializeXMPCore() {
    std::call_once(initializationFlag, [] {
        initializationSucceeded = SXMPMeta::Initialize();
    });
    return initializationSucceeded;
}

bool failOnRecoverableParseError(
    void *,
    XMP_ErrorSeverity,
    XMP_Int32,
    XMP_StringPtr
) {
    // XMPCore otherwise treats malformed XML as recoverable and can return a
    // partial packet. Publication must reject instead of silently losing it.
    return false;
}

void requireStrictParsing(SXMPMeta &metadata) {
    metadata.SetErrorCallback(failOnRecoverableParseError, nullptr, 0);
}

void resetOutputs(LouppeXMPBuffer *output, char **errorMessage) {
    if (output != nullptr) {
        output->bytes = nullptr;
        output->length = 0;
    }
    if (errorMessage != nullptr) *errorMessage = nullptr;
}

void setError(char **errorMessage, const char *message) {
    if (errorMessage == nullptr || message == nullptr) return;
    const size_t length = std::strlen(message);
    char *copy = static_cast<char *>(std::malloc(length + 1));
    if (copy == nullptr) return;
    std::memcpy(copy, message, length);
    copy[length] = '\0';
    *errorMessage = copy;
}

bool copyString(const std::string &source, char **destination) {
    if (destination == nullptr) return false;
    char *copy = static_cast<char *>(std::malloc(source.size() + 1));
    if (copy == nullptr) return false;
    std::memcpy(copy, source.data(), source.size());
    copy[source.size()] = '\0';
    *destination = copy;
    return true;
}

LouppeXMPStatus caughtFailure(
    LouppeXMPStatus status,
    const char *message,
    char **errorMessage
) {
    setError(errorMessage, message);
    return status;
}

bool validMetadata(const LouppeXMPMetadata &metadata) {
    if (metadata.stars < 0 || metadata.stars > 5) return false;
    if (
        metadata.decision < LouppeXMPDecisionUndecided
        || metadata.decision > LouppeXMPDecisionNo
        || metadata.profile < LouppeXMPProfileUniversal
        || metadata.profile > LouppeXMPProfileDarktable
    ) return false;
    if (metadata.colorLabel == nullptr) return true;
    const std::string color(metadata.colorLabel);
    return color == "Red" || color == "Yellow" || color == "Green"
        || color == "Blue" || color == "Purple";
}

const char *decisionValue(LouppeXMPDecision decision) {
    switch (decision) {
    case LouppeXMPDecisionYes: return "yes";
    case LouppeXMPDecisionNo: return "no";
    case LouppeXMPDecisionUndecided: return "undecided";
    }
    return "";
}

bool propertyEquals(
    const SXMPMeta &packet,
    const char *namespaceURI,
    const char *path,
    const char *expected
) {
    std::string actual;
    return packet.GetProperty(namespaceURI, path, &actual, nullptr)
        && actual == expected;
}

bool propertyIsAbsent(
    const SXMPMeta &packet,
    const char *namespaceURI,
    const char *path
) {
    std::string ignored;
    return !packet.GetProperty(namespaceURI, path, &ignored, nullptr);
}

bool arrayContains(
    const SXMPMeta &packet,
    const char *namespaceURI,
    const char *path,
    const char *expected
) {
    const XMP_Index count = packet.CountArrayItems(namespaceURI, path);
    for (XMP_Index index = 1; index <= count; ++index) {
        std::string value;
        if (packet.GetArrayItem(namespaceURI, path, index, &value, nullptr)
            && value == expected) return true;
    }
    return false;
}

bool arrayExcludesReserved(
    const SXMPMeta &packet,
    const char *namespaceURI,
    const char *path,
    const char *first,
    const char *second
) {
    return !arrayContains(packet, namespaceURI, path, first)
        && !arrayContains(packet, namespaceURI, path, second);
}

void removeReservedArrayValues(
    SXMPMeta &packet,
    const char *namespaceURI,
    const char *path,
    const char *first,
    const char *second
) {
    const XMP_Index count = packet.CountArrayItems(namespaceURI, path);
    for (XMP_Index index = count; index >= 1; --index) {
        std::string value;
        if (packet.GetArrayItem(namespaceURI, path, index, &value, nullptr)
            && (value == first || value == second)) {
            packet.DeleteArrayItem(namespaceURI, path, index);
        }
    }
    if (packet.CountArrayItems(namespaceURI, path) == 0) {
        packet.DeleteProperty(namespaceURI, path);
    }
}

bool flatKeywordIsRequired(const LouppeXMPMetadata &metadata) {
    switch (metadata.profile) {
    case LouppeXMPProfileBridge:
    case LouppeXMPProfileCaptureOne:
    case LouppeXMPProfileDarktable:
        return true;
    case LouppeXMPProfileUniversal:
        return metadata.visibleDecisionKeywords != 0;
    case LouppeXMPProfileLightroomClassic:
        return false;
    }
    return false;
}

void applyKeywordMapping(
    SXMPMeta &packet,
    const LouppeXMPMetadata &metadata
) {
    removeReservedArrayValues(
        packet, kXMP_NS_DC, "subject", kFlatYes, kFlatNo
    );
    removeReservedArrayValues(
        packet,
        kLightroomNamespace,
        "hierarchicalSubject",
        kHierarchicalYes,
        kHierarchicalNo
    );

    if (metadata.decision == LouppeXMPDecisionUndecided) return;
    if (flatKeywordIsRequired(metadata)) {
        packet.AppendArrayItem(
            kXMP_NS_DC,
            "subject",
            kXMP_PropArrayIsUnordered,
            metadata.decision == LouppeXMPDecisionYes ? kFlatYes : kFlatNo
        );
    }
    if (metadata.profile == LouppeXMPProfileCaptureOne) {
        packet.AppendArrayItem(
            kLightroomNamespace,
            "hierarchicalSubject",
            kXMP_PropArrayIsUnordered,
            metadata.decision == LouppeXMPDecisionYes
                ? kHierarchicalYes : kHierarchicalNo
        );
    }
}

LouppeXMPStatus applyMapping(
    SXMPMeta &packet,
    const LouppeXMPMetadata &metadata,
    char **errorMessage
) {
    XMP_Int32 existingVersion = 0;
    const bool hasLouppeProvenance = packet.GetProperty_Int(
        kLouppeNamespace,
        "MetadataVersion",
        &existingVersion,
        nullptr
    ) && existingVersion == 1;

    std::string existingLabel;
    const bool hasExistingLabel = packet.GetProperty(
        kXMP_NS_XMP,
        "Label",
        &existingLabel,
        nullptr
    ) && !existingLabel.empty();
    const bool existingLabelIsLouppeValue = existingLabel == "Red"
        || existingLabel == "Yellow" || existingLabel == "Green"
        || existingLabel == "Blue" || existingLabel == "Purple";
    const bool desiredLabelDiffers = metadata.colorLabel == nullptr
        || existingLabel != metadata.colorLabel;
    const bool requiresLabelConfirmation = !existingLabelIsLouppeValue
        || (metadata.colorLabel == nullptr && !hasLouppeProvenance);
    if (
        hasExistingLabel
        && desiredLabelDiffers
        && requiresLabelConfirmation
        && metadata.allowExternalLabelRemoval == 0
    ) {
        const std::string message = "The existing xmp:Label \""
            + existingLabel
            + "\" cannot be replaced or removed without explicit confirmation";
        return caughtFailure(
            LouppeXMPStatusOwnershipConflict,
            message.c_str(),
            errorMessage
        );
    }

    packet.SetProperty_Int(kXMP_NS_XMP, "Rating", metadata.stars);
    if (metadata.colorLabel == nullptr) {
        packet.DeleteProperty(kXMP_NS_XMP, "Label");
    } else {
        packet.SetProperty(kXMP_NS_XMP, "Label", metadata.colorLabel);
    }

    if (metadata.profile == LouppeXMPProfileLightroomClassic) {
        switch (metadata.decision) {
        case LouppeXMPDecisionYes:
            packet.SetProperty_Int(kXMP_NS_DM, "pick", 1);
            packet.SetProperty_Bool(kXMP_NS_DM, "good", true);
            break;
        case LouppeXMPDecisionNo:
            packet.SetProperty_Int(kXMP_NS_DM, "pick", -1);
            packet.SetProperty_Bool(kXMP_NS_DM, "good", false);
            break;
        case LouppeXMPDecisionUndecided:
            packet.SetProperty_Int(kXMP_NS_DM, "pick", 0);
            packet.DeleteProperty(kXMP_NS_DM, "good");
            break;
        }
    }

    packet.SetProperty(
        kLouppeNamespace,
        "Decision",
        decisionValue(metadata.decision)
    );
    packet.SetProperty_Int(kLouppeNamespace, "MetadataVersion", 1);
    applyKeywordMapping(packet, metadata);
    return LouppeXMPStatusOK;
}

bool verifyMapping(
    const SXMPMeta &packet,
    const LouppeXMPMetadata &expected
) {
    XMP_Int32 stars = -1;
    XMP_Int32 metadataVersion = 0;
    if (!packet.GetProperty_Int(kXMP_NS_XMP, "Rating", &stars, nullptr)
        || stars != expected.stars
        || !packet.GetProperty_Int(
            kLouppeNamespace,
            "MetadataVersion",
            &metadataVersion,
            nullptr
        )
        || metadataVersion != 1
        || !propertyEquals(
            packet,
            kLouppeNamespace,
            "Decision",
            decisionValue(expected.decision)
        )) return false;

    if (expected.colorLabel == nullptr) {
        if (!propertyIsAbsent(packet, kXMP_NS_XMP, "Label")) return false;
    } else if (!propertyEquals(
        packet, kXMP_NS_XMP, "Label", expected.colorLabel
    )) return false;

    if (expected.profile == LouppeXMPProfileLightroomClassic) {
        XMP_Int32 pick = 99;
        const XMP_Int32 expectedPick =
            expected.decision == LouppeXMPDecisionYes ? 1
            : expected.decision == LouppeXMPDecisionNo ? -1 : 0;
        if (!packet.GetProperty_Int(kXMP_NS_DM, "pick", &pick, nullptr)
            || pick != expectedPick) return false;
        if (expected.decision == LouppeXMPDecisionUndecided) {
            if (!propertyIsAbsent(packet, kXMP_NS_DM, "good")) return false;
        } else {
            bool good = false;
            if (!packet.GetProperty_Bool(kXMP_NS_DM, "good", &good, nullptr)
                || good != (expected.decision == LouppeXMPDecisionYes)) {
                return false;
            }
        }
    }

    const bool expectsFlat = flatKeywordIsRequired(expected)
        && expected.decision != LouppeXMPDecisionUndecided;
    const char *flat = expected.decision == LouppeXMPDecisionYes
        ? kFlatYes : kFlatNo;
    if (expectsFlat) {
        const char *otherFlat = expected.decision == LouppeXMPDecisionYes
            ? kFlatNo : kFlatYes;
        if (!arrayContains(packet, kXMP_NS_DC, "subject", flat)
            || arrayContains(packet, kXMP_NS_DC, "subject", otherFlat)) {
            return false;
        }
    } else if (!arrayExcludesReserved(
        packet, kXMP_NS_DC, "subject", kFlatYes, kFlatNo
    )) return false;

    const bool expectsHierarchical =
        expected.profile == LouppeXMPProfileCaptureOne
        && expected.decision != LouppeXMPDecisionUndecided;
    const char *hierarchical = expected.decision == LouppeXMPDecisionYes
        ? kHierarchicalYes : kHierarchicalNo;
    if (expectsHierarchical) {
        const char *otherHierarchical =
            expected.decision == LouppeXMPDecisionYes
                ? kHierarchicalNo : kHierarchicalYes;
        if (!arrayContains(
            packet,
            kLightroomNamespace,
            "hierarchicalSubject",
            hierarchical
        ) || arrayContains(
            packet,
            kLightroomNamespace,
            "hierarchicalSubject",
            otherHierarchical
        )) return false;
    } else if (!arrayExcludesReserved(
        packet,
        kLightroomNamespace,
        "hierarchicalSubject",
        kHierarchicalYes,
        kHierarchicalNo
    )) return false;
    return true;
}

uint32_t inspectChanges(
    const SXMPMeta &packet,
    const LouppeXMPMetadata &metadata
) {
    uint32_t changes = LouppeXMPChangeNone;
    std::string value;

    if (packet.GetProperty(kXMP_NS_XMP, "Rating", &value, nullptr)
        && !value.empty() && value != std::to_string(metadata.stars)) {
        changes |= LouppeXMPChangeStars;
    }

    value.clear();
    if (packet.GetProperty(kXMP_NS_XMP, "Label", &value, nullptr)
        && !value.empty()
        && (metadata.colorLabel == nullptr || value != metadata.colorLabel)) {
        changes |= LouppeXMPChangeColor;
    }

    value.clear();
    if (packet.GetProperty(kLouppeNamespace, "Decision", &value, nullptr)
        && !value.empty() && value != decisionValue(metadata.decision)) {
        changes |= LouppeXMPChangeFlag;
    }
    if (metadata.profile == LouppeXMPProfileLightroomClassic) {
        XMP_Int32 pick = 99;
        const XMP_Int32 expectedPick =
            metadata.decision == LouppeXMPDecisionYes ? 1
            : metadata.decision == LouppeXMPDecisionNo ? -1 : 0;
        if (packet.GetProperty_Int(kXMP_NS_DM, "pick", &pick, nullptr)
            && pick != expectedPick) {
            changes |= LouppeXMPChangeFlag;
        }
        bool good = false;
        const bool hasGood = packet.GetProperty_Bool(
            kXMP_NS_DM, "good", &good, nullptr
        );
        if (hasGood && (
            metadata.decision == LouppeXMPDecisionUndecided
            || good != (metadata.decision == LouppeXMPDecisionYes)
        )) {
            changes |= LouppeXMPChangeFlag;
        }
    }

    const bool hasFlatYes = arrayContains(
        packet, kXMP_NS_DC, "subject", kFlatYes
    );
    const bool hasFlatNo = arrayContains(
        packet, kXMP_NS_DC, "subject", kFlatNo
    );
    const bool expectsFlat = flatKeywordIsRequired(metadata)
        && metadata.decision != LouppeXMPDecisionUndecided;
    const bool expectsFlatYes = expectsFlat
        && metadata.decision == LouppeXMPDecisionYes;
    const bool expectsFlatNo = expectsFlat
        && metadata.decision == LouppeXMPDecisionNo;

    const bool hasHierarchicalYes = arrayContains(
        packet,
        kLightroomNamespace,
        "hierarchicalSubject",
        kHierarchicalYes
    );
    const bool hasHierarchicalNo = arrayContains(
        packet,
        kLightroomNamespace,
        "hierarchicalSubject",
        kHierarchicalNo
    );
    const bool expectsHierarchical =
        metadata.profile == LouppeXMPProfileCaptureOne
        && metadata.decision != LouppeXMPDecisionUndecided;
    const bool expectsHierarchicalYes = expectsHierarchical
        && metadata.decision == LouppeXMPDecisionYes;
    const bool expectsHierarchicalNo = expectsHierarchical
        && metadata.decision == LouppeXMPDecisionNo;

    const bool hasReservedKeyword = hasFlatYes || hasFlatNo
        || hasHierarchicalYes || hasHierarchicalNo;
    const bool keywordMappingChanges =
        hasFlatYes != expectsFlatYes
        || hasFlatNo != expectsFlatNo
        || hasHierarchicalYes != expectsHierarchicalYes
        || hasHierarchicalNo != expectsHierarchicalNo;
    if (hasReservedKeyword && keywordMappingChanges) {
        changes |= LouppeXMPChangeKeywords;
    }
    return changes;
}

LouppeXMPStatus parsePacket(
    const uint8_t *inputBytes,
    size_t inputLength,
    SXMPMeta &packet,
    char **errorMessage
) {
    if (inputLength == 0) return LouppeXMPStatusOK;
    if (inputBytes == nullptr) {
        return caughtFailure(
            LouppeXMPStatusInvalidArgument,
            "A non-null packet is required when the length is non-zero",
            errorMessage
        );
    }
    requireStrictParsing(packet);
    packet.ParseFromBuffer(
        reinterpret_cast<const char *>(inputBytes),
        inputLength,
        kXMP_RequireXMPMeta
    );
    return LouppeXMPStatusOK;
}

LouppeXMPStatus serialize(
    const SXMPMeta &metadata,
    LouppeXMPBuffer *output,
    char **errorMessage
) {
    std::string serialized;
    metadata.SerializeToBuffer(&serialized);
    if (serialized.empty()) {
        return caughtFailure(
            LouppeXMPStatusSerializationFailed,
            "XMPCore returned an empty serialized packet",
            errorMessage
        );
    }
    auto *bytes = static_cast<uint8_t *>(std::malloc(serialized.size()));
    if (bytes == nullptr) {
        return caughtFailure(
            LouppeXMPStatusSerializationFailed,
            "Could not allocate the serialized XMP buffer",
            errorMessage
        );
    }
    std::memcpy(bytes, serialized.data(), serialized.size());
    output->bytes = bytes;
    output->length = serialized.size();
    return LouppeXMPStatusOK;
}

} // namespace

LouppeXMPStatus LouppeXMPInitialize(char **errorMessage) {
    if (errorMessage != nullptr) *errorMessage = nullptr;
    if (initializeXMPCore()) return LouppeXMPStatusOK;
    return caughtFailure(
        LouppeXMPStatusInitializationFailed,
        "XMPCore initialization failed",
        errorMessage
    );
}

LouppeXMPStatus LouppeXMPRoundTrip(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPBuffer *output,
    char **errorMessage
) {
    resetOutputs(output, errorMessage);
    if (inputBytes == nullptr || inputLength == 0 || output == nullptr) {
        return caughtFailure(
            LouppeXMPStatusInvalidArgument,
            "A non-empty input packet and output buffer are required",
            errorMessage
        );
    }
    if (!initializeXMPCore()) {
        return caughtFailure(
            LouppeXMPStatusInitializationFailed,
            "XMPCore initialization failed",
            errorMessage
        );
    }
    try {
        SXMPMeta packet;
        const auto status = parsePacket(
            inputBytes, inputLength, packet, errorMessage
        );
        if (status != LouppeXMPStatusOK) return status;
        return serialize(packet, output, errorMessage);
    } catch (const XMP_Error &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed, error.GetErrMsg(), errorMessage
        );
    } catch (const std::exception &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed, error.what(), errorMessage
        );
    } catch (...) {
        return caughtFailure(
            LouppeXMPStatusParseFailed,
            "Unknown XMPCore parse failure",
            errorMessage
        );
    }
}

LouppeXMPStatus LouppeXMPMerge(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPMetadata metadata,
    LouppeXMPBuffer *output,
    char **errorMessage
) {
    resetOutputs(output, errorMessage);
    if (output == nullptr || !validMetadata(metadata)) {
        return caughtFailure(
            LouppeXMPStatusInvalidArgument,
            "The packet or typed metadata values are invalid",
            errorMessage
        );
    }
    if (!initializeXMPCore()) {
        return caughtFailure(
            LouppeXMPStatusInitializationFailed,
            "XMPCore initialization failed",
            errorMessage
        );
    }
    try {
        SXMPMeta packet;
        auto status = parsePacket(inputBytes, inputLength, packet, errorMessage);
        if (status != LouppeXMPStatusOK) return status;

        std::string prefix;
        SXMPMeta::RegisterNamespace(kLouppeNamespace, "louppe", &prefix);
        SXMPMeta::RegisterNamespace(kLightroomNamespace, "lr", &prefix);
        status = applyMapping(packet, metadata, errorMessage);
        if (status != LouppeXMPStatusOK) return status;

        std::string serialized;
        packet.SerializeToBuffer(&serialized);
        SXMPMeta reparsed;
        requireStrictParsing(reparsed);
        reparsed.ParseFromBuffer(
            serialized.data(), serialized.size(), kXMP_RequireXMPMeta
        );
        if (!verifyMapping(reparsed, metadata)) {
            return caughtFailure(
                LouppeXMPStatusVerificationFailed,
                "Serialized XMP did not retain the intended owned fields",
                errorMessage
            );
        }

        auto *bytes = static_cast<uint8_t *>(std::malloc(serialized.size()));
        if (bytes == nullptr) {
            return caughtFailure(
                LouppeXMPStatusSerializationFailed,
                "Could not allocate the serialized XMP buffer",
                errorMessage
            );
        }
        std::memcpy(bytes, serialized.data(), serialized.size());
        output->bytes = bytes;
        output->length = serialized.size();
        return LouppeXMPStatusOK;
    } catch (const XMP_Error &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed, error.GetErrMsg(), errorMessage
        );
    } catch (const std::exception &error) {
        return caughtFailure(
            LouppeXMPStatusSerializationFailed, error.what(), errorMessage
        );
    } catch (...) {
        return caughtFailure(
            LouppeXMPStatusSerializationFailed,
            "Unknown XMPCore merge failure",
            errorMessage
        );
    }
}

LouppeXMPStatus LouppeXMPVerify(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPMetadata metadata,
    char **errorMessage
) {
    if (errorMessage != nullptr) *errorMessage = nullptr;
    if (
        inputBytes == nullptr || inputLength == 0 || !validMetadata(metadata)
    ) {
        return caughtFailure(
            LouppeXMPStatusInvalidArgument,
            "A packet and valid typed metadata are required",
            errorMessage
        );
    }
    if (!initializeXMPCore()) {
        return caughtFailure(
            LouppeXMPStatusInitializationFailed,
            "XMPCore initialization failed",
            errorMessage
        );
    }
    try {
        SXMPMeta packet;
        const auto status = parsePacket(
            inputBytes, inputLength, packet, errorMessage
        );
        if (status != LouppeXMPStatusOK) return status;
        if (!verifyMapping(packet, metadata)) {
            return caughtFailure(
                LouppeXMPStatusVerificationFailed,
                "The XMP packet does not contain the intended owned fields",
                errorMessage
            );
        }
        return LouppeXMPStatusOK;
    } catch (const XMP_Error &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed, error.GetErrMsg(), errorMessage
        );
    } catch (const std::exception &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed, error.what(), errorMessage
        );
    } catch (...) {
        return caughtFailure(
            LouppeXMPStatusParseFailed,
            "Unknown XMPCore verification failure",
            errorMessage
        );
    }
}

LouppeXMPStatus LouppeXMPReadProperty(
    const uint8_t *inputBytes,
    size_t inputLength,
    const char *namespaceURI,
    const char *propertyPath,
    char **propertyValue,
    char **errorMessage
) {
    if (propertyValue != nullptr) *propertyValue = nullptr;
    if (errorMessage != nullptr) *errorMessage = nullptr;
    if (
        inputBytes == nullptr || inputLength == 0 || namespaceURI == nullptr
        || propertyPath == nullptr || propertyValue == nullptr
    ) {
        return caughtFailure(
            LouppeXMPStatusInvalidArgument,
            "A packet, namespace, property path, and value output are required",
            errorMessage
        );
    }
    if (!initializeXMPCore()) {
        return caughtFailure(
            LouppeXMPStatusInitializationFailed,
            "XMPCore initialization failed",
            errorMessage
        );
    }
    try {
        SXMPMeta packet;
        const auto status = parsePacket(
            inputBytes, inputLength, packet, errorMessage
        );
        if (status != LouppeXMPStatusOK) return status;
        std::string value;
        if (!packet.GetProperty(
            namespaceURI, propertyPath, &value, nullptr
        )) {
            return caughtFailure(
                LouppeXMPStatusPropertyMissing,
                "The expected XMP property is missing",
                errorMessage
            );
        }
        if (!copyString(value, propertyValue)) {
            return caughtFailure(
                LouppeXMPStatusSerializationFailed,
                "Could not allocate the property value",
                errorMessage
            );
        }
        return LouppeXMPStatusOK;
    } catch (const XMP_Error &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed, error.GetErrMsg(), errorMessage
        );
    } catch (const std::exception &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed, error.what(), errorMessage
        );
    } catch (...) {
        return caughtFailure(
            LouppeXMPStatusParseFailed,
            "Unknown XMPCore property-read failure",
            errorMessage
        );
    }
}

LouppeXMPStatus LouppeXMPInspectChanges(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPMetadata metadata,
    uint32_t *changeMask,
    char **errorMessage
) {
    if (changeMask != nullptr) *changeMask = LouppeXMPChangeNone;
    if (errorMessage != nullptr) *errorMessage = nullptr;
    if (
        inputBytes == nullptr || inputLength == 0 || changeMask == nullptr
        || !validMetadata(metadata)
    ) {
        return caughtFailure(
            LouppeXMPStatusInvalidArgument,
            "A packet, valid metadata, and change output are required",
            errorMessage
        );
    }
    if (!initializeXMPCore()) {
        return caughtFailure(
            LouppeXMPStatusInitializationFailed,
            "XMPCore initialization failed",
            errorMessage
        );
    }
    try {
        SXMPMeta packet;
        const auto status = parsePacket(
            inputBytes, inputLength, packet, errorMessage
        );
        if (status != LouppeXMPStatusOK) return status;
        *changeMask = inspectChanges(packet, metadata);
        return LouppeXMPStatusOK;
    } catch (const XMP_Error &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed, error.GetErrMsg(), errorMessage
        );
    } catch (const std::exception &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed, error.what(), errorMessage
        );
    } catch (...) {
        return caughtFailure(
            LouppeXMPStatusParseFailed,
            "Unknown XMPCore change-inspection failure",
            errorMessage
        );
    }
}

void LouppeXMPFreeBuffer(LouppeXMPBuffer buffer) {
    std::free(buffer.bytes);
}

void LouppeXMPFreeString(char *string) {
    std::free(string);
}
