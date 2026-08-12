#!/usr/bin/env bash
# Oracle for 002-counter.
# Pass if: builds, has @State counter, has Button, has incrementing action.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
cd "$WORK" || { echo "no workdir"; exit 2; }

[[ -f Package.swift ]] || { echo "FAIL: no Package.swift"; exit 1; }

if ! swift build 2> .build-stderr.log; then
  echo "FAIL: swift build error"
  tail -20 .build-stderr.log
  exit 1
fi

# Must declare a SwiftUI-style mutable counter state.
if ! grep -RIl --include='*.swift' -E '@State[^=]*(count|counter|number|value)[^=]*=\s*0' . > /dev/null 2>&1; then
  if ! grep -RIl --include='*.swift' '@State.*Int' . > /dev/null 2>&1; then
    echo "FAIL: no @State integer counter found"
    exit 1
  fi
fi

# Must have a Button that performs an increment.
if ! grep -RIl --include='*.swift' 'Button' . > /dev/null 2>&1; then
  echo "FAIL: no Button found"
  exit 1
fi

if ! grep -RIE --include='*.swift' '(count|counter|number|value)\s*\+=\s*1|(count|counter|number|value)\s*=\s*(count|counter|number|value)\s*\+\s*1' . > /dev/null 2>&1; then
  echo "FAIL: no increment expression found"
  exit 1
fi

echo "PASS"
exit 0
