#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

mkdir -p .build/performance-checks/module-cache

swiftc \
    -sdk "$SDK" \
    -module-cache-path .build/performance-checks/module-cache \
    -parse-as-library \
    Sources/Louppe/Models.swift \
    Sources/Louppe/AppDateFormat.swift \
    Sources/Louppe/FolderScanner.swift \
    Sources/Louppe/MetadataExtractor.swift \
    Sources/Louppe/ImagePipeline.swift \
    Sources/Louppe/CleanUpWorker.swift \
    Sources/Louppe/SessionPersistence.swift \
    Tests/PerformanceChecks/main.swift \
    -o .build/performance-checks/LouppePerformanceChecks

.build/performance-checks/LouppePerformanceChecks
