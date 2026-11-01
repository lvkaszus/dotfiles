#!/usr/bin/env bash
# Minimal emoji picker: pick an emoji in wofi, copy it to the clipboard and type it into the focused window.
# Needs: wofi, wl-clipboard, wtype and the unicode-emoji package (provides the emoji list).
set -euo pipefail

data="${EMOJI_DATA:-/usr/share/unicode/emoji/emoji-test.txt}"

if [ ! -r "$data" ]; then
    notify-send "Emoji picker" "Missing $data (install the unicode-emoji package)"
    exit 1
fi

# Turn "1F600 ; fully-qualified # 😀 E1.0 grinning face" into "😀 grinning face"
choice="$(
    awk '/; fully-qualified/ {
        sub(/.*# /, "")
        emoji = $1
        $1 = $2 = ""
        sub(/^ +/, "")
        print emoji " " $0
    }' "$data" | wofi --dmenu -i -p "Emoji"
)" || exit 0   # closed with Escape

emoji="${choice%% *}"
[ -n "$emoji" ] || exit 0

# Clipboard as a fallback for apps where typing does not work
printf '%s' "$emoji" | wl-copy
# Give focus a moment to return to the previous window before typing
sleep 0.15
wtype -- "$emoji"
