#!/bin/bash
# Removes Custom Notch from this Mac: turns off Launch at Login, quits the app, deletes the app, its
# settings, caches, socket folder and Slack token, and makes macOS forget its permissions.
# It does NOT touch ~/.claude/settings.json or your keychain: see the two reminders at the end.
set -u

APP="$HOME/Applications/Custom Notch.app"
BUNDLE_ID="local.customnotch.CustomNotch"

if [[ -x "$APP/Contents/MacOS/CustomNotch" ]]; then
    "$APP/Contents/MacOS/CustomNotch" -unregisterLogin YES 2>/dev/null
fi
pkill -x CustomNotch 2>/dev/null && sleep 0.5

rm -rf "$APP"
defaults delete "$BUNDLE_ID" 2>/dev/null
rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
rm -rf "$HOME/Library/Application Support/Custom Notch"
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1
security delete-generic-password -s local.customnotch.slack >/dev/null 2>&1     # the Slack token, if any

echo "Custom Notch is removed."
echo
echo "Two things to do yourself:"
echo "  1. In ~/.claude/settings.json, remove the five \"notch-hook\" entries under \"hooks\" and the \"statusLine\" entry."
echo "     (Until you do, they find no app and Claude Code simply carries on as usual.)"
echo "  2. If you made the signing certificate: Keychain Access → login → My Certificates →"
echo "     delete \"Custom Notch Local Signing\"."
