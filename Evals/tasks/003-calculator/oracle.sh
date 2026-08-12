#!/usr/bin/env bash
# Oracle for 003-calculator.
# Pass if: builds, source has =, +, -, *, / buttons or cases, and a clear/AC.
set -u
WORK="${1:?usage: oracle.sh <workdir>}"
cd "$WORK" || { echo "no workdir"; exit 2; }

[[ -f Package.swift ]] || { echo "FAIL: no Package.swift"; exit 1; }

if ! swift build 2> .build-stderr.log; then
  echo "FAIL: swift build error"
  tail -20 .build-stderr.log
  exit 1
fi

# Must reference all four operators in some form (as button labels OR as enum cases).
src="$(find . -name '*.swift' -not -path './.build/*' -exec cat {} +)"

check() {
  local label="$1"; shift
  if ! echo "$src" | grep -qE "$1"; then
    echo "FAIL: missing $label"
    exit 1
  fi
}

check '"=" button or equals case'   '"="|\.equals|case equals'
check 'addition (+)'                 '"\+"|\.add|case add|case plus'
check 'subtraction (-)'              '"-"|"−"|\.subtract|case subtract|case minus'
check 'multiplication (×|*)'         '"×"|"\*"|\.multiply|case multiply|case times'
check 'division (÷|/)'               '"÷"|"/"|\.divide|case divide'
check 'clear (C/AC)'                 '"C"|"AC"|\.clear|case clear'

echo "PASS"
exit 0
