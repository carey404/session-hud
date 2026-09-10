#!/bin/zsh
# Session HUD hook bridge: forward the hook payload (stdin JSON) to the local HUD server. Never blocks a session.
curl -s -m 1 -X POST -H 'content-type: application/json' --data-binary @- http://127.0.0.1:4243/hook >/dev/null 2>&1 || true
exit 0
