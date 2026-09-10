# Session HUD

macOS menubar HUD of every Claude Code session on this machine: thematic title, where it left off, live state, running subagents, one-click resume into Warp.

- `server/index.ts` (Bun, 127.0.0.1:4243): indexes `~/.claude/projects/*/*.jsonl`, polls `claude agents --json`, receives hook events, summarises with Haiku via `claude -p`. `bun run server`.
- `app/main.m` (AppKit, Objective-C): menubar popover. `app/build.sh` builds `app/build/SessionHUD.app` with Command Line Tools only. The app starts the server if it is not running.
- `scripts/install-hooks.ts`: adds async hooks to `~/.claude/settings.json` that POST to the server (`--remove` to undo). `scripts/hud-hook.sh` is the bridge.
- `scripts/install-launch-agent.sh`: optional launch at login.

Right-click the menubar icon: choose Warp or Terminal.app for resume, regenerate titles, quit. Keys in the popover: enter resume, c copy, j/k move.
Env: `HUD_SUMMARISE=0` disables the summariser, `HUD_SUMMARY_DAYS` (30) bounds backfill, `HUD_DEBUG_SHOW=1` opens the popover on launch.
