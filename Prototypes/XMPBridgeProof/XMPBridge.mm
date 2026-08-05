#include "XMPBridge.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <string>

#define XMP_StaticBuild 1
#define TXMP_STRING_TYPE std::string
#define XMP_INCLUDE_XMPFILES 0
#include "public/include/XMP.incl_cpp"

namespace {

constexpr const char *kLouppeNamespace =
    "https://github.com/alexander-markin-meow/louppe/ns/1.0/";

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
    // partial packet. Publication must reject rather than silently discard it.
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
    if (errorMessage != nullptr) {
        *errorMessage = nullptr;
    }
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

LouppeXMPStatus serialize(
    const SXMPMeta &metadata,
    LouppeXMPBuffer *output,
    char **errorMessage
) {
    std::string serialized;
    metadata.SerializeToBuffer(&serialized);

    if (serialized.empty()) {
        setError(errorMessage, "XMPCore returned an empty serialized packet");
        return LouppeXMPStatusSerializationFailed;
    }

    auto *bytes = static_cast<uint8_t *>(std::malloc(serialized.size()));
    if (bytes == nullptr) {
        setError(errorMessage, "Could not allocate the serialized XMP buffer");
        return LouppeXMPStatusSerializationFailed;
    }

    std::memcpy(bytes, serialized.data(), serialized.size());
    output->bytes = bytes;
    output->length = serialized.size();
    return LouppeXMPStatusOK;
}

bool verifyOwnedFields(
    const std::string &serialized,
    const LouppeXMPMetadata &expected
) {
    SXMPMeta reparsed;
    requireStrictParsing(reparsed);
    reparsed.ParseFromBuffer(
        serialized.data(),
        serialized.size(),
        kXMP_RequireXMPMeta
    );

    XMP_Int32 stars = -1;
    std::string color;
    std::string decision;
    XMP_Int32 metadataVersion = 0;

    return reparsed.GetProperty_Int(kXMP_NS_XMP, "Rating", &stars, nullptr)
        && stars == expected.stars
        && reparsed.GetProperty(kXMP_NS_XMP, "Label", &color, nullptr)
        && color == expected.colorLabel
        && reparsed.GetProperty(kLouppeNamespace, "Decision", &decision, nullptr)
        && decision == expected.decision
        && reparsed.GetProperty_Int(
            kLouppeNamespace,
            "MetadataVersion",
            &metadataVersion,
            nullptr
        )
        && metadataVersion == 1;
}

LouppeXMPStatus caughtFailure(
    LouppeXMPStatus status,
    const char *message,
    char **errorMessage
) {
    setError(errorMessage, message);
    return status;
}

} // namespace

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
        SXMPMeta metadata;
        requireStrictParsing(metadata);
        metadata.ParseFromBuffer(
            reinterpret_cast<const char *>(inputBytes),
            inputLength,
            kXMP_RequireXMPMeta
        );
        return serialize(metadata, output, errorMessage);
    } catch (const XMP_Error &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed,
            error.GetErrMsg(),
            errorMessage
        );
    } catch (const std::exception &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed,
            error.what(),
            errorMessage
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

    if (
        inputBytes == nullptr
        || inputLength == 0
        || output == nullptr
        || metadata.stars < 0
        || metadata.stars > 5
        || metadata.colorLabel == nullptr
        || metadata.decision == nullptr
    ) {
        return caughtFailure(
            LouppeXMPStatusInvalidArgument,
            "The packet and typed metadata values are invalid",
            errorMessage
        );
    }

    const std::string decision(metadata.decision);
    if (decision != "yes" && decision != "no" && decision != "undecided") {
        return caughtFailure(
            LouppeXMPStatusInvalidArgument,
            "Decision must be yes, no, or undecided",
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
        requireStrictParsing(packet);
        packet.ParseFromBuffer(
            reinterpret_cast<const char *>(inputBytes),
            inputLength,
            kXMP_RequireXMPMeta
        );

        std::string registeredPrefix;
        SXMPMeta::RegisterNamespace(
            kLouppeNamespace,
            "louppe",
            &registeredPrefix
        );

        packet.SetProperty_Int(kXMP_NS_XMP, "Rating", metadata.stars);
        packet.SetProperty(kXMP_NS_XMP, "Label", metadata.colorLabel);
        packet.SetProperty(kLouppeNamespace, "Decision", metadata.decision);
        packet.SetProperty_Int(kLouppeNamespace, "MetadataVersion", 1);

        std::string serialized;
        packet.SerializeToBuffer(&serialized);
        if (!verifyOwnedFields(serialized, metadata)) {
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
            LouppeXMPStatusParseFailed,
            error.GetErrMsg(),
            errorMessage
        );
    } catch (const std::exception &error) {
        return caughtFailure(
            LouppeXMPStatusSerializationFailed,
            error.what(),
            errorMessage
        );
    } catch (...) {
        return caughtFailure(
            LouppeXMPStatusSerializationFailed,
            "Unknown XMPCore merge failure",
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
        inputBytes == nullptr
        || inputLength == 0
        || namespaceURI == nullptr
        || propertyPath == nullptr
        || propertyValue == nullptr
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
        requireStrictParsing(packet);
        packet.ParseFromBuffer(
            reinterpret_cast<const char *>(inputBytes),
            inputLength,
            kXMP_RequireXMPMeta
        );

        std::string value;
        if (!packet.GetProperty(namespaceURI, propertyPath, &value, nullptr)) {
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
            LouppeXMPStatusParseFailed,
            error.GetErrMsg(),
            errorMessage
        );
    } catch (const std::exception &error) {
        return caughtFailure(
            LouppeXMPStatusParseFailed,
            error.what(),
            errorMessage
        );
    } catch (...) {
        return caughtFailure(
            LouppeXMPStatusParseFailed,
            "Unknown XMPCore property-read failure",
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
