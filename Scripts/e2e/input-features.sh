#!/bin/zsh
# End-to-end test for the input and window features: Quit on Close, Maximize
# Windows, Side Buttons, Finder Cut & Paste, Scroll Reverser and Smooth
# Scrolling. Real HID events go through the Debug build's event taps; results
# are read back from Finder, Preview, a logging scroll view, Accessibility and
# the app's own log.
#
#   Scripts/e2e/input-features.sh [output-dir]
#
# Needs: a Debug build (xcodebuild ... -configuration Debug build), Preview
# not running, and a shell with Accessibility access (`hid trust`). It moves
# the pointer and drives Finder, Preview and a Terminal window for about two
# minutes - leave the Mac alone meanwhile. The Debug app's defaults are backed up and restored,
# and a running release macToolKit is quit for the run and relaunched after.
#
# Writes <output-dir>/report.md (one PASS/FAIL line per check plus the app's
# log for the run) and <output-dir>/scroll-timeline.svg (distance scrolled
# over time, smoothing off and on), and exits with the number of failed checks.

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

# build_app <name> <source> <bundle-id>: a test app at $WORK/<name>.app.
build_app() {
  mkdir -p "$WORK/$1.app/Contents/MacOS"
  swiftc -O "$ROOT/Scripts/e2e/$2" -o "$WORK/$1.app/Contents/MacOS/$1" || exit 100
  cat > "$WORK/$1.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$3</string>
<key>CFBundleExecutable</key><string>$1</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
}
# An app whose window has a maximum size and no Window menu (no Fill).
TESTAPP=$WORK/TestWindow.app
TESTID=com.sunilaleti.e2e.testwindow
build_app TestWindow testwindow.swift $TESTID
# A scrollable canvas that logs what the wheel did to it (Smooth Scrolling).
SVAPP=$WORK/ScrollView.app
SVID=com.sunilaleti.e2e.scrollview
SVLOG=$WORK/scrollview.log
build_app ScrollView scrollview.swift $SVID
# An app with no windows (Side Buttons).
WLAPP=$WORK/Windowless.app
WLID=com.sunilaleti.e2e.windowless
build_app Windowless windowless.swift $WLID

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
    FAILURES=$((FAILURES + 1))
    # What the screen looked like right then.
    screencapture -x "$OUT/fail-$FAILURES.png" 2>/dev/null
    echo "FAIL  $1 (expected '$2', got '$3') - screen: fail-$FAILURES.png"
    echo "- **FAIL** - $1 (expected \`$2\`, got \`$3\`) - screen: \`fail-$FAILURES.png\`" >> "$REPORT"
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

mark() { wc -l < "$SVLOG" | tr -d ' '; }
sv_stats() { python3 "$ROOT/Scripts/e2e/scrollstats.py" stats "$SVLOG" "$1"; }
fact() { echo "$FACTS" | tr ' ' '\n' | sed -n "s/^$1=//p"; }

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
  # The run's own Finder windows, by id - Finder can't close a filtered
  # window list in one go (-10010).
  osascript -e 'tell application "Finder"' -e 'repeat with i in (id of every Finder window as list)' \
    -e "try" -e "if POSIX path of (target of Finder window id i as alias) starts with \"$WORK/\" then close Finder window id i" \
    -e 'end try' -e 'end repeat' -e 'end tell' 2>/dev/null
  osascript -e 'tell application "Preview" to quit' 2>/dev/null
  pkill -f "$WORK/ScrollView.app" 2>/dev/null
  pkill -f "$WLAPP" 2>/dev/null
  [[ -n ${TTY_WINDOW:-} ]] && osascript -e "tell application \"Terminal\" to close (every window whose id is $TTY_WINDOW)" 2>/dev/null
  [[ ${TERMINAL_WAS_RUNNING:-yes} == no ]] && osascript -e 'tell application "Terminal" to quit' 2>/dev/null
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
defaults write $DOMAIN scrollReverseTrackpad -bool false
defaults write $DOMAIN scrollReverseMouse -bool true
defaults write $DOMAIN scrollReverseVertical -bool true
# Off at first: the Scroll Reverser checks read the raw wheel event, which
# smoothing replaces. The Smooth Scrolling section turns it on from the menu.
defaults write $DOMAIN smoothScrollingEnabled -bool false
defaults write $DOMAIN smoothScrollExceptions -data $(json_apps)
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

# MARK: Smooth Scrolling

section "Smooth Scrolling"
# ScrollView logs every wheel event it gets and every position its canvas
# moves through - what a person scrolling it would see.
open -n "$SVAPP" --args "$SVLOG"; sleep 2
osascript -e 'tell application "System Events" to tell process "ScrollView"' \
  -e "set position of window 1 to {$((VX + 720)), $((VY + 40))}" -e 'set size of window 1 to {600, 500}' -e 'end tell'
SVX=$((VX + 1020)); SVY=$((VY + 290))
$HID move $SVX $SVY; sleep 0.5

# wheel <hid wheel args...>: turn the wheel, let any animation settle, and
# leave ScrollView's view of it in $FACTS (see scrollstats.py).
wheel() { local from=$(mark); $HID wheel "$@"; sleep 1.2; FACTS=$(sv_stats $from); echo "  $* -> $FACTS"; }

OFF_FROM=$(mark); wheel v 3 1 0; OFF_TO=$(mark)
check "with Smooth Scrolling off, a notch reaches the app as one raw wheel event" "raw=1 precise=0" \
  "raw=$(fact raw) precise=$(fact precise)"
RAW_LINES=$(fact ly)

menu_toggle "Smooth Scrolling"
ON_FROM=$(mark); wheel v 3 1 0; ON_TO=$(mark)
check "a 3-line notch reaches the app only as pixel-precise events" "raw=0" "raw=$(fact raw)"
# Scroll Reverser is on for the mouse: +3 lines becomes -3, which moves the
# canvas down by 3 lines of 40 pt. Reversed once - not twice, not never.
check "it moves exactly 3 lines of 40 pt, reversed once by Scroll Reverser" 120 "$(fact dy)"
check "in many small steps, not one jump" yes "$( (( $(fact moves) >= 8 )) && echo yes || echo "no ($(fact moves))")"
check "and settles in 120 to 600 ms" yes "$( (( $(fact ms) >= 120 && $(fact ms) <= 600 )) && echo yes || echo "no ($(fact ms) ms)")"
# Apps that read lines, not points - terminals, games, Carbon and Java apps -
# must see the notch's own lines, one whole line per event at most, not a
# line for every small pixel step of the glide.
check "apps that count lines get the same 3 lines as from the raw notch" "ly=$RAW_LINES steps=3" \
  "ly=$(fact ly) steps=$(fact steps)"

wheel v 1 3 40
check "three quick 1-line notches add up to one smooth 120 pt scroll" "dy=120 flips=0 raw=0" \
  "dy=$(fact dy) flips=$(fact flips) raw=$(fact raw)"
check "and 3 lines for apps that count lines" "ly=$RAW_LINES steps=3" "ly=$(fact ly) steps=$(fact steps)"

FLIP_FROM=$(mark); $HID wheel v 3 1 0; sleep 0.06; wheel v -3 1 0; FLIP_TO=$(mark)
FACTS=$(sv_stats $FLIP_FROM)
check "turning the wheel back mid-scroll reverses once, with no jerk back" 1 "$(fact flips)"
check "and the new direction wins" yes "$( (( $(fact dy) < 0 )) && echo yes || echo "no (dy $(fact dy))")"

wheel h 2 1 0
check "the horizontal (thumb) wheel scrolls smoothly too, exactly 2 lines" "dx=-80 dy=0 raw=0" \
  "dx=$(fact dx) dy=$(fact dy) raw=$(fact raw)"
check "in many small steps" yes "$( (( $(fact moves) >= 8 )) && echo yes || echo "no ($(fact moves))")"
check "and 2 lines for apps that count lines" "lx=2 steps=2" "lx=$(fact lx) steps=$(fact steps)"

wheel v 3 1 0 cmd
check "⌘ + wheel reaches the app raw, so zooming still works" "raw=1 precise=0 mods=cmd" \
  "raw=$(fact raw) precise=$(fact precise) mods=$(fact mods)"
wheel v 3 1 0 shift
check "⇧ + wheel reaches the app raw and still scrolls sideways" "raw=1 dx=30 dy=0" \
  "raw=$(fact raw) dx=$(fact dx) dy=$(fact dy)"
check "trackpad scroll is still left alone with smoothing on" "1" "$($HID scroll trackpad)"

# The pointer moves to another window mid-scroll: the rest of the scroll must
# not land there, and must stop in the window it left.
LEAVE_FROM=$(mark); $HID wheel v 10 1 0; sleep 0.06; $HID move $((VX + 370)) $((VY + 250)); sleep 1.2
FACTS=$(sv_stats $LEAVE_FROM); $HID move $SVX $SVY; sleep 0.3
check "moving the pointer to another window stops the scroll there" yes \
  "$( (( $(fact dy) > 0 && $(fact dy) < 400 )) && echo yes || echo "no (dy $(fact dy) of 400)")"

SPIN_FROM=$(mark); wheel v 1 60 4; SPIN_TO=$(mark)
check "a fast free-spin (60 events in 240 ms) scrolls exactly 60 lines" "dy=2400 raw=0" \
  "dy=$(fact dy) raw=$(fact raw)"
check "and stops within a second, without lagging behind the wheel" yes \
  "$( (( $(fact ms) < 1000 )) && echo yes || echo "no ($(fact ms) ms)")"
check "and 60 lines for apps that count lines" "ly=$((RAW_LINES * 20))" "ly=$(fact ly)"

# A real line-based app: Terminal with mouse reporting on, as tmux, vim
# (mouse=a) and htop turn it on. Terminal sends one wheel report per event
# that carries lines, so a notch must still be 3 reports, not one per frame.
TERMINAL_WAS_RUNNING=$(pgrep -x Terminal >/dev/null && echo yes || echo no)
open -ga Terminal; sleep 3
TTY_OUT=$WORK/ttywheel.txt
TTY_WINDOW=$(osascript -e 'tell application "Terminal"' \
  -e "do script \"python3 -I '$ROOT/Scripts/e2e/ttywheel.py' '$TTY_OUT' 4; exit\"" -e 'activate' \
  -e "set bounds of window 1 to {$((VX + 720)), $((VY + 40)), $((VX + 1320)), $((VY + 540))}" \
  -e 'return id of window 1' -e 'end tell')
for i in {1..50}; do [[ -f $TTY_OUT.ready ]] && break; sleep 0.1; done; sleep 0.4
$HID move $SVX $SVY; sleep 0.3
$HID wheel v 3 1 0
for i in {1..80}; do [[ -f $TTY_OUT ]] && break; sleep 0.1; done
TTY=$(cat "$TTY_OUT" 2>/dev/null); echo "  Terminal sent: $TTY"
check "a 3-line notch in Terminal (tmux, vim) is 3 wheel reports" "up=0 down=3" "$TTY"
sleep 0.5; osascript -e "tell application \"Terminal\" to close (every window whose id is $TTY_WINDOW)" 2>/dev/null; TTY_WINDOW=
[[ $TERMINAL_WAS_RUNNING == no ]] && osascript -e 'tell application "Terminal" to quit'
osascript -e "tell application id \"$SVID\" to activate"; sleep 0.6

sleep 2
CPU=$(top -l 2 -s 1 -pid $(pgrep -f "macToolKit Debug.app/Contents/MacOS") -stats cpu | tail -1)
check "idle afterwards: the app uses under 1% CPU" yes "$(awk -v c="$CPU" 'BEGIN { print (c < 1 ? "yes" : "no (" c "%)") }')"

menu_toggle "Smooth Scrolling"
wheel v 3 1 0
check "switched off from the menu, the wheel is raw again" "raw=1 precise=0" \
  "raw=$(fact raw) precise=$(fact precise)"

python3 "$ROOT/Scripts/e2e/scrollstats.py" chart "$SVLOG" "$OUT/scroll-timeline.svg" \
  "One notch (3 lines)|smoothing off:$OFF_FROM:$OFF_TO|smoothing on:$ON_FROM:$ON_TO" \
  "Wheel turned back after 60 ms|3 lines down, then 3 up:$FLIP_FROM:$FLIP_TO" \
  "Free spin: 60 notches in 240 ms|smoothing on:$SPIN_FROM:$SPIN_TO"
echo "- Timeline: \`scroll-timeline.svg\` (points in \`scroll-timeline.csv\`)" >> "$REPORT"

# MARK: Side Buttons

section "Side Buttons"
osascript -e 'tell application "Finder" to activate'; sleep 0.5
W1=$(osascript -e 'tell application "Finder" to get id of front window')
$HID move $((VX + 370)) $((VY + 250)); sleep 0.4
$HID side back; sleep 0.9
check "button 4 over Finder goes back" "$WORK/nav/A/" "$(finder_path)"
$HID side forward; sleep 0.9
check "button 5 over Finder goes forward" "$WORK/nav/A/B/" "$(finder_path)"

# The side buttons act on the window they point at, like the click they
# replace - not only when it already has focus. A swipe reaches only the
# key window of the active app, so a window that isn't must come forward.
win_path() { osascript -e "tell application \"Finder\" to get POSIX path of (target of Finder window id $1 as alias)"; }
# A second Finder window with its own history (C -> D), clear of the first.
mkdir -p "$WORK/nav/C/D"
W2=$(osascript -e "tell application \"Finder\" to make new Finder window to POSIX file \"$WORK/nav/C\"" -e 'delay 0.8' \
  -e "tell application \"Finder\" to set target of front window to POSIX file \"$WORK/nav/C/D\"" \
  -e "tell application \"Finder\" to set bounds of front window to {$((VX + 740)), $((VY + 40)), $((VX + 1380)), $((VY + 460))}" \
  -e 'tell application "Finder" to get id of front window')
# Another app in front; the pointer rests on the first Finder window, which
# is not even Finder's front window.
osascript -e "tell application id \"$SVID\" to activate"; sleep 0.6
$HID move $((VX + 370)) $((VY + 250)); sleep 0.4
check "another app is in front" $SVID "$(front)"
$HID side back; sleep 0.9
check "button 4 over a background app's window goes back in that window" "$WORK/nav/A/" "$(win_path $W1)"
check "the other Finder window is untouched" "$WORK/nav/C/D/" "$(win_path $W2)"
check "and the window comes forward, like a click" com.apple.finder "$(front)"
check "as Finder's front window" "$W1" "$(osascript -e 'tell application "Finder" to get id of front window')"
# Finder active with the second window focused; the pointer is on the first,
# whose history is A -> B whatever happened above.
osascript -e "tell application \"Finder\" to set target of Finder window id $W1 to POSIX file \"$WORK/nav/A\"" -e 'delay 0.4' \
  -e "tell application \"Finder\" to set target of Finder window id $W1 to POSIX file \"$WORK/nav/A/B\"" \
  -e "tell application \"Finder\" to set index of Finder window id $W2 to 1" -e 'tell application "Finder" to activate'; sleep 0.6
check "Finder is active, with the other window focused" "com.apple.finder $W2" \
  "$(front) $(osascript -e 'tell application "Finder" to get id of front window')"
$HID side back; sleep 0.9
check "button 4 over the unfocused window of the active app goes back there" "$WORK/nav/A/" "$(win_path $W1)"
check "the focused window is untouched" "$WORK/nav/C/D/" "$(win_path $W2)"
check "the pointed window takes focus" "$W1" "$(osascript -e 'tell application "Finder" to get id of front window')"
osascript -e "tell application \"Finder\" to close Finder window id $W2"; sleep 0.4
# The active app has no window at all - Preview, Mail or Safari after their
# last window closed - so Finder's window is on top of everything, yet it is
# not the key window of the active app, and a swipe alone goes nowhere.
osascript -e "tell application \"Finder\" to set target of Finder window id $W1 to POSIX file \"$WORK/nav/A\"" -e 'delay 0.4' \
  -e "tell application \"Finder\" to set target of Finder window id $W1 to POSIX file \"$WORK/nav/A/B\"" \
  -e 'tell application "Finder" to activate'; sleep 0.6
open -n "$WLAPP"; sleep 1.2
check "a windowless app is active, with Finder's window on top" "$WLID com.apple.finder" "$(front) $($HID top)"
$HID side back; sleep 0.9
check "button 4 over that Finder window goes back there" "$WORK/nav/A/" "$(win_path $W1)"
check "and Finder comes forward, like a click" com.apple.finder "$(front)"
pkill -f "$WLAPP"

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
go "$SRC"; sel delta.txt; $HID key 7 cmd; sleep 1
check "⌘X put the file on the pasteboard" delta.txt "$($HID clipboard)"
sel epsilon.txt; $HID key 8 cmd; sleep 0.8
check "⌘C replaced it with the other file" epsilon.txt "$($HID clipboard)"
go "$DST"; $HID key 9 cmd; sleep 2
check "copying something else after ⌘X turns ⌘V back into a copy" "alpha.txt beta.txt epsilon.txt gamma.txt" "$(listing "$DST")"
check "the cut file stayed put" "delta.txt epsilon.txt" "$(listing "$SRC")"
SINCE=$(now)
go "$SRC"; sel delta.txt; $HID key 36; sleep 0.8; $HID key 7 cmd; sleep 0.8; $HID key 53; sleep 0.6
check "⌘X while renaming cuts text, not files" 0 "$(logged "$SINCE" FinderCutPaste 'cut ')"
check "the rename was cancelled cleanly" "delta.txt epsilon.txt" "$(listing "$SRC")"
# Another key released while ⌘X is down: the ⌘C that replaced ⌘X must still
# come back up (keycodes: 0 = A, 7 = X, 8 = C). Where A's release lands
# relative to the ⌘C press doesn't matter, and depends on how fast Finder
# answers the rename check - only that ⌘C goes down, then up, and A too.
KEYS=$($HID keys 0:d 7+cmd:d 0:u 7+cmd:u)
check "⌘X with a key released in between still releases its ⌘C" yes \
  "$([[ $KEYS == "0d 8d 0u 8u" || $KEYS == "0d 0u 8d 8u" ]] && echo yes || echo "no ($KEYS)")"

# MARK: Phase 2 - the exception lists

defaults write $DOMAIN quitOnCloseExceptions -data $(json_apps com.apple.Preview Preview)
defaults write $DOMAIN sideButtonsExceptions -data $(json_apps com.apple.finder Finder)
defaults write $DOMAIN smoothScrollingEnabled -bool true
defaults write $DOMAIN smoothScrollExceptions -data $(json_apps $SVID ScrollView)
launch_app

section "Exception lists"
osascript -e "tell application id \"$SVID\" to activate"; $HID move $SVX $SVY; sleep 0.6
wheel v 3 1 0
check "ScrollView on the smooth-scrolling list gets the raw wheel event" "raw=1 precise=0" \
  "raw=$(fact raw) precise=$(fact precise)"

LEFT=$((VX + 360)); RIGHT=$((VX + 1060)); MID=$((VY + 260))
preview_open "$WORK/images/one.png"
osascript -e "tell application \"Preview\" to set bounds of front window to {$((VX + 40)), $((VY + 40)), $((VX + 680)), $((VY + 480))}" \
  -e "tell application \"Finder\" to set bounds of front window to {$((VX + 740)), $((VY + 40)), $((VX + 1380)), $((VY + 480))}" >/dev/null
osascript -e 'tell application "Finder" to activate'; sleep 0.4; $HID move $RIGHT $MID; sleep 0.8
check "Finder's window is in front, under the pointer" com.apple.finder "$(front)"
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
