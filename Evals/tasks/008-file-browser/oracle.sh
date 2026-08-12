#!/usr/bin/env bash
# Oracle for 008-file-browser. Pass if: builds, uses FileManager, references Downloads, lists items.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
cd "$WORK" || { echo "no workdir"; exit 2; }
[[ -f Package.swift ]] || { echo "FAIL: no Package.swift"; exit 1; }
if ! swift build 2> .build-stderr.log; then echo "FAIL: swift build error"; tail -20 .build-stderr.log; exit 1; fi

src="$(find . -name '*.swift' -not -path './.build/*' -exec cat {} +)"
check() { if ! echo "$src" | grep -qE "$2"; then echo "FAIL: missing $1"; exit 1; fi; }

check 'FileManager usage'         'FileManager\.default|FileManager\(\)'
check 'Downloads directory ref'   '\.downloadsDirectory|"Downloads"|/Downloads'
check 'list rendering'            'List|ForEach'
check 'file size attribute'       'fileSize|\.size|attributesOfItem|FileAttributeKey'

echo "PASS"
exit 0
