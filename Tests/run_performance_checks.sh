#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

mkdir -p .build/performance-checks/module-cache

swiftc \
    -sdk "$SDK" \
    -module-cache-path .build/performance-checks/module-cache \
    -D LOUPPE_TESTING \
    -parse-as-library \
    Sources/Louppe/Models.swift \
    Sources/Louppe/PreparedSessionIndex.swift \
    Sources/Louppe/SelectionState.swift \
    Sources/Louppe/AppDateFormat.swift \
    Sources/Louppe/FolderScanner.swift \
    Sources/Louppe/MetadataExtractor.swift \
    Sources/Louppe/VideoSupport.swift \
    Sources/Louppe/ImagePipeline.swift \
    Sources/Louppe/HistogramPipeline.swift \
    Sources/Louppe/HighResolutionImagePipeline.swift \
    Sources/Louppe/ZoomViewport.swift \
    Sources/Louppe/VideoPlaybackController.swift \
    Sources/Louppe/DurableFileIO.swift \
    Sources/Louppe/FileOperationJournal.swift \
    Sources/Louppe/CleanUpWorker.swift \
    Sources/Louppe/ExportWorker.swift \
    Sources/Louppe/ExportDestinationValidator.swift \
    Sources/Louppe/SessionPersistence.swift \
    Tests/PerformanceChecks/XMPPublicationStubs.swift \
    Sources/Louppe/SessionStore.swift \
    Tests/PerformanceChecks/main.swift \
    -o .build/performance-checks/LouppePerformanceChecks

.build/performance-checks/LouppePerformanceChecks
