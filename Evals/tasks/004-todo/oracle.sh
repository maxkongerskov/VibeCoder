#!/usr/bin/env bash
# Oracle for 004-todo. Pass if: builds, has list/array state, TextField, add+delete.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
cd "$WORK" || { echo "no workdir"; exit 2; }
[[ -f Package.swift ]] || { echo "FAIL: no Package.swift"; exit 1; }
if ! swift build 2> .build-stderr.log; then echo "FAIL: swift build error"; tail -20 .build-stderr.log; exit 1; fi

src="$(find . -name '*.swift' -not -path './.build/*' -exec cat {} +)"
check() { if ! echo "$src" | grep -qE "$2"; then echo "FAIL: missing $1"; exit 1; fi; }

check 'TextField for input'           'TextField'
check 'list/ForEach over items'       'List|ForEach'
check '@State array of todos'         '@State[^=]*\[[^]]*(String|Todo|Item|Task)'
check 'append/add action'             '\.append\(|\+\s*=\s*\[|onSubmit'
check 'remove/delete action'          'remove|removeAll|onDelete|\.filter'

echo "PASS"
exit 0
