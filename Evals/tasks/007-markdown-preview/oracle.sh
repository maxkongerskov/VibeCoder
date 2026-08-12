#!/usr/bin/env bash
# Oracle for 007-markdown-preview. Pass if: builds, has split layout, TextEditor, markdown rendering.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
cd "$WORK" || { echo "no workdir"; exit 2; }
[[ -f Package.swift ]] || { echo "FAIL: no Package.swift"; exit 1; }
if ! swift build 2> .build-stderr.log; then echo "FAIL: swift build error"; tail -20 .build-stderr.log; exit 1; fi

src="$(find . -name '*.swift' -not -path './.build/*' -exec cat {} +)"
check() { if ! echo "$src" | grep -qE "$2"; then echo "FAIL: missing $1"; exit 1; fi; }

check 'split layout (HSplitView or HStack)'  'HSplitView|HStack'
check 'TextEditor for input'                  'TextEditor'
check 'markdown rendering'                    'AttributedString.*markdown|init\(markdown:|try AttributedString|Text\(\.init\('

echo "PASS"
exit 0
