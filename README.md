# Session HUD

A macOS menubar heads-up display for every Claude Code session on your machine: what each one was about, where it left off, which are live, which agents are still running, and one click to resume in your terminal.

Built in a hackathon day. It leans on Claude Code's own state (`claude agents --json`, hook events) plus the local transcripts, and uses Haiku through your own Claude account to write the titles and summaries.

## What you get

- Menubar robot that turns orange with a count when a session is waiting on you.
- Popover (or a floating always-on-top panel) listing sessions grouped by Needs input, Working, Open, Today, Yesterday, This week, Earlier.
- Each row: a title for the whole session, one line on what it accomplished, a "Left off" line with the last delivery and what is still pending, time, project, turn count, running or finished subagents.
- Search across the whole history by title, summary, prompt or project.
- Resume: one click opens a new Warp tab (or Terminal.app) in the session's directory and runs `claude --resume <id>`. Copy the command instead if you prefer. Right-click for fork, copy id, reveal transcript.
- Global hotkey ⌃⌥H toggles it from anywhere.

## Requirements

- macOS 13 or later, Apple Silicon or Intel.
- Xcode Command Line Tools (`xcode-select --install`). Only `clang` is used; no Xcode, no Swift.
- [Bun](https://bun.sh) 1.1 or later.
- Claude Code 2.1.2xx signed in. The summariser runs `claude -p --model haiku` under your account.
- Warp is optional. Without it, resume opens Terminal.app.

## Install

```bash
git clone <this repo> ~/session-hud      # any location works
cd ~/session-hud
app/build.sh                             # builds app/build/SessionHUD.app with clang
open app/build/SessionHUD.app            # robot appears in the menubar; the app starts the server itself
bun run scripts/install-hooks.ts         # optional but recommended: live updates and subagent status
scripts/install-launch-agent.sh          # optional: start at login
```

First launch indexes your transcripts (a few hundred sessions take about half a second) and then generates titles for interactive sessions from the last 30 days, roughly 3 seconds and under half a cent each. Automated sessions (cron, `claude -p`) keep their first-prompt title and are hidden behind the "automated" toggle.

## What it touches, honestly

- **Reads** `~/.claude/projects/*/*.jsonl` (transcripts), `~/.claude/history.jsonl`, and the output of `claude agents --json`. Anthropic documents the transcript format as internal, so a Claude Code release can break the indexer; the parser ignores anything it does not recognise, and the live state comes from the documented `claude agents --json`.
- **Writes** a cache under `data/` inside this checkout (`index.json` with prompt excerpts and last replies, `summaries.json`). It is gitignored. Delete the folder to reset.
- **Edits** `~/.claude/settings.json` if you run the hook installer: seven async hooks (`UserPromptSubmit`, `Stop`, `SubagentStart`, `SubagentStop`, `SessionStart`, `SessionEnd`, `Notification`) that POST their payload to `127.0.0.1:4243` with a 1 second timeout and never block a session. A timestamped backup is written next to the file. Undo with `bun run scripts/install-hooks.ts --remove`.
- **Sends** prompt excerpts (first 15 and last 55 prompts, 220 characters each) and the last three assistant replies of each session to Haiku through your own Claude Code login, to produce the title and summaries. Nothing else leaves the machine; the server binds to localhost only.
- **Writes** `~/.warp/launch_configurations/session-hud-resume.yaml` on each resume when Warp is the terminal.

## Using it

Click the robot or press ⌃⌥H. In the list: arrows or j/k move, enter resumes, c copies the command, `/` or ⌘F jumps to search, esc closes. Hover a row for the Resume and Copy buttons. Drag the popover away from the menubar, or click the panel icon in the header, to detach it into a floating panel; close the panel to reattach.

Right-click the robot: choose Warp or Terminal.app for resume, detach or reattach, regenerate all titles, quit.

Rebind the hotkey with Carbon key codes and modifier bits, then relaunch:

```bash
defaults write com.sessionhud.app hotkeyKeyCode -int 4        # H
defaults write com.sessionhud.app hotkeyModifiers -int 6144   # control + option
```

## Layout

- `server/index.ts` Bun server on 127.0.0.1:4243. Indexer, `claude agents --json` poller, hook receiver, summariser, JSON API (`/sessions`, `/health`, `/hook`, `/resummarise`).
- `app/main.m` AppKit menubar app in Objective-C, one file, built by `app/build.sh`.
- `scripts/hud-hook.sh` the hook bridge; `scripts/install-hooks.ts` installs or removes it; `scripts/install-launch-agent.sh` optional login item (`--remove` to undo).

Server environment variables: `HUD_PORT` (4243), `HUD_SUMMARISE=0` to disable the summariser, `HUD_SUMMARY_DAYS` (30), `HUD_SUMMARY_MODEL` (haiku), `HUD_SUMMARY_EFFORT` (low), `HUD_SUMMARY_THINKING` (0). App: `HUD_DEBUG_SHOW=1` opens the popover on launch, `HUD_DEBUG_DETACH=1` starts detached (run the binary directly; `open` drops env vars). Logs: `data/server.log`, `~/Library/Logs/SessionHUD.log`.

## Uninstall

```bash
bun run scripts/install-hooks.ts --remove
scripts/install-launch-agent.sh --remove
pkill -x SessionHUD; pkill -f "session-hud/server/index.ts"
```

Then delete the checkout folder.

## Known limitations

- No tests. It is a one-day build; the indexer has only been exercised on one machine's transcripts.
- One machine only; cloud sessions and the desktop app's sessions are not listed.
- Subagent status for sessions started before the hooks were installed is inferred from transcript files rather than reported.
- Headless `claude -p` loads every configured MCP connector unless told not to. The summariser passes `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` and strips inherited `CLAUDE*` environment variables; without that a call costs 60k to 110k tokens.

MIT licensed.
