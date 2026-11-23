#!/bin/zsh
# End-to-end test for the status menu (macToolKit/StatusMenu.swift): feature
# rows switched with the pointer, the keyboard, a script and VoiceOver's
# press, and the highlight the user actually sees. Real HID events go to the
# Debug build's menu; results are read back from its defaults,
# Accessibility and screen pixels.
#
#   Scripts/e2e/status-menu.sh [output-dir]
#
# Needs: a Debug build (xcodebuild ... -configuration Debug build) and a
# shell with Accessibility and Screen Recording access (`hid trust`). It
# moves the pointer and types into the menu for about two minutes - leave
# the Mac alone meanwhile. Keys are sent only while the menu is open: with it
# closed they would reach the frontmost app (under Claude, Escape stops the
# run). Only Side Buttons is switched. The Debug app's defaults are backed up
# and restored, and a running release macToolKit is quit for the run and
# relaunched after.
#
# Writes <output-dir>/report.md (one PASS/FAIL line per check, with a capture
# of the menu at the key moments) and exits with the number of failed checks.

set -u
ROOT=${0:A:h:h:h}
OUT=${1:-${TMPDIR%/}/mactoolkit-status-menu-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/work"
OUT=${OUT:A}
WORK=$OUT/work
REPORT=$OUT/report.md
DOMAIN=com.sunilaleti.mactoolkit.debug
PROCESS="macToolKit Debug"
FEATURE="Side Buttons"; FEATURE_KEY=sideButtonsEnabled
# The rows either side of it, which must never change.
ABOVE="Scroll Reverser"; BELOW="Rewritely"; BELOW_KEY=rewritelyEnabled
STARTED=$(date '+%Y-%m-%d %H:%M:%S')
FAILURES=0

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/macToolKit-*/Build/Products/Debug/"macToolKit Debug.app" 2>/dev/null | head -1)
[[ -n $APP ]] || { echo "No Debug build found - build the macToolKit scheme in Debug first."; exit 100; }

HID=$WORK/hid
swiftc -O "$ROOT/Scripts/e2e/hid.swift" -o "$HID" || exit 100
[[ $($HID trust) == trusted ]] || { echo "This shell needs Accessibility access to post events."; exit 100; }

# MARK: Helpers

{
  echo "# macToolKit status menu - E2E report"
  echo
  echo "- Started: $STARTED"
  echo "- Build: \`$APP\`"
  echo "- Commit: $(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" status --porcelain | grep -q . && echo ' (uncommitted changes)')"
  echo
} > "$REPORT"

section() { echo; echo "== $1"; printf '\n## %s\n\n' "$1" >> "$REPORT"; }

# check <name> <expected> <actual>
check() {
  if [[ $2 == "$3" ]]; then
    echo "PASS  $1"; echo "- PASS - $1" >> "$REPORT"
  else
    FAILURES=$((FAILURES + 1))
    screencapture -x "$OUT/fail-$FAILURES.png" 2>/dev/null
    echo "FAIL  $1 (expected '$2', got '$3') - screen: fail-$FAILURES.png"
    echo "- **FAIL** - $1 (expected \`$2\`, got \`$3\`) - screen: \`fail-$FAILURES.png\`" >> "$REPORT"
  fi
}

# capture <name> <caption>: the open menu, linked from the report.
capture() {
  local x y w h
  read x y w h <<< "$($HID menu "$PROCESS")"
  [[ $x == closed ]] && return
  screencapture -x -R$((x - 4)),$((y - 30)),$((w + 8)),$((h + 34)) "$OUT/$1.png"
  echo "  - $2: ![]($1.png)" >> "$REPORT"
}

value() { defaults read $DOMAIN $1 2>/dev/null || echo 0; }
flipped() { echo $((1 - $1)); }
menu_state() { [[ $($HID menu "$PROCESS") == closed ]] && echo closed || echo open; }

launch_app() {
  pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.8
  open -g "$APP"; sleep 3
  read SX SY <<< "$($HID statusitem "$PROCESS")"
}

open_menu() {
  [[ $(menu_state) == open ]] && close_menu
  $HID click $SX $SY; sleep 0.8
}
# A click on the icon, never Escape: see the header.
close_menu() {
  [[ $(menu_state) == open ]] && { $HID click $SX $SY; sleep 0.6; }
}

# row <title>: x y w h selected|- on|off|-
row() { $HID menurow "$PROCESS" "$1"; }
selected() { local r; r=($(row "$1")); echo ${r[5]}; }
checkbox() { local r; r=($(row "$1")); echo ${r[6]}; }

# hover <title>: real pointer motion onto the middle of a row.
hover() {
  local px py x y w h
  read px py <<< "$($HID pointer)"
  read x y w h _ <<< "$(row "$1")"
  $HID glide $px $py $((x + w / 2)) $((y + h / 2)); sleep 0.4
}

click_row() { local x y w h; read x y w h _ <<< "$(row "$1")"; $HID click $((x + w / 2)) $((y + h / 2)); sleep 0.5; }
rclick_row() { local x y w h; read x y w h _ <<< "$(row "$1")"; $HID rclick $((x + w / 2)) $((y + h / 2)); sleep 0.5; }

# menu_key <keycode>: only into an open menu.
menu_key() {
  if [[ $(menu_state) == open ]]; then $HID key $1; sleep 0.6
  else echo "  (key $1 not sent: the menu is closed)"; fi
}

# drawn <title>: whether the row shows the selection fill on screen - the
# accent colour, against the grey of the menu.
drawn() {
  local x y w h r g b
  read x y w h _ <<< "$(row "$1")"
  screencapture -x -R$x,$y,$w,$h "$WORK/row.png"
  read r g b <<< "$($HID pixel "$WORK/row.png" 0.9 0.5)"
  local hi=$(( r > g ? (r > b ? r : b) : (g > b ? g : b) ))
  local lo=$(( r < g ? (r < b ? r : b) : (g < b ? g : b) ))
  (( hi - lo > 60 )) && echo highlighted || echo plain
}

# keyboard_to <title>: arrow down from the top until the row is selected.
keyboard_to() {
  for _ in {1..14}; do
    [[ $(selected "$1") == selected ]] && return
    menu_key 125
  done
}

# MARK: Setup

RELEASE_WAS_RUNNING=$(pgrep -f "/Applications/macToolKit.app/Contents/MacOS" >/dev/null && echo yes || echo no)
[[ $RELEASE_WAS_RUNNING == yes ]] && { osascript -e 'tell application "macToolKit" to quit'; sleep 1.5; }
DEBUG_WAS_RUNNING=$(pgrep -f "macToolKit Debug.app/Contents/MacOS" >/dev/null && echo yes || echo no)
defaults export $DOMAIN "$WORK/defaults-backup.plist" 2>/dev/null || true

cleanup() {
  [[ $(menu_state 2>/dev/null) == open ]] && close_menu
  pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.5
  defaults delete $DOMAIN 2>/dev/null
  [[ -f $WORK/defaults-backup.plist ]] && defaults import $DOMAIN "$WORK/defaults-backup.plist"
  [[ $DEBUG_WAS_RUNNING == yes ]] && open -g "$APP"
  [[ $RELEASE_WAS_RUNNING == yes ]] && open -g /Applications/macToolKit.app
}
trap cleanup EXIT

defaults write $DOMAIN hasCompletedOnboarding -bool true
launch_app
[[ -n ${SX:-} ]] || { echo "The Debug app shows no menu bar icon."; exit 100; }
BELOW_START=$(value $BELOW_KEY)

# MARK: Pointer

section "Pointer"
open_menu
check "the menu opens from the menu bar icon" open "$(menu_state)"
read _ _ W0 _ <<< "$($HID menu "$PROCESS")"
hover "$FEATURE"
check "the hovered row is drawn highlighted" highlighted "$(drawn "$FEATURE")"
V=$(value $FEATURE_KEY); click_row "$FEATURE"
check "a click flips the feature" "$(flipped $V)" "$(value $FEATURE_KEY)"
check "the menu stays open after a click" open "$(menu_state)"
check "the clicked row keeps its highlight" highlighted "$(drawn "$FEATURE")"
check "the row's checkbox reports the new state" "$( (( $(flipped $V) )) && echo on || echo off)" "$(checkbox "$FEATURE")"
capture pointer-click "after a click on $FEATURE"
click_row "$FEATURE"
check "a second click flips it back" "$V" "$(value $FEATURE_KEY)"
hover "$BELOW"
check "moving on clears the clicked row's highlight" plain "$(drawn "$FEATURE")"
hover "$FEATURE"; read px py <<< "$($HID pointer)"; $HID glide $px $py $((px - 300)) $py; sleep 0.4
check "leaving the menu leaves no row highlighted" "plain plain" "$(drawn "$FEATURE") $(drawn "$BELOW")"
for _ in 1 2 3 4; do hover "Window Switcher"; hover "Audio Priority"; done
read _ _ W1 _ <<< "$($HID menu "$PROCESS")"
check "sweeping the pointer over the rows leaves the menu's width alone" "$W0" "$W1"
hover "$FEATURE"; V=$(value $FEATURE_KEY); rclick_row "$FEATURE"
check "a right-click flips the feature" "$(flipped $V)" "$(value $FEATURE_KEY)"
check "the menu stays open after a right-click" open "$(menu_state)"
rclick_row "$FEATURE"
check "a second right-click flips it back" "$V" "$(value $FEATURE_KEY)"
close_menu
check "a click on the icon closes the menu" closed "$(menu_state)"

# MARK: Keys on a row the pointer highlighted

section "Keys on a row the pointer highlighted"
for spec in "36 Return" "49 Space" "76 keypad Enter"; do
  code=${spec%% *}; name=${spec#* }
  for round in 1 2; do
    open_menu; hover "$FEATURE"; V=$(value $FEATURE_KEY)
    menu_key $code
    check "$name on the hovered row flips the feature (round $round)" "$(flipped $V)" "$(value $FEATURE_KEY)"
    check "$name closes the menu, as on a plain item (round $round)" closed "$(menu_state)"
    close_menu
  done
done
open_menu; hover "$FEATURE"; V=$(value $FEATURE_KEY); click_row "$FEATURE"
menu_key 36
check "Return after a click acts on the clicked row" "$V" "$(value $FEATURE_KEY)"
check "and closes the menu" closed "$(menu_state)"
close_menu

# MARK: Arrow keys from a row the pointer highlighted

section "Arrow keys from a row the pointer highlighted"
open_menu; hover "$BELOW"; menu_key 126
check "Up from the hovered $BELOW selects $FEATURE" selected "$(selected "$FEATURE")"
check "the screen shows $FEATURE highlighted" highlighted "$(drawn "$FEATURE")"
check "the screen no longer shows $BELOW highlighted" plain "$(drawn "$BELOW")"
capture arrow-up "after Up from the hovered $BELOW"
V=$(value $FEATURE_KEY); menu_key 36
check "Return then flips $FEATURE, the row on screen" "$(flipped $V)" "$(value $FEATURE_KEY)"
check "and leaves $BELOW alone" "$BELOW_START" "$(value $BELOW_KEY)"
close_menu
open_menu; hover "$ABOVE"; menu_key 125
check "Down from the hovered $ABOVE selects $FEATURE" selected "$(selected "$FEATURE")"
check "the screen shows $FEATURE highlighted, not $ABOVE" "highlighted plain" "$(drawn "$FEATURE") $(drawn "$ABOVE")"
menu_key 36
check "Return flips $FEATURE back" "$V" "$(value $FEATURE_KEY)"
close_menu

# MARK: Keyboard only

section "Keyboard only"
for round in 1 2; do
  open_menu; keyboard_to "$FEATURE"
  check "arrow keys reach $FEATURE (round $round)" selected "$(selected "$FEATURE")"
  check "the screen shows it highlighted (round $round)" highlighted "$(drawn "$FEATURE")"
  [[ $round == 1 ]] && capture keyboard "reached with the arrow keys"
  V=$(value $FEATURE_KEY); menu_key 36
  check "Return flips it and closes the menu (round $round)" "$(flipped $V) closed" "$(value $FEATURE_KEY) $(menu_state)"
  close_menu
done
open_menu; menu_key 53
check "Escape closes the menu" closed "$(menu_state)"

# MARK: Accessibility

section "Accessibility"
for round in 1 2; do
  V=$(value $FEATURE_KEY)
  osascript -e "tell application \"System Events\" to tell process \"$PROCESS\"" \
    -e 'click menu bar item 1 of menu bar 2' -e 'delay 0.5' \
    -e "click menu item \"$FEATURE\" of menu 1 of menu bar item 1 of menu bar 2" -e 'end tell' >/dev/null
  sleep 0.8
  check "a script's click menu item flips the feature (round $round)" "$(flipped $V)" "$(value $FEATURE_KEY)"
  check "and closes the menu, as on a plain item (round $round)" closed "$(menu_state)"
  close_menu
done
open_menu
for round in 1 2; do
  V=$(value $FEATURE_KEY)
  osascript -e "tell application \"System Events\" to tell process \"$PROCESS\"" \
    -e "perform action \"AXPress\" of checkbox 1 of menu item \"$FEATURE\" of menu 1 of menu bar item 1 of menu bar 2" \
    -e 'end tell' >/dev/null
  sleep 0.5
  check "VoiceOver's press on the row's checkbox flips the feature (round $round)" "$(flipped $V)" "$(value $FEATURE_KEY)"
  check "the checkbox reads the new state (round $round)" "$( (( $(flipped $V) )) && echo on || echo off)" "$(checkbox "$FEATURE")"
done
check "the menu stays open for VoiceOver" open "$(menu_state)"
close_menu

# MARK: Before onboarding

section "Before onboarding"
pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.8
defaults write $DOMAIN hasCompletedOnboarding -bool false
launch_app
open_menu
check "the menu offers Finish Setup" "yes" "$(row "Finish Setup…" >/dev/null 2>&1 && echo yes || echo no)"
hover "$FEATURE"
check "a disabled row is not drawn highlighted" plain "$(drawn "$FEATURE")"
V=$(value $FEATURE_KEY); click_row "$FEATURE"; rclick_row "$FEATURE"
check "clicks on a disabled row change nothing" "$V" "$(value $FEATURE_KEY)"
menu_key 36
check "Return on a disabled row changes nothing" "$V" "$(value $FEATURE_KEY)"
capture onboarding "before onboarding"
close_menu

# MARK: Report

{
  echo
  echo "## App log during the run"
  echo
  echo '```'
  /usr/bin/log show --start "$STARTED" --predicate 'process == "macToolKit Debug" AND messageType == fault' --style compact 2>/dev/null \
    | grep -v '^Timestamp'
  echo '```'
  echo
  echo "Result: $FAILURES failed check(s)."
} >> "$REPORT"

echo; echo "Report: $REPORT"; echo "$FAILURES failed check(s)."
exit $FAILURES
