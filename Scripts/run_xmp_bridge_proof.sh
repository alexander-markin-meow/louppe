#!/bin/zsh
set -euo pipefail

readonly expected_xmp_revision="7093513bd3caaad29da01db0f275d88a39d6bcc2"
readonly expected_expat_revision="654d2de0da85662fcc7644a7acd7c2dd2cfb21f0"

readonly script_directory="${0:A:h}"
readonly repository_root="${script_directory:h}"
readonly proof_directory="${repository_root}/Prototypes/XMPBridgeProof"
if [[ -n "${SDKROOT:-}" ]]; then
    readonly macos_sdk="${SDKROOT:A}"
elif [[ -d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk ]]; then
    readonly macos_sdk="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
    readonly macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

if (( $# != 2 )); then
    print -u2 "Usage: $0 /path/to/XMP-Toolkit-SDK /path/to/libexpat"
    print -u2 "The checkouts must match the revisions recorded in Docs/XMP_TOOLKIT_INTEGRATION.md."
    exit 64
fi

readonly xmp_toolkit_directory="${1:A}"
readonly expat_checkout_directory="${2:A}"

if [[ ! -d "${xmp_toolkit_directory}/XMPCore/source" || ! -d "${xmp_toolkit_directory}/public/include" ]]; then
    print -u2 "The first argument is not an Adobe XMP Toolkit SDK checkout."
    exit 66
fi
if [[ ! -d "${expat_checkout_directory}/expat/lib" ]]; then
    print -u2 "The second argument is not a libexpat checkout."
    exit 66
fi
if [[ ! -d "${macos_sdk}" ]]; then
    print -u2 "The current macOS SDK could not be found at ${macos_sdk}."
    exit 69
fi

readonly actual_xmp_revision="$(git -C "${xmp_toolkit_directory}" rev-parse HEAD)"
readonly actual_expat_revision="$(git -C "${expat_checkout_directory}" rev-parse HEAD)"

if [[ "${actual_xmp_revision}" != "${expected_xmp_revision}" ]]; then
    print -u2 "XMPCore revision mismatch: expected ${expected_xmp_revision}, got ${actual_xmp_revision}."
    exit 65
fi
if [[ "${actual_expat_revision}" != "${expected_expat_revision}" ]]; then
    print -u2 "Expat revision mismatch: expected ${expected_expat_revision}, got ${actual_expat_revision}."
    exit 65
fi

readonly proof_build_directory="$(mktemp -d /private/tmp/louppe-xmp-bridge-proof.XXXXXX)"
readonly object_directory="${proof_build_directory}/objects"
mkdir -p "${object_directory}"
mkdir -p "${proof_build_directory}/include-shim/third-party/expat"
ln -s \
    "${expat_checkout_directory}/expat/lib" \
    "${proof_build_directory}/include-shim/third-party/expat/lib"

readonly -a common_defines=(
    -DMAC_ENV=1
    -DXMP_64=1
    -DXMP_StaticBuild=1
    -DBUILDING_XMPCORE_LIB=1
    -DBUILDING_XMPCORE_AS_STATIC=1
    -DENABLE_CPP_DOM_MODEL=0
    -DXMP_COMPONENT_INT_NAMESPACE=AdobeXMPCore_Int
    -DBanAllEntityUsage=1
)
readonly -a common_includes=(
    -I"${proof_build_directory}/include-shim"
    -I"${xmp_toolkit_directory}"
    -I"${xmp_toolkit_directory}/public/include"
    -I"${xmp_toolkit_directory}/XMPCore/resource/mac"
    -I"${expat_checkout_directory}/expat/lib"
    -I"${proof_directory}/include"
)
readonly -a xmp_sources=(
    "${xmp_toolkit_directory}/XMPCore/source/WXMPIterator.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/WXMPMeta.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/WXMPUtils.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/CoreObjectFactoryImpl.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPIterator.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPIterator2.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPMeta-GetSet.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPMeta-Parse.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPMeta-Serialize.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPMeta.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPMeta2-GetSet.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPUtils-FileInfo.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPUtils.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPUtils2.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/ExpatAdapter.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/ParseRDF.cpp"
    "${xmp_toolkit_directory}/XMPCore/source/XMPCore_Impl.cpp"
    "${xmp_toolkit_directory}/source/UnicodeConversions.cpp"
    "${xmp_toolkit_directory}/source/XML_Node.cpp"
    "${xmp_toolkit_directory}/source/XMP_LibUtils.cpp"
    "${xmp_toolkit_directory}/third-party/zuid/interfaces/MD5.cpp"
)
readonly -a expat_sources=(
    "${expat_checkout_directory}/expat/lib/xmlparse.c"
    "${expat_checkout_directory}/expat/lib/xmlrole.c"
    "${expat_checkout_directory}/expat/lib/xmltok.c"
)

integer object_index=0
typeset -a objects=()

for source_file in "${expat_sources[@]}"; do
    object_index=$(( object_index + 1 ))
    object_file="${object_directory}/${object_index}.o"
    xcrun clang \
        -std=c11 \
        -O1 \
        -isysroot "${macos_sdk}" \
        "${common_includes[@]}" \
        -c "${source_file}" \
        -o "${object_file}"
    objects+=("${object_file}")
done

for source_file in "${xmp_sources[@]}"; do
    object_index=$(( object_index + 1 ))
    object_file="${object_directory}/${object_index}.o"
    xcrun clang++ \
        -std=c++17 \
        -O1 \
        -isysroot "${macos_sdk}" \
        "${common_defines[@]}" \
        "${common_includes[@]}" \
        -Wno-deprecated-declarations \
        -Wno-register \
        -c "${source_file}" \
        -o "${object_file}"
    objects+=("${object_file}")
done

object_index=$(( object_index + 1 ))
bridge_object="${object_directory}/${object_index}.o"
xcrun clang++ \
    -std=c++17 \
    -O1 \
    -isysroot "${macos_sdk}" \
    "${common_defines[@]}" \
    "${common_includes[@]}" \
    -Wno-deprecated-declarations \
    -Wno-register \
    -c "${proof_directory}/XMPBridge.mm" \
    -o "${bridge_object}"
objects+=("${bridge_object}")

readonly bridge_library="${proof_build_directory}/libLouppeXMPBridge.a"
xcrun libtool -static -o "${bridge_library}" "${objects[@]}"

readonly proof_runner="${proof_build_directory}/XMPBridgeProofRunner"
xcrun swiftc \
    -swift-version 6 \
    -sdk "${macos_sdk}" \
    -module-cache-path "${proof_build_directory}/module-cache" \
    -I "${proof_directory}" \
    "${proof_directory}/ProofRunner.swift" \
    -L "${proof_build_directory}" \
    -lLouppeXMPBridge \
    -Xlinker -lc++ \
    -framework CoreFoundation \
    -framework CoreServices \
    -o "${proof_runner}"

"${proof_runner}" "${proof_directory}/Fixtures"
print "Proof build retained at ${proof_build_directory}"
