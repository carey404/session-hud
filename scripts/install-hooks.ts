// Adds (or removes with --remove) the Session HUD hook bridge to ~/.claude/settings.json. Backs up first.
import { readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
const SETTINGS = join(homedir(), ".claude", "settings.json");
const CMD = "$HOME/Development/session-hud/scripts/hud-hook.sh";
const EVENTS = ["UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop", "SessionStart", "SessionEnd", "Notification"];
const remove = process.argv.includes("--remove");
const raw = readFileSync(SETTINGS, "utf8");
const settings = JSON.parse(raw);
const backup = SETTINGS + ".bak-session-hud-" + new Date().toISOString().replace(/[:.]/g, "-");
copyFileSync(SETTINGS, backup);
settings.hooks ??= {};
let changes = 0;
for (const ev of EVENTS) {
  const list: any[] = settings.hooks[ev] ?? [];
  const isOurs = (g: any) => Array.isArray(g?.hooks) && g.hooks.some((h: any) => typeof h?.command === "string" && h.command.includes("session-hud/scripts/hud-hook.sh"));
  const filtered = list.filter((g) => !isOurs(g));
  if (filtered.length !== list.length) changes++;
  if (!remove) { filtered.push({ hooks: [{ type: "command", command: CMD, timeout: 2, async: true }] }); changes++; }
  if (filtered.length) settings.hooks[ev] = filtered; else delete settings.hooks[ev];
}
writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + "\n");
JSON.parse(readFileSync(SETTINGS, "utf8")); // validate
console.log(`${remove ? "removed" : "installed"} hooks for ${EVENTS.length} events (${changes} edits). Backup: ${backup}`);
