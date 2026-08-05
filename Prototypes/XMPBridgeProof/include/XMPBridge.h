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

typedef struct LouppeXMPMetadata {
    int32_t stars;
    const char *colorLabel;
    const char *decision;
} LouppeXMPMetadata;

typedef enum LouppeXMPStatus {
    LouppeXMPStatusOK = 0,
    LouppeXMPStatusInvalidArgument = 1,
    LouppeXMPStatusInitializationFailed = 2,
    LouppeXMPStatusParseFailed = 3,
    LouppeXMPStatusSerializationFailed = 4,
    LouppeXMPStatusVerificationFailed = 5,
    LouppeXMPStatusPropertyMissing = 6
} LouppeXMPStatus;

// Parses and serializes a packet without changing its metadata. This is used
// by the isolation proof to verify that XMPCore retains foreign fields.
LouppeXMPStatus LouppeXMPRoundTrip(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPBuffer *output,
    char **errorMessage
);

// Applies the small typed field set needed by the bridge proof. Production
// profile and ownership rules deliberately remain outside this Phase-0 API.
LouppeXMPStatus LouppeXMPMerge(
    const uint8_t *inputBytes,
    size_t inputLength,
    LouppeXMPMetadata metadata,
    LouppeXMPBuffer *output,
    char **errorMessage
);

// Reads one property through XMPCore so the Swift proof can compare semantic
// values rather than relying only on serialized XML spelling or layout.
LouppeXMPStatus LouppeXMPReadProperty(
    const uint8_t *inputBytes,
    size_t inputLength,
    const char *namespaceURI,
    const char *propertyPath,
    char **propertyValue,
    char **errorMessage
);

void LouppeXMPFreeBuffer(LouppeXMPBuffer buffer);
void LouppeXMPFreeString(char *string);

#ifdef __cplusplus
}
#endif

#endif
