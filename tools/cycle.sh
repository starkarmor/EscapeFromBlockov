#!/bin/bash
# Play-test loop with Rojo live sync (rojo serve on 34872, plugin connected): never closes, reopens or saves the place.
# Compile-check, stop any running play, press Play, print new script output from the Studio log.
# Usage: tools/cycle.sh [seconds to wait after Play]
cd "$(dirname "$0")/.." || exit 1
WAIT=${1:-25}
tools/check.sh || exit 1
proc='first process whose name is "RobloxStudio"'
osascript -e "tell application \"System Events\" to tell ($proc) to click menu item \"Stop\" of menu 1 of menu bar item \"Test\" of menu bar 1" >/dev/null 2>&1
sleep 2
LOG=$(ls -t ~/Library/Logs/Roblox/*Studio*_last.log | head -1)
START=$(wc -l < "$LOG" | tr -d " ")
osascript -e "tell application \"System Events\" to set frontmost of ($proc) to true" -e 'delay 0.3' -e 'tell application "System Events" to key code 96'
sleep "$WAIT"
tail -n +"$START" "$LOG" | grep -E "CreatorError|CreatorWarning|CreatorOutput" | grep -v -E "Hello [Ww]orld|Flag .* referenced|UIBlox|203785492|FoundationProvider" | cut -c1-320 | tail -60
