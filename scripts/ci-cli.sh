#!/usr/bin/env bash
# CLI launch bar P1: dedicated VibeCoderCLILib filter.
# Not the full package `swift test`. Not eval-runner. Not App tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "==> [ci-cli] swift test --filter VibeCoderCLILib"
swift test --filter VibeCoderCLILib
echo "✓ [ci-cli] VibeCoderCLILib passed"
