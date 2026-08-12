#!/usr/bin/env bash
# Oracle for 005-stopwatch. Pass if: builds, has Timer/TimelineView, Start+Stop+Reset.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
cd "$WORK" || { echo "no workdir"; exit 2; }
[[ -f Package.swift ]] || { echo "FAIL: no Package.swift"; exit 1; }
if ! swift build 2> .build-stderr.log; then echo "FAIL: swift build error"; tail -20 .build-stderr.log; exit 1; fi

src="$(find . -name '*.swift' -not -path './.build/*' -exec cat {} +)"
check() { if ! echo "$src" | grep -qE "$2"; then echo "FAIL: missing $1"; exit 1; fi; }

check 'Timer or TimelineView or DispatchSourceTimer'  'Timer\.scheduledTimer|Timer\.publish|TimelineView|DispatchSourceTimer'
check 'Start button'                                  '"Start"|Label\("Start"'
check 'Stop or Pause button'                          '"Stop"|"Pause"'
check 'Reset button'                                  '"Reset"'
check 'elapsed state'                                 '@State[^=]*(elapsed|time|seconds|interval)'

echo "PASS"
exit 0
