#!/bin/zsh
# End-to-end test for the Window Switcher's selection right after an app
# switch. Two test apps (SwitchA, SwitchB) that are busy for 0.4 s on each
# activation, so they raise their window late like cmux, are activated in
# turn, then the switcher chord (Cmd+Tab, thumbnails style) is pressed with
# real HID events.
# The highlighted tile is read back from the panel through Accessibility,
# and the screen is captured while Cmd is still held.
#
#   Scripts/e2e/switcher-selection.sh [output-dir] [app]
#
# app defaults to the newest Debug build in DerivedData or build/dd.
# Needs a shell with Accessibility and Screen Recording access (`hid trust`),
# and the Mac left alone for about a minute. The Debug app's defaults are
# backed up and restored, and a running release macToolKit is quit for the
# run and relaunched after.
#
# Writes <output-dir>/report.md (one PASS/FAIL line per check, the tiles
# seen, and the app's log for the run) plus one screenshot per scenario, and
# exits with the number of failed checks.

set -u
ROOT=${0:A:h:h:h}
OUT=${1:-${TMPDIR%/}/mactoolkit-switcher-$(date +%Y%m%d-%H%M%S)}
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

# build_app <name> <bundle-id>: a one-window test app at $WORK/<name>.app.
build_app() {
  mkdir -p "$WORK/$1.app/Contents/MacOS"
  swiftc -O "$ROOT/Scripts/e2e/testwindow.swift" -o "$WORK/$1.app/Contents/MacOS/$1" 2>/dev/null || exit 100
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
AID=com.sunilaleti.e2e.switch-a
BID=com.sunilaleti.e2e.switch-b
build_app SwitchA $AID
build_app SwitchB $BID

{
  echo "# macToolKit Window Switcher selection - E2E report"
  echo
  echo "- Started: $STARTED"
  echo "- Build: \`$APP\`"
  echo "- Commit: $(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet || echo ' (uncommitted changes)')"
  echo "- Shortcut: Cmd+Tab, thumbnails style. Tiles read as \"index app, title\", \`*\` = highlighted."
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

# tiles <file>: the panel's tiles now, kept in <file> and the report.
tiles() {
  $HID switcher "$PROCESS" > "$1"
  { echo '```'; cat "$1"; echo '```'; } >> "$REPORT"
}
# selected <file>: "index app" of the highlighted tile.
selected() { sed -n 's/^\*\([0-9]*\) \([^,]*\).*/\1 \2/p' "$1"; }
count() { grep -c '^.[0-9]' "$1"; }

activate() { osascript -e "tell application id \"$1\" to activate"; }
# B frontmost, A the window before it: what the user had a moment ago.
switch_apps() { activate $AID; sleep 1.5; activate $BID; sleep ${1:-1.5}; }

hold_cmd() { $HID flags cmd; sleep 0.03; }
release_cmd() { $HID flags; sleep 0.6; }
# Escape only reaches the switcher while its panel is up; otherwise it would
# go to the frontmost app.
cancel() {
  [[ $($HID switcher "$PROCESS") != closed ]] && $HID key 53 cmd
  sleep 0.05; $HID flags; sleep 0.4
}

# MARK: Setup

RELEASE_WAS_RUNNING=$(pgrep -f "/Applications/macToolKit.app/Contents/MacOS" >/dev/null && echo yes || echo no)
[[ $RELEASE_WAS_RUNNING == yes ]] && { osascript -e 'tell application "macToolKit" to quit'; sleep 1.5; }
pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.5
defaults export $DOMAIN "$WORK/defaults-backup.plist" 2>/dev/null || true
FRONT_BEFORE=$($HID front)

cleanup() {
  $HID flags 2>/dev/null
  pkill -f "macToolKit Debug.app/Contents/MacOS" 2>/dev/null; sleep 0.5
  pkill -f "$WORK/SwitchA.app" 2>/dev/null
  pkill -f "$WORK/SwitchB.app" 2>/dev/null
  defaults delete $DOMAIN 2>/dev/null
  [[ -f $WORK/defaults-backup.plist ]] && defaults import $DOMAIN "$WORK/defaults-backup.plist"
  [[ $RELEASE_WAS_RUNNING == yes ]] && open -g /Applications/macToolKit.app
  [[ -n $FRONT_BEFORE ]] && activate $FRONT_BEFORE 2>/dev/null
}
trap cleanup EXIT

defaults write $DOMAIN hasCompletedOnboarding -bool true
defaults write $DOMAIN windowSwitcherEnabled -bool true
SLOTS='[{"id":"6B1D0C9E-0000-4000-8000-000000000001","key":"tab","holdModifier":"command","style":"thumbnails","activeSpaceOnly":false,"currentScreenOnly":false,"sameAppOnly":false}]'
defaults write $DOMAIN switcherShortcuts -data $(printf '%s' "$SLOTS" | xxd -p | tr -d '\n')
defaults write $DOMAIN switcherShowDelay -float 0

# Both raise their window late on activation, like cmux: the activation
# notification comes before the z-order changes.
open "$WORK/SwitchA.app" --args --slow-activation
open "$WORK/SwitchB.app" --args --slow-activation; sleep 2
open -g "$APP"; sleep 3

# MARK: Scenarios

section "Hold Cmd+Tab 1.5 s after an app switch"
switch_apps
hold_cmd; $HID key 48 cmd
echo "Right away, from the cache:" >> "$REPORT"; tiles "$WORK/early"
sleep 0.6
echo "After the fresh snapshot:" >> "$REPORT"; tiles "$WORK/late"
screencapture -x "$OUT/hold-after-switch.png"
cancel
check "the panel opens on the previous window (SwitchA at 1)" "1 SwitchA" "$(selected "$WORK/early")"
check "it is still on the previous window after the fresh snapshot" "1 SwitchA" "$(selected "$WORK/late")"
check "the frontmost window is tile 0" "0 SwitchB" "$(sed -n 's/^.\(0\) \([^,]*\),.*/\1 \2/p' "$WORK/late")"
check "Escape leaves SwitchB in front" $BID "$($HID front)"

section "Quick Cmd+Tab 1.5 s after an app switch"
switch_apps
hold_cmd; $HID key 48 cmd; release_cmd
check "a quick chord goes to the previous window" $AID "$($HID front)"

section "Release Cmd after the fresh snapshot lands"
switch_apps
hold_cmd; $HID key 48 cmd; sleep 0.8; release_cmd
check "a held chord goes to the previous window" $AID "$($HID front)"

section "Cmd+Tab 0.15 s after an app switch, while SwitchB is still busy"
switch_apps 0.15
hold_cmd; $HID key 48 cmd
echo "Right away, from the cache:" >> "$REPORT"; tiles "$WORK/fast-early"
sleep 0.8
echo "After the fresh snapshots:" >> "$REPORT"; tiles "$WORK/fast-late"
screencapture -x "$OUT/hold-right-after-switch.png"
release_cmd
check "the panel opens on the previous window" SwitchA "$(selected "$WORK/fast-early" | cut -d' ' -f2)"
check "the panel settles on the previous window" "1 SwitchA" "$(selected "$WORK/fast-late")"
check "releasing goes to the previous window" $AID "$($HID front)"

section "Quick Cmd+Tab 0.15 s after an app switch"
switch_apps 0.15
hold_cmd; $HID key 48 cmd; release_cmd
check "a quick chord goes to the previous window" $AID "$($HID front)"

section "Tab twice: a selection the user made stays put"
switch_apps
hold_cmd; $HID key 48 cmd; sleep 0.05; $HID key 48 cmd; sleep 0.8
tiles "$WORK/twice"
cancel
check "the third tile stays highlighted after the fresh snapshot" 2 "$(selected "$WORK/twice" | cut -d' ' -f1)"

section "Shift+Cmd+Tab starts on the last tile"
switch_apps
hold_cmd; $HID key 48 cmd shift; sleep 0.8
tiles "$WORK/reverse"
cancel
check "the last tile is highlighted" $(( $(count "$WORK/reverse") - 1 )) "$(selected "$WORK/reverse" | cut -d' ' -f1)"

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
