#!/bin/bash
# Build the headless test harness (p215cli). Same engine as the app, no GUI.
set -euo pipefail
cd "$(dirname "$0")"

SDK="${SDK:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
mkdir -p build

swiftc -sdk "$SDK" -target "${TARGET:-arm64-apple-macos14.0}" -O \
    -framework AppKit -framework Vision -framework CoreImage \
    -framework ImageIO -framework CoreText -framework UniformTypeIdentifiers \
    Sources/Tunnel.swift Sources/Models.swift Sources/ImagePipeline.swift \
    Sources/Export.swift Sources/ScanEngine.swift Sources/Orientation.swift Sources/SaneBackend.swift Sources/CLI/main.swift \
    -o build/p215cli

echo "built build/p215cli"
