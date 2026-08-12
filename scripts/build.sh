#!/usr/bin/env bash
#
# Build everything: core library, CLI, and (if XcodeGen is installed) the app.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ swift build (AgentCore + MLXBackend + Harness)"
swift build

echo "→ swift test (core tests)"
swift test --quiet

if command -v xcodegen >/dev/null 2>&1; then
    echo "→ xcodegen generate (App)"
    (cd App && xcodegen generate)
    echo "→ xcodebuild (App, debug)"
    xcodebuild -project App/VibeCoder.xcodeproj \
        -scheme VibeCoder \
        -configuration Debug \
        -destination 'platform=macOS' \
        build | xcpretty || true
else
    echo "→ xcodegen not found — skipping app build."
    echo "  brew install xcodegen, then re-run."
fi

echo "✓ done. (CLI removed — focusing on the app)"
