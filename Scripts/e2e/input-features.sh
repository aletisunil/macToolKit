#!/bin/zsh
# End-to-end test for the input and window features: Quit on Close, Maximize
# Windows, Focus Follows Mouse, Side Buttons, Finder Cut & Paste and Scroll
# Reverser. Real HID events go through the Debug build's event taps; results
# are read back from Finder, Preview, Accessibility and the app's own log.
#
#   Scripts/e2e/input-features.sh [output-dir]
#
# Needs: a Debug build (xcodebuild ... -configuration Debug build), Preview
# not running, and a shell with Accessibility access (`hid trust`). It moves
# the pointer and drives Finder and Preview for about two minutes - leave the
# Mac alone meanwhile. The Debug app's defaults are backed up and restored,
# and a running release macToolKit is quit for the run and relaunched after.
#
# Writes <output-dir>/report.md (one PASS/FAIL line per check plus the app's
# log for the run) and exits with the number of failed checks.

set -u
ROOT=${0:A:h:h:h}
OUT=${1:-${TMPDIR%/}/mactoolkit-e2e-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/work"
OUT=${OUT:A}
WORK=$OUT/work
REPORT=$OUT/report.md
DOMAIN=com.sunilaleti.mactoolkit.debug
STARTED=$(date '+%Y-%m-%d %H:%M:%S')
FAILURES=0

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/macToolKit-*/Build/Products/Debug/"macToolKit Debug.app" 2>/dev/null | head -1)
[[ -n $APP ]] || { echo "No Debug build found - build the macToolKit scheme in Debug first."; exit 100; }
pgrep -x Preview >/dev/null && { echo "Quit Preview first - the run opens, closes and quits it."; exit 100; }

HID=$WORK/hid
swiftc -O "$ROOT/Scripts/e2e/hid.swift" -o "$HID" || exit 100
[[ $($HID trust) == trusted ]] || { echo "This shell needs Accessibility access to post events."; exit 100; }

# An app whose window has a maximum size and no Window menu (no Fill).
TESTAPP=$WORK/TestWindow.app
TESTID=com.sunilaleti.e2e.testwindow
mkdir -p "$TESTAPP/Contents/MacOS"
swiftc -O "$ROOT/Scripts/e2e/testwindow.swift" -o "$TESTAPP/Contents/MacOS/TestWindow" || exit 100
cat > "$TESTAPP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$TESTID</string>
<key>CFBundleExecutable</key><string>TestWindow</string>
<key>CFBundleName</key><string>TestWindow</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# MARK: Helpers

{
  echo "# macToolKit input features - E2E report"
  echo
  echo "- Started: $STARTED"
  echo "- Build: \`$APP\`"
  echo "- Commit: $(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet || echo ' (uncommitted changes)')"
  echo
} > "$REPORT"

section() { echo; echo "== $1"; printf '\n## %s\n\n' "$1" >> "$REPORT"; }

# check <name> <expected> <actual>
check() {
  if [[ $2 == "$3" ]]; then
    echo "PASS  $1"; echo "- PASS - $1" >> "$REPORT"
  else
    echo "FAIL  $1 (expected '$2', got '$3')"
    echo "- **FAIL** - $1 (expected \`$2\`, got \`$3\`)" >> "$REPORT"
    FAILURES=$((FAILURES + 1))
  fi
}

running() { pgrep -x "$1" >/dev/null && echo running || echo "not running"; }
front() { $HID front; }
finder_path() { osascript -e 'tell application "Finder" to get POSIX path of (target of front window as alias)'; }
logged() { /usr/bin/log show --start "$1" --predicate "subsystem == \"com.sunilaleti.mactoolkit\" AND category == \"$2\"" --style compact 2>/dev/null | grep -c "$3"; }
now() { date '+%Y-%m-%d %H:%M:%S'; }

# Frames are compared with a few points of slack: apps round sizes.
near() {
  local -a a b; a=(${=1}); b=(${=2})
  for i in 1 2 3 4; do (( ${a[i]} - ${b[i]} > 4 || ${b[i]} - ${a[i]} > 4 )) && { echo no; return; }; done
  echo yes
}

json_apps() { python3 -c 'import json,sys;print(json.dumps([{"bundleID":b,"name":n} for b,n in zip(sys.argv[1::2],sys.argv[2::2])],separators=(",",":")).encode().hex())' "$@"; }

launch_app() {
  pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.8
  open -g "$APP"; sleep 3
}

preview_open() { open -a Preview "$@"; sleep 2.5; osascript -e 'tell application "Preview" to activate'; sleep 0.6; }

# Turns a feature on or off from the menu bar extra, the way a user does.
menu_toggle() {
  osascript -e 'tell application "System Events" to tell process "macToolKit Debug"' \
    -e 'click menu bar item 1 of menu bar 2' -e 'delay 0.4' \
    -e "click menu item \"$1\" of menu 1 of menu bar item 1 of menu bar 2" -e 'end tell' >/dev/null
  sleep 0.8
}

# green_click <bundle-id>: rest on the green button long enough for its Move
# & Resize menu to open, then click it while sampling the window's frames.
# Leaves the frame count in $WORK/frames.
green_click() {
  local x y fs
  read x y fs <<< "$($HID button $1 zoom)"
  $HID move $x $y; sleep 1.5
  $HID popover > "$WORK/popover-before"
  $HID frames $1 900 > "$WORK/frames" & sleep 0.1
  $HID click $x $y; wait; sleep 0.4
}
animated() { (( $(cat "$WORK/frames") > 10 )) && echo yes || echo "no ($(cat "$WORK/frames") frames)"; }

# MARK: Setup

RELEASE_WAS_RUNNING=$(pgrep -f "/Applications/macToolKit.app/Contents/MacOS" >/dev/null && echo yes || echo no)
[[ $RELEASE_WAS_RUNNING == yes ]] && { osascript -e 'tell application "macToolKit" to quit'; sleep 1.5; }
pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.5
defaults export $DOMAIN "$WORK/defaults-backup.plist" 2>/dev/null || true

cleanup() {
  pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.5
  osascript -e 'tell application "Preview" to quit' 2>/dev/null
  defaults delete $DOMAIN 2>/dev/null
  [[ -f $WORK/defaults-backup.plist ]] && defaults import $DOMAIN "$WORK/defaults-backup.plist"
  [[ $RELEASE_WAS_RUNNING == yes ]] && open -g /Applications/macToolKit.app
}
trap cleanup EXIT

read VX VY VW VH <<< "$($HID visible)"
mkdir -p "$WORK/nav/A/B" "$WORK/images"
for name in one two three; do
  sips -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns \
    --out "$WORK/images/$name.png" >/dev/null 2>&1
done

defaults write $DOMAIN hasCompletedOnboarding -bool true
for key in quitOnCloseEnabled maximizeWindowsEnabled sideButtonsEnabled finderCutPasteEnabled scrollReverserEnabled; do
  defaults write $DOMAIN $key -bool true
done
defaults write $DOMAIN focusFollowsMouseEnabled -bool false
defaults write $DOMAIN scrollReverseTrackpad -bool false
defaults write $DOMAIN scrollReverseMouse -bool true
defaults write $DOMAIN scrollReverseVertical -bool true
defaults write $DOMAIN quitOnCloseExceptions -data $(json_apps)
defaults write $DOMAIN sideButtonsExceptions -data $(json_apps)
launch_app

# A Finder window of our own, with back/forward history: A -> B.
osascript -e "tell application \"Finder\" to make new Finder window to POSIX file \"$WORK/nav/A\"" \
  -e 'delay 0.8' -e "tell application \"Finder\" to set target of front window to POSIX file \"$WORK/nav/A/B\"" \
  -e "tell application \"Finder\" to set bounds of front window to {$((VX + 40)), $((VY + 40)), $((VX + 700)), $((VY + 460))}" \
  -e 'tell application "Finder" to activate' -e 'delay 0.6'

# MARK: Scroll Reverser

section "Scroll Reverser"
check "mouse wheel +3 arrives reversed" "-3" "$($HID scroll wheel)"
check "trackpad scroll is left alone (trackpad reversal off)" "1" "$($HID scroll trackpad)"

# MARK: Side Buttons

section "Side Buttons"
$HID move $((VX + 370)) $((VY + 250)); sleep 0.4
$HID side back; sleep 0.9
check "button 4 over Finder goes back" "$WORK/nav/A/" "$(finder_path)"
$HID side forward; sleep 0.9
check "button 5 over Finder goes forward" "$WORK/nav/A/B/" "$(finder_path)"

# MARK: Maximize Windows

section "Maximize Windows"
preview_open "$WORK/images/one.png"
osascript -e 'tell application "Preview" to set bounds of front window to {300, 200, 1000, 700}'; sleep 0.5
BEFORE=$($HID frame com.apple.Preview)
SINCE=$(now); green_click com.apple.Preview
check "resting on the green button opens its Move & Resize menu" open "$(cat "$WORK/popover-before")"
check "green button fills the visible screen" yes "$(near "$($HID frame com.apple.Preview)" "$VX $VY $VW $VH")"
check "the window animates there, like the system's Fill" yes "$(animated)"
check "the Move & Resize menu closes with the click" closed "$($HID popover)"
check "full screen was not entered" false "$($HID button com.apple.Preview zoom | cut -d' ' -f3)"
green_click com.apple.Preview; sleep 0.4
check "second click restores the exact earlier frame" "$BEFORE" "$($HID frame com.apple.Preview)"
check "the restore animates too" yes "$(animated)"
check "the menu closes with the second click too" closed "$($HID popover)"
check "both clicks logged by the app" 2 "$(logged "$SINCE" Maximize window)"
for i in 1 2 3; do green_click com.apple.Preview; green_click com.apple.Preview; sleep 0.4; done
check "three more round trips leave the frame exactly where it was" "$BEFORE" "$($HID frame com.apple.Preview)"
# A window of a background app: the click brings it forward and fills it.
# The test app (one window, clear of Preview's) is the app in front.
osascript -e "tell application \"Preview\" to set bounds of front window to {$((VX + 860)), $((VY + 200)), $((VX + 1400)), $((VY + 600))}"
open -n "$TESTAPP"; sleep 2
read X Y FS <<< "$($HID button com.apple.Preview zoom)"; $HID click $X $Y; sleep 1
check "green button on a background app's window brings it forward" com.apple.Preview "$(front)"
check "and fills the screen" yes "$(near "$($HID frame com.apple.Preview)" "$VX $VY $VW $VH")"
read X Y FS <<< "$($HID button com.apple.Preview zoom)"; $HID click $X $Y; sleep 1.2
osascript -e "tell application id \"$TESTID\" to quit" \
  -e 'tell application "Preview" to set bounds of front window to {300, 200, 1000, 700}' -e 'tell application "Preview" to activate'; sleep 0.6
read X Y FS <<< "$($HID button com.apple.Preview zoom)"
$HID click $X $Y opt; sleep 2.5
check "⌥-click enters full screen" true "$($HID button com.apple.Preview zoom | cut -d' ' -f3)"
# In full screen the title bar only shows once the pointer pushes into the
# top edge - a warp there doesn't count, it takes real motion.
$HID glide 300 80 300 0; $HID glide 300 0 320 0; sleep 1.5
read X Y FS <<< "$($HID button com.apple.Preview zoom)"
$HID glide 320 0 $X $Y; sleep 0.5; $HID click $X $Y; sleep 2.5
check "green button in full screen still exits full screen" false "$($HID button com.apple.Preview zoom | cut -d' ' -f3)"

section "Maximize Windows - app without the system's Fill"
open -n "$TESTAPP"; sleep 2
BEFORE=$($HID frame $TESTID)
read X Y FS <<< "$($HID button $TESTID zoom)"; $HID click $X $Y; sleep 1
read FX FY FW FH <<< "$($HID frame $TESTID)"
check "a window with a maximum size grows to the screen's top left" "$VX $VY" "$FX $FY"
check "as far as its maximum size allows" yes "$( (( FW < VW || FH < VH )) && echo yes || echo no )"
read X Y FS <<< "$($HID button $TESTID zoom)"; $HID click $X $Y; sleep 1
check "second click restores it though it never filled the screen" "$BEFORE" "$($HID frame $TESTID)"
read X Y FS <<< "$($HID button $TESTID zoom)"; $HID click $X $Y; sleep 1
read X Y FS <<< "$($HID button $TESTID zoom)"; $HID click $X $Y; sleep 1
check "and keeps toggling" "$BEFORE" "$($HID frame $TESTID)"
osascript -e "tell application id \"$TESTID\" to quit"; sleep 0.5

# MARK: Quit on Close

section "Quit on Close"
read X Y FS <<< "$($HID button com.apple.Preview close)"
SINCE=$(now); $HID click $X $Y; sleep 1.5
check "closing Preview's only window quits it" "not running" "$(running Preview)"
check "quit logged by the app" 1 "$(logged "$SINCE" QuitOnClose quitting)"

preview_open "$WORK/images/one.png"; preview_open "$WORK/images/two.png"
$HID key 13 cmd; sleep 1.5
check "closing one of two windows keeps it running" running "$(running Preview)"
read X Y FS <<< "$($HID button com.apple.Preview min)"; $HID click $X $Y; sleep 1.5
preview_open "$WORK/images/three.png"
$HID key 13 cmd; sleep 1.5
check "a minimized window keeps it running" running "$(running Preview)"
osascript -e 'tell application "Preview" to set miniaturized of window 1 to false'; sleep 1.2
osascript -e 'tell application "Preview" to activate'; sleep 0.5
$HID key 13 cmd; sleep 1.5
check "closing the restored last window quits it" "not running" "$(running Preview)"

preview_open "$WORK/images/one.png"; preview_open "$WORK/images/two.png"
osascript -e 'tell application "System Events" to tell process "Preview" to click menu item "Merge All Windows" of menu "Window" of menu bar 1' >/dev/null
sleep 1.5
$HID key 13 cmd; sleep 1.5
check "closing one tab of a tab group keeps it running" running "$(running Preview)"
$HID key 13 cmd; sleep 1.5
check "closing the last tab quits it" "not running" "$(running Preview)"

# MARK: Finder Cut & Paste

section "Finder Cut & Paste"
mkdir -p "$WORK/cp/src" "$WORK/cp/dst"
for name in alpha beta gamma delta epsilon; do echo $name > "$WORK/cp/src/$name.txt"; done
SRC=$WORK/cp/src; DST=$WORK/cp/dst
go() { osascript -e "tell application \"Finder\" to set target of front window to POSIX file \"$1\"" -e 'tell application "Finder" to activate' -e 'delay 0.8'; }
sel() {
  local items=() name
  for name in "$@"; do items+=("file \"$name\" of folder (POSIX file \"$SRC\" as alias)"); done
  osascript -e "tell application \"Finder\" to select {${(j:, :)items}}" -e 'delay 0.4'
}
listing() { ls "$1" | tr '\n' ' ' | sed 's/ $//'; }

SINCE=$(now)
go "$SRC"; sel alpha.txt; $HID key 7 cmd; sleep 1; go "$DST"; $HID key 9 cmd; sleep 2
check "⌘X then ⌘V moves a file" "alpha.txt" "$(listing "$DST")"
check "the moved file left the source" "beta.txt delta.txt epsilon.txt gamma.txt" "$(listing "$SRC")"
go "$SRC"; sel beta.txt gamma.txt; $HID key 7 cmd; sleep 1; go "$DST"; $HID key 9 cmd; sleep 2
check "a multi-file cut moves every file" "alpha.txt beta.txt gamma.txt" "$(listing "$DST")"
check "cuts and moves logged" "2 2" "$(logged "$SINCE" FinderCutPaste 'cut ') $(logged "$SINCE" FinderCutPaste moving)"
go "$SRC"; sel delta.txt; $HID key 7 cmd; sleep 1; sel epsilon.txt; $HID key 8 cmd; sleep 0.8
go "$DST"; $HID key 9 cmd; sleep 2
check "copying something else after ⌘X turns ⌘V back into a copy" "alpha.txt beta.txt epsilon.txt gamma.txt" "$(listing "$DST")"
check "the cut file stayed put" "delta.txt epsilon.txt" "$(listing "$SRC")"
SINCE=$(now)
go "$SRC"; sel delta.txt; $HID key 36; sleep 0.8; $HID key 7 cmd; sleep 0.8; $HID key 53; sleep 0.6
check "⌘X while renaming cuts text, not files" 0 "$(logged "$SINCE" FinderCutPaste 'cut ')"
check "the rename was cancelled cleanly" "delta.txt epsilon.txt" "$(listing "$SRC")"
# Another key released while ⌘X is down: the ⌘C that replaced ⌘X must still
# come back up (keycodes: 0 = A, 7 = X, 8 = C).
check "⌘X with a key released in between still releases its ⌘C" "0d 8d 0u 8u" "$($HID keys 0:d 7+cmd:d 0:u 7+cmd:u)"

# MARK: Phase 2 - Focus Follows Mouse and the exception lists

defaults write $DOMAIN focusFollowsMouseEnabled -bool true
# 0.4 s leaves room for the key-press check to land inside the delay.
defaults write $DOMAIN focusFollowsMouseDelay -float 0.4
defaults write $DOMAIN quitOnCloseExceptions -data $(json_apps com.apple.Preview Preview)
defaults write $DOMAIN sideButtonsExceptions -data $(json_apps com.apple.finder Finder)
launch_app

section "Focus Follows Mouse"
LEFT=$((VX + 360)); RIGHT=$((VX + 1060)); MID=$((VY + 260))
preview_open "$WORK/images/one.png"
osascript -e "tell application \"Preview\" to set bounds of front window to {$((VX + 40)), $((VY + 40)), $((VX + 680)), $((VY + 480))}" \
  -e "tell application \"Finder\" to set bounds of front window to {$((VX + 740)), $((VY + 40)), $((VX + 1380)), $((VY + 480))}" \
  -e 'tell application "Finder" to activate'
$HID move $RIGHT $MID; sleep 0.8
$HID glide $RIGHT $MID $LEFT $MID; sleep 1
check "resting on Preview focuses it" com.apple.Preview "$(front)"
$HID glide $LEFT $MID $RIGHT $MID; sleep 1
check "resting on Finder focuses it" com.apple.finder "$(front)"
# The last move lands inside the lookup throttle: only a lookup where the
# pointer stopped sees Preview.
$HID hop $((RIGHT - 10)) $MID $LEFT $MID 15; sleep 1
check "a flick that stops on Preview right away still focuses it" com.apple.Preview "$(front)"
$HID glide $LEFT $MID $RIGHT $MID; sleep 1
$HID glide $RIGHT $MID $LEFT $MID; $HID key 53; sleep 1
check "a key press right after moving keeps focus where it is" com.apple.finder "$(front)"
$HID glide $LEFT $MID $((LEFT + 20)) $((MID + 10)); sleep 1
check "moving again afterwards focuses after all" com.apple.Preview "$(front)"
$HID glide $LEFT $MID $RIGHT $MID; sleep 1
$HID glide $RIGHT 10 $LEFT 10; sleep 0.8
check "gliding along the menu bar changes nothing" com.apple.finder "$(front)"
$HID move $RIGHT $MID; sleep 0.5
osascript -e 'tell application "System Events" to tell process "Finder" to click menu bar item "View" of menu bar 1' >/dev/null; sleep 0.5
$HID glide $RIGHT $MID $LEFT $MID; sleep 0.8
check "an open menu keeps focus where it is" com.apple.finder "$(front)"
$HID key 53; sleep 0.5

section "Exception lists"
osascript -e 'tell application "Finder" to activate'; sleep 0.4; $HID move $RIGHT $MID; sleep 0.8
BEFORE=$(finder_path); $HID side back; sleep 0.9
check "Finder on the side-button list gets the raw button (no navigation)" "$BEFORE" "$(finder_path)"
# A side button held while the feature is switched off: its release is never
# seen, and must not leave the button marked as swallowed.
$HID move $LEFT $MID; sleep 0.6
$HID buttons 3:d >/dev/null; menu_toggle "Side Buttons"; $HID buttons 3:u >/dev/null; menu_toggle "Side Buttons"
$HID move $RIGHT $MID; sleep 0.6
check "after an off/on toggle mid-press, Finder still gets whole clicks" "3d 3g 3u" "$($HID buttons 3:d 3:g 3:u)"
osascript -e 'tell application "Preview" to activate'; sleep 0.5; $HID key 13 cmd; sleep 1.5
check "Preview on the keep-running list survives its last window" running "$(running Preview)"

# MARK: Report

osascript -e "tell application \"Finder\" to close (every window whose name is \"dst\" or name is \"src\" or name is \"B\" or name is \"A\")" 2>/dev/null
{
  echo
  echo "## App log during the run"
  echo
  echo '```'
  /usr/bin/log show --start "$STARTED" --predicate 'subsystem == "com.sunilaleti.mactoolkit"' --style compact 2>/dev/null \
    | grep -v '^Timestamp' | sed 's/^\([0-9-]* [0-9:.]*\).*mactoolkit:\(.*\)/\1 \2/'
  echo '```'
  echo
  echo "Result: $FAILURES failed check(s)."
} >> "$REPORT"

echo; echo "Report: $REPORT"; echo "$FAILURES failed check(s)."
exit $FAILURES
