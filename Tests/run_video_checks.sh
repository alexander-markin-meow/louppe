#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p .build/video-checks/module-cache

swiftc \
    -sdk "$SDK" \
    -module-cache-path .build/video-checks/module-cache \
    -parse-as-library \
    Sources/Louppe/Models.swift \
    Sources/Louppe/AppDateFormat.swift \
    Sources/Louppe/FolderScanner.swift \
    Sources/Louppe/MetadataExtractor.swift \
    Sources/Louppe/VideoSupport.swift \
    Sources/Louppe/ImagePipeline.swift \
    Sources/Louppe/VideoPlaybackController.swift \
    Tests/VideoChecks/main.swift \
    -o .build/video-checks/LouppeVideoChecks

.build/video-checks/LouppeVideoChecks
