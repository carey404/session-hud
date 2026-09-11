#!/bin/zsh
# Optional: start Session HUD at login (the app starts the Bun server itself when it is not running). Pass --remove to uninstall.
if [ "$1" = "--remove" ]; then launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.sessionhud.launcher.plist 2>/dev/null; rm -f ~/Library/LaunchAgents/com.sessionhud.launcher.plist; echo removed; exit 0; fi
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST=~/Library/LaunchAgents/com.sessionhud.launcher.plist
APP="$ROOT/app/build/SessionHUD.app"
[ -d "$APP" ] || { echo "build the app first: app/build.sh"; exit 1; }
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.sessionhud.launcher</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
launchctl bootout gui/$(id -u) "$PLIST" 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "installed $PLIST (remove with: launchctl bootout gui/\$(id -u) $PLIST && rm $PLIST)"
