#!/bin/bash
# Opens the built app in test mode and checks the things that have broken before:
#   - the window never stretches because of long text, - tabs/groups/split/workspaces survive a stress run (no crash report),
#   - quitting is quick, - features still work (star, tint colour, page watch, PDF viewer, picture in picture).
# Usage: scripts/smoke_test.sh [path/to/Pane.app]   (exit code 1 when something fails)
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Pane.app}/Contents/MacOS/Pane"
[ -x "$APP" ] || { echo "no app at $APP"; exit 2; }
OUT=$(mktemp -d); FAIL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=1; }

# Test pages on a local server.
python3 -m http.server 8765 -d Tests/site >/dev/null 2>&1 & SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$OUT"' EXIT
sleep 1

run() { # name seconds env...
  local name=$1 delay=$2; shift 2
  rm -rf "$OUT/support"; mkdir -p "$OUT/support"
  env "$@" PANE_ONSCREEN_TEST=1 PANE_ONSCREEN_FRONT=1 PANE_SUPPORT_DIR="$OUT/support" PANE_SNAPSHOT="$OUT/$name" PANE_SNAPSHOT_DELAY=$delay PANE_DEBUG_NO_NOTIFY=1 "$APP" >"$OUT/$name.log" 2>&1
}
STAMP=$(mktemp); sleep 1

echo "Window width with absurdly long text"
run long 6 PANE_DEBUG_LONG=addr,status,title,toast,tabs,group PANE_DEBUG_LAYOUT=1
W=$(head -1 "$OUT/long-layout.txt" | sed -E 's/.*frame=\([0-9.-]+, [0-9.-]+, ([0-9.]+),.*/\1/')
[ "${W%.*}" = "1280" ] && pass "window stayed 1280 wide" || fail "window grew to ${W:-?}"

echo "Stress: tabs, groups, sleep, split view, workspaces, assistant panel"
run stress 60 PANE_DEBUG_STRESS_ALL=3
grep -q survived "$OUT/stress-stress.txt" 2>/dev/null && pass "survived 3 rounds" || fail "stress run did not finish"
grep -q "tabs=1 live=1" "$OUT/stress-stress.txt" 2>/dev/null && pass "no leaked pages" || fail "pages leaked"

echo "Sidebar stress: random moves, groups, pins, sleeps, closes"
run sidebar 60 PANE_DEBUG_SIDEBAR=250
grep -q "sidebar survived" "$OUT/sidebar-sidebar.txt" 2>/dev/null && pass "sidebar survived 250 random operations" || fail "sidebar stress did not finish"

echo "Features"
run features 30 PANE_DEBUG_FEATURES=1
F="$OUT/features-features.txt"
grep -q "bookmarked=true" "$F" 2>/dev/null && pass "bookmark + star pulse" || fail "bookmark"
grep -q "history snippet: ad:" "$F" 2>/dev/null && pass "page text remembered for search" || fail "page text snippet"
grep -q "mhtml: ok" "$F" 2>/dev/null && pass "save page as one file (MHTML)" || fail "save page"
grep -q "h=28" "$F" 2>/dev/null && pass "sidebar tint colour" || fail "tint colour"
grep -q "watch fired for: ads page" "$F" 2>/dev/null && pass "page watch" || fail "page watch"
run pdf 14 PANE_DEBUG_PDF=1
grep -q "overlay shown: true" "$OUT/pdf-pdf.txt" 2>/dev/null && pass "PDF viewer" || fail "PDF viewer"
run pip 12 PANE_DEBUG_PIP=1
grep -q "opened pip=true" "$OUT/pip-pip.txt" 2>/dev/null && pass "picture in picture" || fail "picture in picture"

run ctx 10 PANE_DEBUG_RIGHTCLICK=1 PANE_DEBUG_CONTEXT_LOG="$OUT/ctx.txt"
grep -q "items=" "$OUT/ctx.txt" 2>/dev/null && pass "right-click menu" || fail "right-click menu"
run probe 40 PANE_DEBUG_PROBE=1 PANE_DEBUG_PERMISSIONS=deny
grep -q 'done' "$OUT/probe-probe.txt" 2>/dev/null && ! grep -q TIMEOUT "$OUT/probe-probe.txt" && pass "permission requests answered (camera, location, notifications)" || fail "permission requests hang"
run fs 20 PANE_DEBUG_FULLSCREEN=1
grep -q "containerParentIsHost=true" "$OUT/fs-fullscreen.txt" 2>/dev/null && grep -q "after exit: window=false host=false containerParentIsWebHost=true" "$OUT/fs-fullscreen.txt" 2>/dev/null && pass "HTML fullscreen in and out" || fail "HTML fullscreen"

echo "Quitting"
rm -rf "$OUT/support"; mkdir -p "$OUT/support"
PANE_DEBUG_QUIT=4 PANE_DEBUG_QUIT_FILE="$OUT/quit-start.txt" PANE_OFFSCREEN=1 PANE_SUPPORT_DIR="$OUT/support" PANE_SNAPSHOT="$OUT/q" PANE_SNAPSHOT_DELAY=60 "$APP" >/dev/null 2>&1
END=$(python3 -c "import time;print(time.time())")
T=$(python3 -c "print('%.1f' % ($END-float(open('$OUT/quit-start.txt').read())))" 2>/dev/null || echo 99)
python3 -c "import sys; sys.exit(0 if $T < 2.5 else 1)" && pass "quit took ${T}s" || fail "quit took ${T}s"

echo "Crash reports"
NEW=$(find ~/Library/Logs/DiagnosticReports -newer "$STAMP" -name "Pane-*.ips" 2>/dev/null | wc -l | tr -d ' ')
[ "$NEW" = "0" ] && pass "no crashes" || fail "$NEW new crash report(s)"
rm -f "$STAMP"
[ $FAIL = 0 ] && echo "All good." || echo "FAILED"
exit $FAIL
