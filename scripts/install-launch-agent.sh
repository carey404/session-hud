#!/bin/zsh
# Optional: start Session HUD at login (the app starts the Bun server itself when it is not running).
set -e
PLIST=~/Library/LaunchAgents/com.mikecarey.session-hud.plist
APP="$HOME/Development/session-hud/app/build/SessionHUD.app"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.mikecarey.session-hud</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
launchctl bootout gui/$(id -u) "$PLIST" 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "installed $PLIST (remove with: launchctl bootout gui/\$(id -u) $PLIST && rm $PLIST)"
