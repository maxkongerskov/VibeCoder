#!/usr/bin/env bash
# Oracle for 001-hello-world.
# Pass if: Package.swift exists, swift build succeeds, sources mention "Hello".
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
cd "$WORK" || { echo "no workdir"; exit 2; }

[[ -f Package.swift ]] || { echo "FAIL: no Package.swift"; exit 1; }

# Build must succeed.
if ! swift build 2> .build-stderr.log; then
  echo "FAIL: swift build error"
  tail -20 .build-stderr.log
  exit 1
fi

# Source must reference the required text. Cover Sources/, App/, anywhere.
if ! grep -RIl --include='*.swift' 'Hello' . > /dev/null 2>&1; then
  echo "FAIL: no Swift file contains the string 'Hello'"
  exit 1
fi

# Source must look like a SwiftUI app (App protocol or WindowGroup).
if ! grep -RIl --include='*.swift' -E 'WindowGroup|: App\b|@main' . > /dev/null 2>&1; then
  echo "FAIL: no SwiftUI App / WindowGroup found"
  exit 1
fi

echo "PASS"
exit 0
