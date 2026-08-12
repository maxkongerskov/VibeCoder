#!/usr/bin/env bash
# Oracle for 010-notes-app. Pass if: builds, has split nav, list of notes, TextEditor, new-note action.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
cd "$WORK" || { echo "no workdir"; exit 2; }
[[ -f Package.swift ]] || { echo "FAIL: no Package.swift"; exit 1; }
if ! swift build 2> .build-stderr.log; then echo "FAIL: swift build error"; tail -20 .build-stderr.log; exit 1; fi

src="$(find . -name '*.swift' -not -path './.build/*' -exec cat {} +)"
check() { if ! echo "$src" | grep -qE "$2"; then echo "FAIL: missing $1"; exit 1; fi; }

check 'split-view layout'              'NavigationSplitView|HSplitView|NavigationView'
check 'list/ForEach of notes'          'List|ForEach'
check 'TextEditor for note body'       'TextEditor'
check 'notes array state'              '@State[^=]*\[[^]]*(Note|Item)|@StateObject|@ObservedObject'
check 'new-note action'                '"New"|append|\.add|Button.*Note'
check 'selection binding'              'selection:|@State[^=]*selected|@State[^=]*[A-Za-z]*ID'

echo "PASS"
exit 0
