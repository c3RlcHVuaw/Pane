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
  rm -rf "$OUT/support"; mkdir -p "$OUT/support/Extensions"; cp -R Tests/site/ext "$OUT/support/Extensions/ext"
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
grep -q "sidebar survived.*mismatches=0" "$OUT/sidebar-sidebar.txt" 2>/dev/null && pass "sidebar survived 250 random operations" || fail "sidebar stress did not finish"

echo "Private windows opening and closing"
run windows 25 PANE_DEBUG_WINDOWS=8
grep -q "windows left=1 survived" "$OUT/windows-windows.txt" 2>/dev/null && pass "8 private windows opened and closed" || fail "window open/close cycle"

RSS=$(grep -o 'rss=[0-9]*->[0-9]*' "$OUT/sidebar-sidebar.txt" 2>/dev/null | head -1)
GROWTH=$(echo "$RSS" | sed -E 's/rss=([0-9]+)->([0-9]+)/\2 - \1/' | bc 2>/dev/null || echo 9999)
[ "${GROWTH:-9999}" -lt 400 ] && pass "memory growth in the sidebar stress ($RSS MB)" || fail "memory grew too much ($RSS)"

echo "AutoFill and spell check"
run autofill 12 PANE_DEBUG_AUTOFILL=1
grep -q "n=Anna Smith|e=anna@example.com" "$OUT/autofill-autofill.txt" 2>/dev/null && pass "address form filled" || fail "autofill"
grep -q "suggested=true" "$OUT/autofill-autofill.txt" 2>/dev/null && pass "suggestion list appears under the field" || fail "autofill suggestion list"
grep -q "cc=4242424242424242|ccn=ANNA SMITH|mm=03|yy=2029" "$OUT/autofill-autofill.txt" 2>/dev/null && pass "card form filled" || fail "card autofill"
run spell 12 PANE_DEBUG_X=45 PANE_DEBUG_RIGHTCLICK=spell PANE_DEBUG_CONTEXT_LOG="$OUT/spell.txt"
grep -q "misspelled=превет" "$OUT/spell.txt" 2>/dev/null && pass "Russian spell check suggests corrections" || fail "Russian spell check"

echo "Extension popup"
run extpopup 12 PANE_DEBUG_EXTPOPUP=1
grep -q "button=true popup=true" "$OUT/extpopup-extpopup.txt" 2>/dev/null && pass "extension toolbar button opens its popup" || fail "extension popup"

echo "Spelling underline"
run spellul 12 PANE_DEBUG_SPELLUL=1
grep -q "spans=[1-9]" "$OUT/spellul-spellul.txt" 2>/dev/null && pass "misspelled words are underlined" || fail "spelling underline"

echo "Back after the first page"
run back 14 PANE_DEBUG_BACK=1
grep -q "canGoBack=true afterBack=http://127.0.0.1:8765/form.html" "$OUT/back-back.txt" 2>/dev/null && pass "Back returns to the previous page" || fail "Back after a new tab's first page"

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
