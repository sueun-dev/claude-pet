#!/bin/bash
# Runs the real menu bar app against throwaway sessions and checks what it shows and does.
# Needs a logged-in GUI session; a second ✦ appears in the menu bar for about 25 seconds.
set -uo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos26" -framework AppKit -framework SwiftUI \
  $(find Sources -name "*.swift" ! -name main.swift) tests/app_checks/main.swift -o "$OUT/app_checks" || exit 1

status=0
for scenario in launch full; do
  echo "== $scenario"
  CLAUDE_PET_HOME="$(mktemp -d "$OUT/home.XXXX")" "$OUT/app_checks" "$scenario" || status=1
done
exit $status
