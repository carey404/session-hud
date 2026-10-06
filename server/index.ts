// Session HUD data server. Bun. Serves JSON on localhost:4243 for the menubar app.
// Sources, most stable first: `claude agents --json`, hook POSTs, ~/.claude/projects/*/*.jsonl (internal format, read defensively).
import { readdirSync, statSync, existsSync, readFileSync, writeFileSync, watch, mkdirSync } from "node:fs";
import { join, basename } from "node:path";
import { homedir } from "node:os";

const HOME = homedir();
const CLAUDE_DIR = process.env.CLAUDE_DIR ?? join(HOME, ".claude");
const PROJECTS_DIR = join(CLAUDE_DIR, "projects");
const DATA_DIR = process.env.HUD_DATA_DIR ?? join(import.meta.dir, "..", "data");
const PORT = Number(process.env.HUD_PORT ?? 4243);
const SUMMARY_DAYS = Number(process.env.HUD_SUMMARY_DAYS ?? 30);
const SUMMARY_MODEL = process.env.HUD_SUMMARY_MODEL ?? "haiku";
const SUMMARY_ENABLED = (process.env.HUD_SUMMARISE ?? "1") !== "0";
// Spawn policy. Every `claude -p` is a full Claude Code process start, which org telemetry (managed settings, OTel) counts as a
// session; summarising after every reply made one HUD look like 10x the real usage. So: a session gets its first summary
// right away and on SessionEnd, otherwise only after it has been idle; pending sessions share one process; a daily spawn cap backstops it.
const SUMMARY_IDLE_MS = Number(process.env.HUD_SUMMARY_IDLE_MIN ?? 10) * 60_000;
const SUMMARY_BATCH = Math.max(1, Number(process.env.HUD_SUMMARY_BATCH ?? 5));
const SUMMARY_COALESCE_MS = Number(process.env.HUD_SUMMARY_COALESCE_S ?? 30) * 1000;
const SUMMARY_DAILY_CAP = Number(process.env.HUD_SUMMARY_DAILY_CAP ?? 40);
const DEMO = process.env.HUD_DEMO === "1"; // serve a generic dataset for screenshots instead of your sessions
mkdirSync(DATA_DIR, { recursive: true });

// ---------- types ----------
type AgentRow = {
  id: string; type: string; description: string; startedAt?: string; endedAt?: string;
  status: "running" | "done" | "unknown"; source: "hook" | "meta";
};
type Session = {
  id: string; file: string; project: string; cwd?: string; gitBranch?: string; entrypoint?: string; version?: string;
  firstAt?: string; lastActivityAt?: string; lastUserAt?: string; lastAssistantAt?: string;
  firstPrompt?: string; lastPrompt?: string; leafUuid?: string; lastAssistantText?: string;
  prompts?: string[]; replies?: string[]; // digest for the summariser: every real user prompt (capped), last few assistant texts
  hookInteractive?: boolean; // a human typed a prompt (UserPromptSubmit); transcripts no longer carry this since CC 2.1.269
  endedAt?: string; // SessionEnd hook seen and not resumed since: summarise now rather than waiting for idle
  aiTitle?: string; customTitle?: string; agentName?: string;
  turns: number; costUSD?: number; continuedIn?: string;
  pendingBackgroundAgents?: number;
  agents: Record<string, AgentRow>;
  // parse bookkeeping
  offset: number; size: number; mtimeMs: number;
  // live overlays
  hookStatus?: "busy" | "idle"; hookStatusAt?: number;
  needsInput?: { type: string; message?: string; at: number };
};
type Summary = { leaf: string; title: string; about?: string; leftOff: string; at: string; v?: number };
const SUMMARY_VERSION = 2; // bump to regenerate every cached summary
const INDEX_VERSION = 2;   // bump to force a full re-parse of transcripts (new fields)
type LiveAgent = { pid?: number; id?: string; cwd?: string; kind?: string; startedAt?: number; sessionId: string; name?: string; status?: string; state?: string; waitingFor?: string };

const sessions = new Map<string, Session>();
const summaries = new Map<string, Summary>();
let live = new Map<string, LiveAgent>();
let liveUpdatedAt = 0;
let liveError: string | undefined;
let hooksReceived = 0; let lastHook: { event?: string; session?: string; at?: string } = {};

// ---------- persistence ----------
const INDEX_PATH = join(DATA_DIR, "index.json");
const SUMMARIES_PATH = join(DATA_DIR, "summaries.json");
function loadCache() {
  try {
    const raw = JSON.parse(readFileSync(INDEX_PATH, "utf8"));
    const list: Session[] = Array.isArray(raw) ? [] : raw.version === INDEX_VERSION ? raw.sessions : [];
    for (const s of list) sessions.set(s.id, { ...s, agents: s.agents ?? {} });
  } catch {}
  try { for (const [k, v] of Object.entries(JSON.parse(readFileSync(SUMMARIES_PATH, "utf8")))) summaries.set(k, v as Summary); } catch {}
}
let saveTimer: Timer | undefined;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try { writeFileSync(INDEX_PATH, JSON.stringify({ version: INDEX_VERSION, sessions: [...sessions.values()] })); } catch (e) { console.error("save index", e); }
    try { writeFileSync(SUMMARIES_PATH, JSON.stringify(Object.fromEntries(summaries))); } catch (e) { console.error("save summaries", e); }
  }, 500);
}

// ---------- transcript parsing ----------
function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.filter((b: any) => b && b.type === "text" && typeof b.text === "string").map((b: any) => b.text).join("\n");
  return "";
}
function isRealPrompt(rec: any): boolean {
  if (rec.isMeta || rec.isSidechain) return false;
  const c = rec.message?.content;
  if (Array.isArray(c) && c.every((b: any) => b?.type === "tool_result")) return false;
  const t = textOf(c).trim();
  if (!t) return false;
  if (t.startsWith("<local-command") || t.startsWith("<command-name>") || t.startsWith("<task-notification>") || t.startsWith("<system-reminder>")) return false;
  return true;
}
function isNoisePrompt(t: string): boolean {
  const x = t.trim();
  return !x || x.startsWith("<task-notification>") || x.startsWith("[Request interrupted") || x.startsWith("<local-command") || x.startsWith("<command-name>") || x.startsWith("<system-reminder>") || /^(ok|okay|yes|no|continue|go|go ahead|sorry continue|thanks|resume)\.?$/i.test(x);
}
// claude -p expands @path mentions and treats leading slashes as commands; neutralise both so quoted prompts stay inert text
function inert(t: string): string { return t.replace(/@/g, "＠").replace(/^\//, "／"); }
function pushPrompt(s: Session, p: string) {
  s.prompts ??= [];
  s.prompts.push(inert(p).slice(0, 220));
  if (s.prompts.length > 70) s.prompts.splice(15, s.prompts.length - 70); // keep the first 15 and the most recent 55
}
function pushReply(s: Session, t: string) {
  s.replies ??= [];
  s.replies.push(inert(t.length > 1500 ? t.slice(0, 500) + " […] " + t.slice(-1000) : t));
  if (s.replies.length > 3) s.replies.splice(0, s.replies.length - 3);
}
function cleanPrompt(t: string): string {
  return t.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").replace(/\s+/g, " ").trim().slice(0, 400);
}

function parseSlice(s: Session, text: string) {
  for (const line of text.split("\n")) {
    if (!line) continue;
    let d: any; try { d = JSON.parse(line); } catch { continue; }
    const t = d.type;
    if (d.timestamp && (t === "user" || t === "assistant")) {
      if (!s.firstAt || d.timestamp < s.firstAt) s.firstAt = d.timestamp;
      if (!s.lastActivityAt || d.timestamp > s.lastActivityAt) s.lastActivityAt = d.timestamp;
      s.cwd = d.cwd ?? s.cwd; s.gitBranch = d.gitBranch ?? s.gitBranch; s.entrypoint = d.entrypoint ?? s.entrypoint; s.version = d.version ?? s.version;
    }
    switch (t) {
      case "user":
        if (isRealPrompt(d)) {
          const p = cleanPrompt(textOf(d.message?.content));
          if (p && !isNoisePrompt(p)) { s.turns++; s.lastPrompt = p; s.lastUserAt = d.timestamp; if (!s.firstPrompt) s.firstPrompt = p; pushPrompt(s, p); s.hookStatus = undefined; s.needsInput = undefined; }
        }
        break;
      case "assistant": {
        if (d.isSidechain) break;
        const txt = textOf(d.message?.content).trim();
        if (txt) { s.lastAssistantText = txt.slice(-3000); s.lastAssistantAt = d.timestamp; if (txt.length > 80) pushReply(s, txt); }
        break;
      }
      case "ai-title": if (d.aiTitle) s.aiTitle = d.aiTitle; break;
      case "custom-title": if (d.customTitle) s.customTitle = d.customTitle; break;
      case "agent-name": if (d.agentName) s.agentName = d.agentName; break;
      case "last-prompt": if (d.leafUuid) s.leafUuid = d.leafUuid; break;
      case "cost-state": if (typeof d.totalCostUSD === "number") s.costUSD = d.totalCostUSD; break;
      case "continued-in": if (d.continuedInSessionId) s.continuedIn = d.continuedInSessionId; break;
      case "system": if (d.subtype === "turn_duration" && typeof d.pendingBackgroundAgentCount === "number") s.pendingBackgroundAgents = d.pendingBackgroundAgentCount; break;
      case "queue-operation": {
        // task-notification delivered to the parent => that subagent finished
        const m = typeof d.content === "string" && d.content.match(/<task-id>([^<]+)<\/task-id>[\s\S]*?<status>([^<]+)<\/status>/);
        if (m) { const a = s.agents[m[1]]; if (a && a.status !== "done") { a.status = "done"; a.endedAt = d.timestamp; } else if (!a) s.agents[m[1]] = { id: m[1], type: "?", description: "", status: "done", endedAt: d.timestamp, source: "meta" }; }
        break;
      }
    }
  }
}

function indexFile(project: string, file: string): boolean {
  const id = basename(file, ".jsonl");
  let st; try { st = statSync(file); } catch { return false; }
  let s = sessions.get(id);
  if (!s) { s = { id, file, project, turns: 0, agents: {}, offset: 0, size: 0, mtimeMs: 0 }; sessions.set(id, s); }
  s.file = file; s.project = project;
  if (st.size === s.size && st.mtimeMs === s.mtimeMs) return false;
  if (st.size < s.offset) { // rewritten: start over
    Object.assign(s, { turns: 0, offset: 0, firstAt: undefined, lastActivityAt: undefined, firstPrompt: undefined, lastPrompt: undefined, lastAssistantText: undefined, prompts: [], replies: [] });
  }
  const buf = readFileSync(file);
  let end = buf.length;
  if (end > 0 && buf[end - 1] !== 0x0a) { const nl = buf.lastIndexOf(0x0a); end = nl < s.offset ? s.offset : nl + 1; } // only whole lines
  if (end > s.offset) parseSlice(s, buf.subarray(s.offset, end).toString("utf8"));
  s.offset = end; s.size = st.size; s.mtimeMs = st.mtimeMs;
  indexSubagents(s);
  return true;
}

function indexSubagents(s: Session) {
  const dir = join(s.file.slice(0, -".jsonl".length), "subagents");
  if (!existsSync(dir)) return;
  let names: string[]; try { names = readdirSync(dir); } catch { return; }
  for (const n of names) {
    if (!n.endsWith(".meta.json")) continue;
    const id = n.slice("agent-".length, -".meta.json".length);
    let meta: any = {}; try { meta = JSON.parse(readFileSync(join(dir, n), "utf8")); } catch {}
    const jsonl = join(dir, `agent-${id}.jsonl`);
    let jst; try { jst = statSync(jsonl); } catch {}
    const mst = (() => { try { return statSync(join(dir, n)); } catch { return undefined; } })();
    const existing = s.agents[id];
    const row: AgentRow = existing ?? { id, type: meta.agentType ?? "?", description: meta.description ?? "", status: "unknown", source: "meta" };
    row.type = meta.agentType ?? row.type; row.description = meta.description ?? row.description;
    row.startedAt ??= mst ? new Date(mst.mtimeMs).toISOString() : undefined;
    if (row.source !== "hook" && row.status !== "done") {
      // infer: final assistant text with no tool_use, or stale for 10 min => done
      const stale = jst ? Date.now() - jst.mtimeMs > 10 * 60_000 : true;
      let finished = false;
      if (jst && jst.size > 0) {
        try {
          const buf = readFileSync(jsonl); const tail = buf.subarray(Math.max(0, buf.length - 20000)).toString("utf8").trim().split("\n");
          for (let i = tail.length - 1; i >= 0; i--) { try { const d = JSON.parse(tail[i]); if (d.type === "assistant") { const c = d.message?.content; finished = Array.isArray(c) && !c.some((b: any) => b.type === "tool_use") && !!textOf(c).trim(); break; } } catch {} }
        } catch {}
      }
      row.status = finished || stale ? "done" : "running";
      if (row.status === "done") row.endedAt ??= jst ? new Date(jst.mtimeMs).toISOString() : undefined;
    }
    s.agents[id] = row;
  }
}

function fullScan(): number {
  let changed = 0;
  let projects: string[] = []; try { projects = readdirSync(PROJECTS_DIR); } catch { return 0; }
  const seen = new Set<string>();
  for (const p of projects) {
    const dir = join(PROJECTS_DIR, p);
    let files: string[] = []; try { files = readdirSync(dir); } catch { continue; }
    for (const f of files) if (f.endsWith(".jsonl")) { seen.add(basename(f, ".jsonl")); if (indexFile(p, join(dir, f))) changed++; }
  }
  for (const id of [...sessions.keys()]) { const sx = sessions.get(id)!; if (!seen.has(id) && sx.offset > 0 && !sx.hookInteractive) sessions.delete(id); }
  if (changed) scheduleSave();
  return changed;
}

// ---------- live processes via `claude agents --json` ----------
async function pollLive() {
  try {
    const proc = Bun.spawn(["claude", "agents", "--json", "--all"], { stdout: "pipe", stderr: "pipe", env: summariserEnv() });
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    const arr = JSON.parse(out) as LiveAgent[];
    const m = new Map<string, LiveAgent>();
    for (const a of arr) if (a.sessionId) m.set(a.sessionId, a);
    live = m; liveUpdatedAt = Date.now(); liveError = undefined;
  } catch (e: any) { liveError = String(e?.message ?? e); }
}

// ---------- summariser ----------
// Clean environment for `claude -p`: drop every CLAUDE* variable inherited from a parent Claude Code session (a nested
// session otherwise inherits its parent's context and hooks), and turn extended thinking off for this classification job.
function summariserEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined && !k.startsWith("CLAUDE")) env[k] = v;
  env.MAX_THINKING_TOKENS = process.env.HUD_SUMMARY_THINKING ?? "0";
  return env;
}
const summaryQueue: string[] = []; let summarising = 0; const inQueue = new Set<string>();
const summaryFailedAt = new Map<string, number>(); // per-session backoff after a bad or empty result
let waitingIdle = 0; // stale sessions holding for their idle window (reported, not queued)
// daily spawn budget, persisted so a server restart does not reset it
const SPAWNS_PATH = join(DATA_DIR, "summariser.json");
let spawnDay = ""; let spawnsToday = 0; let capLogged = false;
try { const j = JSON.parse(readFileSync(SPAWNS_PATH, "utf8")); spawnDay = j.day ?? ""; spawnsToday = Number(j.count ?? 0); } catch {}
function spawnBudget(): boolean {
  const d = new Date().toDateString();
  if (d !== spawnDay) { spawnDay = d; spawnsToday = 0; capLogged = false; }
  return spawnsToday < SUMMARY_DAILY_CAP;
}
function recordSpawn() { spawnBudget(); spawnsToday++; try { writeFileSync(SPAWNS_PATH, JSON.stringify({ day: spawnDay, count: spawnsToday })); } catch {} }
function summariserStatus() { spawnBudget(); return { spawnsToday, dailyCap: SUMMARY_DAILY_CAP, capped: spawnsToday >= SUMMARY_DAILY_CAP, idleMin: SUMMARY_IDLE_MS / 60_000, batch: SUMMARY_BATCH, queued: summaryQueue.length, running: summarising, waitingIdle }; }

// stale: the cached summary no longer matches the session (or there is none)
function needsSummary(s: Session): boolean {
  if (!SUMMARY_ENABLED || s.turns === 0 || !s.lastAssistantText) return false;
  if (s.entrypoint && s.entrypoint !== "cli") return false; // automated (-p, cron) sessions keep their first-prompt title; they still write local transcripts so entrypoint is known
  if (s.lastActivityAt && Date.now() - Date.parse(s.lastActivityAt) > SUMMARY_DAYS * 86_400_000) return false;
  const leaf = summaryLeaf(s); const cur = summaries.get(s.id);
  return !cur || cur.leaf !== leaf || cur.v !== SUMMARY_VERSION;
}
function summaryLeaf(s: Session) { return `${s.turns}:${s.lastAssistantAt ?? ""}:${(s.lastAssistantText ?? "").length}`; }
// urgent: never summarised, or the session just ended. Due: urgent, or idle long enough that the user has moved on.
function summaryUrgent(s: Session) { return !summaries.has(s.id) || !!s.endedAt; }
function summaryDue(s: Session, now: number) {
  if (summaryUrgent(s)) return true;
  const failed = summaryFailedAt.get(s.id); if (failed && now - failed < 10 * 60_000) return false;
  return !s.lastActivityAt || now - Date.parse(s.lastActivityAt) >= SUMMARY_IDLE_MS;
}
let coalesceTimer: Timer | undefined; let coalesceAt = 0;
function enqueueSummaries() {
  const now = Date.now(); let urgent = false; waitingIdle = 0;
  for (const s of sessions.values()) {
    if (!needsSummary(s)) continue;
    if (!summaryDue(s, now)) { waitingIdle++; continue; }
    if (!inQueue.has(s.id)) { inQueue.add(s.id); summaryQueue.push(s.id); }
    if (summaryUrgent(s)) urgent = true;
  }
  if (!summaryQueue.length) return;
  // newest first
  summaryQueue.sort((a, b) => (sessions.get(b)?.lastActivityAt ?? "").localeCompare(sessions.get(a)?.lastActivityAt ?? ""));
  // hold briefly so sessions that go stale together share one process; urgent work waits at most 5 s
  const delay = urgent ? Math.min(5000, SUMMARY_COALESCE_MS) : SUMMARY_COALESCE_MS;
  if (coalesceTimer && coalesceAt > now + delay) { clearTimeout(coalesceTimer); coalesceTimer = undefined; }
  if (!coalesceTimer) { coalesceAt = now + delay; coalesceTimer = setTimeout(() => { coalesceTimer = undefined; pumpSummaries(); }, delay); }
}
async function pumpSummaries() {
  while (summarising < 1 && summaryQueue.length) {
    if (!spawnBudget()) { if (!capLogged) { capLogged = true; console.log(`summariser daily cap ${SUMMARY_DAILY_CAP} reached, ${summaryQueue.length} queued until tomorrow`); } return; }
    const batch: Session[] = [];
    while (batch.length < SUMMARY_BATCH && summaryQueue.length) {
      const id = summaryQueue.shift()!; inQueue.delete(id);
      const s = sessions.get(id); if (s && needsSummary(s)) batch.push(s);
    }
    if (!batch.length) continue;
    summarising++;
    summariseBatch(batch).catch((e) => { console.error("summarise", batch.map((s) => s.id.slice(0, 8)).join(","), e?.message ?? e); const t = Date.now(); for (const s of batch) summaryFailedAt.set(s.id, t); }).finally(() => { summarising--; pumpSummaries(); });
  }
}
function sessionDigest(s: Session, tag: string) {
  const hint = s.customTitle ?? s.aiTitle ?? "";
  const prompts = (s.prompts?.length ? s.prompts : [s.firstPrompt, s.lastPrompt].filter(Boolean) as string[]);
  const promptList = prompts.map((p, i) => `${i + 1}. ${inert(p)}`).join("\n");
  const replies = (s.replies?.length ? s.replies : [s.lastAssistantText ?? ""]).map((r) => inert(r)).map((r, i, a) => `--- reply ${a.length - i === 1 ? "(most recent)" : `(${a.length - i} back)`} ---\n${r}`).join("\n");
  const span = s.firstAt && s.lastActivityAt ? `${s.firstAt.slice(0, 16)} to ${s.lastActivityAt.slice(0, 16)}` : "the session";
  return `===== SESSION ${tag} =====
The user typed ${prompts.length} prompts over ${span}.
${hint ? `Hint title (may be stale or a code name): ${inert(hint)}\n` : ""}
USER PROMPTS IN ORDER:
${promptList}

LAST ASSISTANT REPLIES:
${replies}`;
}
async function summariseBatch(batch: Session[]) {
  const leaves = batch.map((s) => summaryLeaf(s)); // captured before the call; a session that moves on meanwhile goes stale again
  const tags = batch.map((_, i) => `S${i + 1}`);
  const prompt = `You write the rows for ${batch.length} Claude Code session${batch.length === 1 ? "" : "s"} in a heads-up display the user scans when returning to work, sometimes a day later.
For each session read ALL of its prompts: the title and "about" must describe the whole session's work, not just the latest prompt.
The sessions are independent. Never carry a detail from one into another.

Return ONLY a compact JSON array with exactly ${batch.length} object${batch.length === 1 ? "" : "s"}, in the same order as the sessions, each with four fields:
"id": the session tag exactly as given (${tags.join(", ")}).
"title": 4 to 7 words, Title Case, the session's overall subject (the thing being built, decided, researched or written). Not the latest tweak.
"about": one sentence, max 22 words, plain past tense, what the session accomplished across its arc.
"leftOff": one or two sentences, max 40 words. First what the last exchange delivered, then what is still open: waiting on the user, a next step named in the last reply, or nothing pending. Be concrete: name the artifact, decision or question.

Rules: no em-dashes, no marketing words, no "the user"; write as a colleague's note. If a hint title is a short code name the user chose (like "MBR"), you may reuse it inside the title but still make the title descriptive.

${batch.map((s, i) => sessionDigest(s, tags[i])).join("\n\n")}`;
  recordSpawn();
  const proc = Bun.spawn(["claude", "-p", "--model", SUMMARY_MODEL, "--effort", process.env.HUD_SUMMARY_EFFORT ?? "low", "--no-session-persistence", "--setting-sources", "", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--system-prompt", "You output only compact JSON. No prose, no code fences.", "--output-format", "json", prompt],
    { stdout: "pipe", stderr: "pipe", cwd: DATA_DIR, env: summariserEnv() });
  const out = await new Response(proc.stdout).text(); await proc.exited;
  let result = ""; let meta: any = {}; try { meta = JSON.parse(out); result = meta.result ?? ""; } catch { result = out; }
  const u = meta.usage ?? {};
  console.log(`summariser spawn ${spawnsToday}/${SUMMARY_DAILY_CAP} today n=${batch.length} ids=${batch.map((s) => s.id.slice(0, 8)).join(",")} in=${(u.input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0)} cacheRead=${u.cache_read_input_tokens ?? 0} out=${u.output_tokens ?? 0} think=${u.output_tokens_details?.thinking_tokens ?? 0} cost=$${Number(meta.total_cost_usd ?? 0).toFixed(4)} api=${meta.duration_api_ms ?? "?"}ms`);
  const m = result.match(/\[[\s\S]*\]/) ?? result.match(/\{[\s\S]*\}/); if (!m) throw new Error("no JSON in summary: " + result.slice(0, 120));
  const parsed = JSON.parse(m[0]); const arr: any[] = Array.isArray(parsed) ? parsed : [parsed];
  const fix = (x: unknown) => String(x ?? "").replace(/[—–]/g, "-").replace(/\s+/g, " ").trim();
  const now = Date.now(); const at = new Date(now).toISOString(); let ok = 0;
  batch.forEach((s, i) => {
    const j = arr.find((e) => fix(e?.id).toUpperCase() === tags[i]) ?? (arr.length === batch.length ? arr[i] : undefined);
    const title = fix(j?.title), about = fix(j?.about), leftOff = fix(j?.leftOff);
    if (!title) { console.error("summary", s.id.slice(0, 8), "missing or empty entry"); summaryFailedAt.set(s.id, now); return; }
    summaries.set(s.id, { leaf: leaves[i], title, about, leftOff, at, v: SUMMARY_VERSION }); summaryFailedAt.delete(s.id); ok++;
    console.log(`summary ${s.id.slice(0, 8)} ok: ${title}`);
  });
  if (ok) scheduleSave();
}

// ---------- hooks ----------
function applyHook(h: any) {
  const id = h.session_id; if (!id) return;
  hooksReceived++; lastHook = { event: h.hook_event_name, session: String(id).slice(0, 8), at: new Date().toISOString() };
  let s = sessions.get(id);
  if (!s && h.transcript_path) { const p = h.transcript_path as string; s = { id, file: p, project: basename(join(p, "..")), turns: 0, agents: {}, offset: 0, size: 0, mtimeMs: 0, cwd: h.cwd }; sessions.set(id, s); }
  if (!s) return;
  const now = Date.now(); const iso = new Date(now).toISOString();
  s.lastActivityAt = iso;
  switch (h.hook_event_name) {
    case "UserPromptSubmit": { s.hookStatus = "busy"; s.hookStatusAt = now; s.needsInput = undefined; s.endedAt = undefined; const p = h.prompt ? cleanPrompt(String(h.prompt)) : ""; if (p && !isNoisePrompt(p)) { s.lastPrompt = p; s.lastUserAt = iso; s.turns++; if (!s.firstPrompt) s.firstPrompt = p; pushPrompt(s, p); s.hookInteractive = true; } break; }
    case "Stop": s.hookStatus = "idle"; s.hookStatusAt = now; s.needsInput = undefined; if (h.last_assistant_message) { const t = String(h.last_assistant_message); s.lastAssistantText = t.slice(-3000); s.lastAssistantAt = iso; if (t.length > 80) pushReply(s, t); } break;
    case "SubagentStart": if (h.agent_id) s.agents[h.agent_id] = { id: h.agent_id, type: h.agent_type ?? "?", description: (h.subagent_prompt ?? h.description ?? "").slice(0, 160), startedAt: iso, status: "running", source: "hook" }; break;
    case "SubagentStop": if (h.agent_id) { const a = s.agents[h.agent_id] ?? { id: h.agent_id, type: h.agent_type ?? "?", description: "", source: "hook" as const, status: "done" as const }; a.status = "done"; a.endedAt = iso; a.source = "hook"; s.agents[h.agent_id] = a; } break;
    case "Notification": if (["permission_prompt", "agent_needs_input", "elicitation_dialog"].includes(h.notification_type)) s.needsInput = { type: h.notification_type, message: h.message, at: now }; break; // idle_prompt is just "waiting for your next prompt", not a blocker
    case "SessionStart": s.hookStatus = "idle"; s.hookStatusAt = now; s.endedAt = undefined; break;
    case "SessionEnd": s.hookStatus = undefined; s.needsInput = undefined; s.endedAt = iso; break;
  }
  // transcript may lag the hook; pick up the file shortly after
  setTimeout(() => { if (s && indexFile(s.project, s.file)) scheduleSave(); enqueueSummaries(); }, 1500);
  scheduleSave();
}

// ---------- view ----------
function view() {
  const now = Date.now();
  const rows = [...sessions.values()].map((s) => {
    const lv = live.get(s.id); const sum = summaries.get(s.id);
    const title = s.customTitle ?? sum?.title ?? s.aiTitle ?? s.agentName ?? (s.firstPrompt ? s.firstPrompt.slice(0, 70) : "(untitled)");
    const titleSource = s.customTitle ? "custom" : sum ? "summary" : s.aiTitle ? "ai-title" : s.agentName ? "agent-name" : "first-prompt";
    const agents = Object.values(s.agents).sort((a, b) => (b.startedAt ?? "").localeCompare(a.startedAt ?? ""));
    const running = agents.filter((a) => a.status === "running").length;
    const hookFresh = s.hookStatusAt && now - s.hookStatusAt < 6 * 3600_000;
    const alive = !!lv && (lv.kind === "interactive" || (lv.kind === "background" && lv.state !== "done" && lv.state !== "failed" && lv.state !== "stopped"));
    // a hook-reported needs-input flag is stale once the process reports busy without waitingFor, or after 30 min
    const needsInput = !!s.needsInput && alive && !(lv?.status === "busy" && !lv?.waitingFor) && now - s.needsInput.at < 30 * 60_000;
    let state: string;
    if (lv?.waitingFor || needsInput) state = "needs_input";
    else if (lv?.status === "busy" || (alive && hookFresh && s.hookStatus === "busy") || (alive && running > 0)) state = "working";
    else if (alive) state = "idle";
    else if (lv?.state === "done") state = "bg_done";
    else if (lv?.state === "failed") state = "bg_failed";
    else state = "ended";
    const shortBg = lv?.kind === "background" ? lv.id : undefined;
    const resume = shortBg && alive ? `claude attach ${shortBg}` : `claude --resume ${s.id}`;
    const automated = (s.entrypoint && s.entrypoint !== "cli") || (s.turns === 0 && !s.hookInteractive);
    return {
      id: s.id, shortId: s.id.slice(0, 8), title, titleSource, about: sum?.about ?? null, leftOff: sum?.leftOff ?? null,
      lastActivityAt: s.lastActivityAt ?? s.firstAt ?? new Date(s.mtimeMs || 0).toISOString(), firstAt: s.firstAt ?? null, lastPrompt: s.lastPrompt ?? null,
      project: s.cwd ? basename(s.cwd) : s.project, cwd: s.cwd ?? null, gitBranch: s.gitBranch ?? null,
      state, alive, needsInput: s.needsInput?.message ?? lv?.waitingFor ?? null,
      live: lv ? { pid: lv.pid, kind: lv.kind, name: lv.name, status: lv.status, state: lv.state, waitingFor: lv.waitingFor, shortId: lv.id } : null,
      agents, runningAgents: running, turns: s.turns, costUSD: s.costUSD ?? null, continuedIn: s.continuedIn ?? null, automated,
      resume: { command: resume, forkCommand: `claude --resume ${s.id} --fork-session`, cwd: s.cwd ?? null },
    };
  }).sort((a, b) => b.lastActivityAt.localeCompare(a.lastActivityAt));
  const needsInput = rows.filter((r) => r.state === "needs_input").length;
  const working = rows.filter((r) => r.state === "working").length;
  return { generatedAt: new Date(now).toISOString(), counts: { total: rows.length, needsInput, working, alive: rows.filter((r) => r.alive).length, summariesPending: summaryQueue.length + summarising, summariesWaitingIdle: waitingIdle, summariesCapped: summariserStatus().capped }, live: { updatedAt: liveUpdatedAt ? new Date(liveUpdatedAt).toISOString() : null, error: liveError ?? null }, sessions: rows };
}

// ---------- boot ----------
import { demoView } from "./demo";
if (!DEMO) {
  loadCache();
  const t0 = Date.now(); const changed = fullScan();
  console.log(`indexed ${sessions.size} sessions (${changed} changed) in ${Date.now() - t0} ms`);
  await pollLive();
  enqueueSummaries();
  setInterval(pollLive, 5000);
  setInterval(() => { if (fullScan()) enqueueSummaries(); }, 30_000); // safety net behind fs.watch
  setInterval(enqueueSummaries, 60_000); // releases sessions whose idle window has elapsed
  let watchTimer: Timer | undefined;
  try {
    watch(PROJECTS_DIR, { recursive: true }, () => { clearTimeout(watchTimer); watchTimer = setTimeout(() => { if (fullScan()) enqueueSummaries(); }, 400); });
  } catch (e) { console.error("fs.watch failed, polling only", e); }
} else console.log("demo mode: serving generic sessions");

Bun.serve({
  port: PORT, hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });
    if (url.pathname === "/health") return json({ ok: true, sessions: sessions.size, liveUpdatedAt, liveError: liveError ?? null, summariesPending: summaryQueue.length + summarising, summariser: summariserStatus(), hooksReceived, lastHook });
    if (url.pathname === "/sessions") return json(DEMO ? demoView() : view());
    if (url.pathname === "/hook" && req.method === "POST") { try { applyHook(await req.json()); } catch (e) { return json({ ok: false }, 400); } return json({ ok: true }); }
    if (url.pathname === "/resummarise" && req.method === "POST") { const id = url.searchParams.get("id"); if (id) summaries.delete(id); else summaries.clear(); enqueueSummaries(); return json({ ok: true }); }
    return json({ error: "not found" }, 404);
  },
});
console.log(`session-hud server on http://127.0.0.1:${PORT}`);
