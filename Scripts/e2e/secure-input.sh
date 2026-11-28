#!/bin/zsh
# End-to-end test for the status menu's Secure Input row. A test app
# (SecureHolder) turns macOS Secure Input on and keeps it on, like a browser
# that keeps a password field's Secure Input after it loses focus. The menu
# is opened with real clicks and read back through Accessibility.
#
#   Scripts/e2e/secure-input.sh [output-dir] [app]
#
# app defaults to the newest Debug build in build/dd or DerivedData. Needs a
# shell with Accessibility and Screen Recording access (`hid trust`), Secure
# Input off at the start, and the Mac left alone for about a minute. The
# Debug app's defaults are backed up and restored, and a running release
# macToolKit is quit for the run and relaunched after.
#
# Ways the row could fail, each covered below:
#  1. shown while Secure Input is off
#  2. missing while Secure Input is on
#  3. names the wrong app - macOS's holder PID is the frontmost app for a
#     process that turned Secure Input on from the background, so the row
#     must name the stuck app after you switch away from it (the Dia case)
#  4. names nothing when Secure Input was on before macToolKit started
#  5. clicking it does not bring the holder to the front - macOS refuses
#     most activations while Secure Input is on
#  6. stays after every feature that needs key presses is off, or does not
#     come back when one is on again (and a feature off-on-off crashes)
#  7. a toggle row looks selected as soon as the menu opens (it did: the
#     first row became the menu window's first responder)
#  8. the keyboard no longer flips a toggle row (arrow, then Space/Return)
#  9. the app is gone by the end
#
# Writes <output-dir>/report.md (one PASS/FAIL line per check and the menu
# rows seen) plus a screenshot of the menu per scenario, and exits with the
# number of failed checks.

set -u
ROOT=${0:A:h:h:h}
OUT=${1:-${TMPDIR%/}/mactoolkit-secure-input-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/work"
OUT=${OUT:A}
WORK=$OUT/work
REPORT=$OUT/report.md
DOMAIN=com.sunilaleti.mactoolkit.debug
PROCESS="macToolKit Debug"
STARTED=$(date '+%Y-%m-%d %H:%M:%S')
FAILURES=0

APP=${2:-$(ls -td "$ROOT"/build/dd/Build/Products/Debug/"macToolKit Debug.app" \
  ~/Library/Developer/Xcode/DerivedData/macToolKit-*/Build/Products/Debug/"macToolKit Debug.app" 2>/dev/null | head -1)}
[[ -d $APP ]] || { echo "No Debug build found - build the macToolKit scheme in Debug first."; exit 100; }

HID=$WORK/hid
swiftc -O "$ROOT/Scripts/e2e/hid.swift" -o "$HID" 2>/dev/null || exit 100
[[ $($HID trust) == trusted ]] || { echo "This shell needs Accessibility access to post events."; exit 100; }

secure_pid() { ioreg -l -w 0 | sed -n 's/.*"kCGSSessionSecureInputPID"=\([0-9]*\).*/\1/p' | head -1; }
[[ -z $(secure_pid) ]] || { echo "Secure Input is already on (pid $(secure_pid)) - the test needs it off."; exit 100; }

# bundle <name> <bundle-id> <source>: a one-binary app at $WORK/<name>.app.
bundle() {
  mkdir -p "$WORK/$1.app/Contents/MacOS"
  swiftc -O "$ROOT/Scripts/e2e/$3" -o "$WORK/$1.app/Contents/MacOS/$1" 2>/dev/null || exit 100
  cat > "$WORK/$1.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>$1</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
}
HOLDER_ID=com.sunilaleti.e2e.secure-holder
OTHER_ID=com.sunilaleti.e2e.other
bundle SecureHolder $HOLDER_ID secureholder.swift
bundle Other $OTHER_ID testwindow.swift

{
  echo "# macToolKit Secure Input row - E2E report"
  echo
  echo "- Started: $STARTED"
  echo "- Build: \`$APP\`"
  echo "- Commit: $(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet || echo ' (uncommitted changes)')"
  echo "- Menu rows read through Accessibility; \`*\` = highlighted, \` / \` = a line break in the row."
  echo
} > "$REPORT"

section() { echo; echo "== $1"; printf '\n## %s\n\n' "$1" >> "$REPORT"; }

# check <name> <expected> <actual>
check() {
  if [[ $2 == "$3" ]]; then
    echo "PASS  $1"; echo "- PASS - $1" >> "$REPORT"
  else
    FAILURES=$((FAILURES + 1))
    echo "FAIL  $1 (expected '$2', got '$3')"
    echo "- **FAIL** - $1 (expected \`$2\`, got \`$3\`)" >> "$REPORT"
  fi
}

# The frontmost app as the window server sees it.
front() { lsappinfo info -only bundleid "$(lsappinfo front)" | sed -n 's/.*bundleID="\(.*\)"/\1/p'; }
alive() { pgrep -f "macToolKit Debug.app/Contents/MacOS" >/dev/null && echo yes || echo no; }

ITEM=""
menu_state() { $HID menu "$PROCESS"; }
# Clicks only: a key posted while the menu is closed would go to the
# frontmost app.
open_menu() {
  ITEM=$($HID statusitem "$PROCESS")
  $HID click ${ITEM% *} ${ITEM#* }
  for _ in {1..20}; do [[ $(menu_state) != closed ]] && break; sleep 0.1; done
  sleep 0.3
}
close_menu() {
  [[ $(menu_state) != closed ]] && $HID click ${ITEM% *} ${ITEM#* }
  sleep 0.4
}
# rows <name>: the open menu's rows, kept in $WORK/<name>.txt and the
# report, plus a screenshot of the menu as <name>.png.
rows() {
  $HID menuitems "$PROCESS" > "$WORK/$1.txt"
  { echo '```'; cat "$WORK/$1.txt"; echo '```'; } >> "$REPORT"
  local rect=($(menu_state))
  [[ ${#rect} == 4 ]] && screencapture -x -R${rect[1]},${rect[2]},${rect[3]},${rect[4]} "$OUT/$1.png"
}
warning_row() { grep '^.Keyboard shortcuts paused' "$WORK/$1.txt" | cut -c2-; }
highlighted() { grep -c '^\*' "$WORK/$1.txt"; }
# click_row <title>: a click in the middle of an open menu row.
click_row() {
  local r=($($HID menurow "$PROCESS" "$1"))
  $HID click $((r[1] + r[3] / 2)) $((r[2] + r[4] / 2))
  sleep 0.5
}
# Most activations are refused while Secure Input is on; a click on a
# window is not. Clicks the right end of Other's window, clear of the
# holder's.
click_other() {
  local f=($($HID frame $OTHER_ID))
  $HID click $((f[1] + f[3] - 60)) $((f[2] + 60))
  sleep 1.2
}
start_holder() { open "$WORK/SecureHolder.app" --args "$@"; sleep 2; }
stop_holder() { pkill -f "$WORK/SecureHolder.app"; sleep 1; }
launch() { open -g "$APP"; sleep 3; }

# MARK: Setup

RELEASE_WAS_RUNNING=$(pgrep -f "/Applications/macToolKit.app/Contents/MacOS" >/dev/null && echo yes || echo no)
[[ $RELEASE_WAS_RUNNING == yes ]] && { osascript -e 'tell application "macToolKit" to quit'; sleep 1.5; }
pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.5
defaults export $DOMAIN "$WORK/defaults-backup.plist" 2>/dev/null || true
FRONT_BEFORE=$(front)

cleanup() {
  close_menu 2>/dev/null
  pkill -f "$WORK/SecureHolder.app" 2>/dev/null
  pkill -f "$WORK/Other.app" 2>/dev/null
  pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.5
  defaults delete $DOMAIN 2>/dev/null
  [[ -f $WORK/defaults-backup.plist ]] && defaults import $DOMAIN "$WORK/defaults-backup.plist"
  [[ $RELEASE_WAS_RUNNING == yes ]] && open -g /Applications/macToolKit.app
  [[ -n $FRONT_BEFORE ]] && osascript -e "tell application id \"$FRONT_BEFORE\" to activate" 2>/dev/null
}
trap cleanup EXIT

# Of the features that need key presses only the switcher is on, so turning
# it off leaves none.
defaults write $DOMAIN hasCompletedOnboarding -bool true
defaults write $DOMAIN windowSwitcherEnabled -bool true
defaults write $DOMAIN rewritelyEnabled -bool false
defaults write $DOMAIN finderCutPasteEnabled -bool false

open "$WORK/Other.app"; sleep 1.5
launch

HELD_BY="Keyboard shortcuts paused, Secure Input is on, probably from SecureHolder. / Click to switch to SecureHolder."
UNKNOWN="Keyboard shortcuts paused, Another app has Secure Input on, / often for a password field."

# MARK: Scenarios

section "Secure Input off: no row, nothing highlighted"
open_menu; rows off; close_menu
check "no Secure Input row" "" "$(warning_row off)"
check "no row highlighted as the menu opens" 0 "$(highlighted off)"

section "Holder in front, then another app clicked (the Dia case)"
start_holder
check "holder in front" $HOLDER_ID "$(front)"
click_other
check "Other in front" $OTHER_ID "$(front)"
open_menu; rows held; close_menu
check "row names the holder" "$HELD_BY" "$(warning_row held)"
check "no row highlighted as the menu opens" 0 "$(highlighted held)"

section "Clicking the row brings the holder to the front"
NL=$'\n'
open_menu; click_row "${HELD_BY// \/ /$NL}"
sleep 0.8
check "menu closed" closed "$(menu_state)"
check "holder in front" $HOLDER_ID "$(front)"

section "Switcher off: no row; on again: row back"
click_other
open_menu
click_row "Window Switcher"; rows switcher-off
check "no row while no keyboard feature is on" "" "$(warning_row switcher-off)"
click_row "Window Switcher"; rows switcher-on
check "row back once the switcher is on" "$HELD_BY" "$(warning_row switcher-on)"
click_row "Window Switcher"; click_row "Window Switcher"; rows switcher-twice
check "switcher on after off-on-off-on" on "$(defaults read $DOMAIN windowSwitcherEnabled | sed 's/1/on/;s/0/off/')"
close_menu
check "app alive after the toggles" yes "$(alive)"

section "Secure Input already on when macToolKit starts"
pkill -f "macToolKit Debug.app/Contents/MacOS"; sleep 1
launch
open_menu; rows before-launch; close_menu
check "row names the holder" "$HELD_BY" "$(warning_row before-launch)"

section "Holder that turned it on from the background"
stop_holder
start_holder --background
click_other
open_menu; rows background; close_menu
# macOS names the frontmost app here, not the holder - the reason the row
# says "probably". Recorded, not judged; the row must still show.
echo "- Row text: \`$(warning_row background)\`" >> "$REPORT"
check "row shows" "Keyboard shortcuts paused" "$(warning_row background | cut -d, -f1)"
stop_holder

section "Secure Input off again: row gone, keyboard flips a toggle"
check "Secure Input off" "" "$(secure_pid)"
open_menu; rows after; check "no Secure Input row" "" "$(warning_row after)"
# Down highlights the first row that can be chosen: the switcher.
$HID key 125; sleep 0.3; rows keyboard
check "Down highlights Window Switcher" "*Window Switcher" "$(grep '^\*' "$WORK/keyboard.txt")"
$HID key 49; sleep 0.6
check "Space flips it off and closes the menu" "0 closed" "$(defaults read $DOMAIN windowSwitcherEnabled) $(menu_state)"
open_menu; $HID key 125; sleep 0.3; $HID key 36; sleep 0.6
check "Return flips it on and closes the menu" "1 closed" "$(defaults read $DOMAIN windowSwitcherEnabled) $(menu_state)"

section "End"
check "app alive" yes "$(alive)"

# MARK: Report

{
  echo
  echo "Result: $FAILURES failed check(s)."
} >> "$REPORT"

echo; echo "Report: $REPORT"; echo "$FAILURES failed check(s)."
exit $FAILURES
