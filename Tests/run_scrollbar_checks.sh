#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

mkdir -p .build/scrollbar-checks/module-cache

swiftc \
    -sdk "$SDK" \
    -module-cache-path .build/scrollbar-checks/module-cache \
    -parse-as-library \
    Sources/Louppe/Views/PersistentVerticalScroller.swift \
    Tests/ScrollbarChecks/main.swift \
    -o .build/scrollbar-checks/LouppeScrollbarChecks

.build/scrollbar-checks/LouppeScrollbarChecks
