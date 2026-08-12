#!/usr/bin/env bash
#
# One-shot dev setup. Idempotent.
#
set -euo pipefail

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift toolchain not found. Install Xcode 16+ from the App Store."
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "→ installing xcodegen via Homebrew"
        brew install xcodegen
    else
        echo "Homebrew not found — install XcodeGen manually for app builds."
    fi
fi

if ! command -v xcpretty >/dev/null 2>&1; then
    if command -v gem >/dev/null 2>&1; then
        echo "→ installing xcpretty (optional — prettier xcodebuild logs)"
        sudo gem install xcpretty || true
    fi
fi

echo "✓ setup done. Next: ./scripts/build.sh"
