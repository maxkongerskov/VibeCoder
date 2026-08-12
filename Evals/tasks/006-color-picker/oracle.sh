#!/usr/bin/env bash
# Oracle for 006-color-picker. Pass if: builds, has 3 Sliders, Color from r/g/b state.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
cd "$WORK" || { echo "no workdir"; exit 2; }
[[ -f Package.swift ]] || { echo "FAIL: no Package.swift"; exit 1; }
if ! swift build 2> .build-stderr.log; then echo "FAIL: swift build error"; tail -20 .build-stderr.log; exit 1; fi

src="$(find . -name '*.swift' -not -path './.build/*' -exec cat {} +)"

slider_count=$(echo "$src" | grep -oE 'Slider\(' | wc -l | tr -d ' ')
if [[ $slider_count -lt 3 ]]; then
  echo "FAIL: expected 3 Slider() calls, found $slider_count"
  exit 1
fi

if ! echo "$src" | grep -qE 'Color\(red:|Color\(\.sRGB|\.background\(Color'; then
  echo "FAIL: no Color construction from RGB"
  exit 1
fi

if ! echo "$src" | grep -qE '@State[^=]*(red|green|blue|r\s*[:=]|g\s*[:=]|b\s*[:=])'; then
  echo "FAIL: no @State for r/g/b components"
  exit 1
fi

echo "PASS"
exit 0
