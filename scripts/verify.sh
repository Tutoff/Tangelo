#!/bin/bash
# Runs every automated check: release builds, deep QA of all conversions, the WebP encoder self-test,
# scripted ring drags, the tool-window leak test and a memory profile. Prints a short summary.
set -uo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tangelo-verify.XXXX")
LOG="$WORK/logs"; mkdir -p "$LOG"
status=0
step() { printf "\n› %s\n" "$1"; }

step "Building (release)"
swift build -c release --product tangelo-cli >"$LOG/build-cli.txt" 2>&1 || { echo "  CLI build failed (see $LOG/build-cli.txt)"; exit 1; }
swift build -c release --product Tangelo >"$LOG/build-app.txt" 2>&1 || { echo "  App build failed (see $LOG/build-app.txt)"; exit 1; }
echo "  ok"
CLI=.build/release/tangelo-cli
APP=.build/release/Tangelo

step "WebP encoder round-trips"
if $CLI selftest-webp >"$LOG/webp.txt" 2>&1; then echo "  ok ($(grep -c '^ok' "$LOG/webp.txt") images pixel-exact)"; else echo "  FAILED"; status=1; fi

step "Deep QA of every action (takes a few minutes)"
$CLI qa "$WORK/qa" >"$LOG/qa.txt" 2>&1 || status=1
grep -E "^QA:" "$LOG/qa.txt" | sed 's/^/  /'
grep -E "^  ✗" "$LOG/qa.txt" | head -20
FIX="$WORK/qa/inputs"

step "Ring: scripted drags"
$APP --self-test "$FIX" >"$LOG/ring.txt" 2>&1 || status=1
echo "  $(grep -c '^ok' "$LOG/ring.txt") passed, $(grep -c '^FAIL' "$LOG/ring.txt") failed"
grep -E "^FAIL" "$LOG/ring.txt" | head -10 | sed 's/^/  /'

step "Tool windows: leak test"
$APP --leak-test "$FIX" >"$LOG/leaks.txt" 2>&1 || status=1
grep -E "heap after|leaked" "$LOG/leaks.txt" | sed 's/^/  /'

step "Memory profile"
$APP --mem-test "$FIX" >"$LOG/mem.txt" 2>&1 || status=1
grep -E " MB" "$LOG/mem.txt" | sed 's/^/  /'

echo
[ $status -eq 0 ] && echo "All checks passed. Logs: $LOG" || echo "Some checks failed. Logs: $LOG"
exit $status
