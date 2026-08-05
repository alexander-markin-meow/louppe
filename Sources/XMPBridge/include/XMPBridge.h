#ifndef LOUPPE_XMP_BRIDGE_H
#define LOUPPE_XMP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LouppeXMPBuffer {
    uint8_t *bytes;
    size_t length;
} LouppeXMPBuffer;

typedef enum LouppeXMPDecision {
    LouppeXMPDecisionUndecided = 0,
    LouppeXMPDecisionYes = 1,
    LouppeXMPDecisionNo = 2
} LouppeXMPDecision;

typedef enum LouppeXMPProfile {
    LouppeXMPProfileUniversal = 0,
    LouppeXMPProfileLightroomClassic = 1,
    LouppeXMPProfileBridge = 2,
    LouppeXMPProfileCaptureOne = 3,
    LouppeXMPProfileDarktable = 4
} LouppeXMPProfile;

typedef struct LouppeXMPMetadata {
    // Zero serializes the XMP-defined Unrated value. Other valid values are
    // one through five.
    int32_t stars;
    // Null means that xmp:Label should be absent. Non-null values must be one
    // of the five exact portable English color names.
    const char *colorLabel;
    LouppeXMPDecision decision;
    LouppeXMPProfile profile;
    uint8_t visibleDecisionKeywords;
    // Normally false. An explicit confirmation UI may set this after
    // explaining that an external/custom xmp:Label will be replaced or
    // removed.
    uint8_t allowExternalLabelRemoval;
} LouppeXMPMetadata;

typedef enum LouppeXMPStatus {
    LouppeXMPStatusOK = 0,
    LouppeXMPStatusInvalidArgument = 1,
    LouppeXMPStatusInitializationFailed = 2,
    LouppeXMPStatusParseFailed = 3,
    LouppeXMPStatusSerializationFailed = 4,
    LouppeXMPStatusVerificationFailed = 5,
    LouppeXMPStatusPropertyMissing = 6,
    LouppeXMPStatusOwnershipConflict = 7
} LouppeXMPStatus;

typedef enum LouppeXMPChangeMask {
    LouppeXMPChangeNone = 0,
    LouppeXMPChangeStars = 1 << 0,
    LouppeXMPChangeColor = 1 << 1,
    LouppeXMPChangeFlag = 1 << 2,
    LouppeXMPChangeKeywords = 1 << 3
} LouppeXMPChangeMask;

// Retains and initializes the production XMPCore runtime without parsing or
// touching any file. The app calls this once at startup so a disconnected
// Phase-5 core is not removed by release dead stripping before Phase 6.
LouppeXMPStatus LouppeXMPInitialize(char **errorMessage);

// Parses and serializes a packet without changing its metadata.
LouppeXMPStatus LouppeXMPRoundTrip(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPBuffer *output,
    char **errorMessage
);

// Merges the typed, profile-specific field set. A zero-length input creates a
// new packet. Unknown namespaces, arrays, qualifiers, and edit settings remain
// owned by XMPCore and are preserved semantically.
LouppeXMPStatus LouppeXMPMerge(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPMetadata metadata,
    LouppeXMPBuffer *output,
    char **errorMessage
);

// Verifies the complete field set Louppe owns for this mapping after a packet
// has been serialized or committed to disk.
LouppeXMPStatus LouppeXMPVerify(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPMetadata metadata,
    char **errorMessage
);

// Reads one semantic property through XMPCore. Tests and preflight use this
// instead of depending on a particular XML spelling or namespace prefix.
LouppeXMPStatus LouppeXMPReadProperty(
    const uint8_t *inputBytes,
    size_t inputLength,
    const char *namespaceURI,
    const char *propertyPath,
    char **propertyValue,
    char **errorMessage
);

// Reports which existing, non-empty Louppe-owned portable values would be
// changed by a merge. Missing values that will merely be added are not
// warnings. The returned bits are LouppeXMPChangeMask values.
LouppeXMPStatus LouppeXMPInspectChanges(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPMetadata metadata,
    uint32_t *changeMask,
    char **errorMessage
);

void LouppeXMPFreeBuffer(LouppeXMPBuffer buffer);
void LouppeXMPFreeString(char *string);

#ifdef __cplusplus
}
#endif

#endif
