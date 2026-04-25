#!/usr/bin/env node
/**
 * mcp-shell-proxy.js — Token-Efficient Shell Proxy MCP Server
 *
 * v2: Event logging, measured baselines, agent attribution, USD cost tracking
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { execSync } from 'child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync, readdirSync, appendFileSync, renameSync, openSync, closeSync, unlinkSync } from 'fs';
import { join, resolve, relative, extname, basename } from 'path';
import { fileURLToPath } from 'url';
import { createHash } from 'crypto';
import { homedir } from 'os';

// ── Paths ──────────────────────────────────────────────────────
// REPO = project root where Cursor opened the workspace.
// Cursor always spawns MCP servers with cwd = project root, so process.cwd()
// is reliable regardless of where flowctl is installed (local, global, npm link).
// Fallback: FLOWCTL_PROJECT_ROOT env var for manual / non-Cursor invocations.
const __file      = fileURLToPath(import.meta.url);
const REPO        = resolve(process.env.FLOWCTL_PROJECT_ROOT || process.cwd());
const CACHE       = join(REPO, '.cache', 'mcp');
const GEN_FILE    = join(CACHE, '_gen.json');
const BASELINE_F  = join(CACHE, '_baselines.json');
const EVENTS_F    = join(CACHE, 'events.jsonl');
const STATS_F     = join(CACHE, 'session-stats.json');
const STATE       = join(REPO, 'flowctl-state.json');
const FLOWCTL_HOME = join(homedir(), '.flowctl');
const REGISTRY_F   = join(FLOWCTL_HOME, 'registry.json');

// ── Project identity — read once at startup ────────────────────
function readProjectIdentity() {
  try {
    const s = existsSync(STATE) ? JSON.parse(readFileSync(STATE, 'utf8')) : {};
    return {
      id:   s.flow_id      || `path-${createHash('sha1').update(REPO).digest('hex').slice(0, 8)}`,
      name: s.project_name || basename(REPO),
    };
  } catch {
    return { id: `path-${createHash('sha1').update(REPO).digest('hex').slice(0, 8)}`, name: basename(REPO) };
  }
}

const _proj        = readProjectIdentity();
const PROJECT_ID   = _proj.id;
const PROJECT_NAME = _proj.name;

// Anthropic Sonnet 4.6 pricing (per 1M tokens)
const PRICE = { input: 3.0, output: 15.0 };

// Bash-equivalent token cost for each tool — what an agent would consume
// if it used raw bash commands instead of this MCP proxy.
// These are conservative estimates based on real command output sizes.
const BASH_EQUIV = {
  wf_state:          1900, // cat flowctl-state.json (~1600) + flowctl status (~300)
  wf_git:            1000, // git log --oneline -5 + git status --short + git diff --stat
  wf_step_context:   4800, // reading state + context-digest + war-room + blockers (5+ files)
  wf_files:           500, // ls -la + find . -maxdepth 2
  wf_read:            700, // cat <file> raw (uncompressed, full content)
  wf_env:             300, // node/npm/python/git --version + uname commands
  wf_reports_status:  600, // ls reports/ + reading 2-3 report files for status
};

// Per-connection agent context (parallel subagents = parallel connections)
let connectionAgent = 'unknown';

// ── Token estimation ───────────────────────────────────────────

function estimateTokens(text) {
  if (!text) return 0;
  const chars   = text.length;
  const quotes  = (text.match(/"/g) || []).length;
  const nonAscii = [...text].filter(c => c.charCodeAt(0) > 127).length;
  const jsonRatio = quotes / Math.max(chars, 1);
  const vietRatio = nonAscii / Math.max(chars, 1);
  if (jsonRatio > 0.05) return Math.ceil(chars / 3);   // JSON/code
  if (vietRatio > 0.15) return Math.ceil(chars / 2);   // Vietnamese
  return Math.ceil(chars / 4);                          // English prose
}

function costUsd(inputTok, outputTok) {
  return (inputTok * PRICE.input + outputTok * PRICE.output) / 1_000_000;
}

// ── Baselines (measured, not hardcoded) ───────────────────────

function readBaselines() {
  if (!existsSync(BASELINE_F)) return {};
  try { return JSON.parse(readFileSync(BASELINE_F, 'utf8')); }
  catch { return {}; }
}

function updateBaseline(tool, outputTokens) {
  const b = readBaselines();
  const prev = b[tool] || { samples: [], avg: outputTokens };
  prev.samples = [...(prev.samples || []).slice(-9), outputTokens]; // keep last 10
  prev.avg = Math.round(prev.samples.reduce((a, x) => a + x, 0) / prev.samples.length);
  b[tool] = prev;
  writeFileSync(BASELINE_F, JSON.stringify(b, null, 2));
  return prev.avg;
}

function getBaseline(tool) {
  const b = readBaselines();
  // Fallback estimates only used until first real measurement
  const FALLBACK = {
    wf_state: 480, wf_git: 250, wf_step_context: 1200,
    wf_files: 120, wf_read: 500, wf_env: 80,
  };
  return b[tool]?.avg ?? FALLBACK[tool] ?? 200;
}

// ── Global registry ────────────────────────────────────────────

function ensureFlowctlHome() {
  if (!existsSync(FLOWCTL_HOME)) mkdirSync(FLOWCTL_HOME, { recursive: true });
}

function readRegistry() {
  try {
    return existsSync(REGISTRY_F)
      ? JSON.parse(readFileSync(REGISTRY_F, 'utf8'))
      : { version: 1, projects: {} };
  } catch { return { version: 1, projects: {} }; }
}

// Synchronous busy-wait sleep — safe on Node.js main thread (no Atomics.wait)
function sleepMs(ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { /* spin */ }
}

function registryUpsert(extra = {}) {
  ensureFlowctlHome();
  const lockFile = REGISTRY_F + '.lock';

  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      // Atomic exclusive lock: openSync 'wx' (O_EXCL) — fails if file already exists
      const fd = openSync(lockFile, 'wx');
      closeSync(fd);
      try {
        const registry = readRegistry();

        // Read fresh step/status from state file
        let meta = {};
        try {
          const s = JSON.parse(readFileSync(STATE, 'utf8'));
          const openBlockers = Object.values(s.steps ?? {})
            .flatMap(st => st.blockers ?? [])
            .filter(b => !b.resolved).length;
          meta = {
            current_step:   s.current_step    ?? 0,
            overall_status: s.overall_status  ?? 'unknown',
            project_name:   s.project_name    ?? PROJECT_NAME,
            open_blockers:  openBlockers,
          };
        } catch { /* state unreadable — use existing meta */ }

        registry.projects[PROJECT_ID] = {
          project_id:   PROJECT_ID,
          project_name: PROJECT_NAME,
          path:         REPO,
          cache_dir:    CACHE,
          last_seen:    new Date().toISOString(),
          ...meta,
          ...extra,
        };

        // Prune entries not seen in 30 days
        const cutoff = Date.now() - 30 * 24 * 60 * 60 * 1000;
        for (const [id, p] of Object.entries(registry.projects)) {
          if (new Date(p.last_seen).getTime() < cutoff) delete registry.projects[id];
        }

        // Atomic write: temp file + rename (POSIX-atomic)
        const tmp = REGISTRY_F + '.tmp.' + process.pid;
        writeFileSync(tmp, JSON.stringify(registry, null, 2));
        renameSync(tmp, REGISTRY_F);
      } finally {
        try { unlinkSync(lockFile); } catch { /* ignore */ }
      }
      return; // success
    } catch (e) {
      if (e.code !== 'EEXIST') return; // unexpected error — fail silently
      sleepMs(10 * Math.pow(2, attempt)); // 10ms, 20ms, 40ms, 80ms, 160ms backoff
    }
  }
  // All retries exhausted — skip (registry is best-effort)
}

// ── Event logging ──────────────────────────────────────────────

function ensureCache() {
  if (!existsSync(CACHE)) mkdirSync(CACHE, { recursive: true });
}

function logEvent(event) {
  ensureCache();
  // Rotate if > 1000 lines
  try {
    const content = existsSync(EVENTS_F) ? readFileSync(EVENTS_F, 'utf8') : '';
    const lines = content.split('\n').filter(Boolean);
    if (lines.length > 1000) {
      writeFileSync(EVENTS_F, lines.slice(-800).join('\n') + '\n');
    }
  } catch { /* ignore */ }
  appendFileSync(EVENTS_F, JSON.stringify({ ...event, project_id: PROJECT_ID, project_name: PROJECT_NAME, ts: new Date().toISOString() }) + '\n');
  updateSessionStats(event);
}

// Reset current_session on each shell-proxy startup (called once at module init)
function initSessionStats() {
  ensureCache();
  let stats = {};
  try { stats = existsSync(STATS_F) ? JSON.parse(readFileSync(STATS_F, 'utf8')) : {}; }
  catch { stats = {}; }
  // Always reset current_session on startup — it tracks only this process lifetime
  stats.current_session = { session_start: new Date().toISOString(), consumed: 0, saved: 0 };
  // Ensure all_time exists (migration from flat schema)
  if (!stats.all_time && stats.total_consumed_tokens !== undefined) {
    // Migrate flat stats to new schema
    stats.all_time = {
      total_consumed_tokens: stats.total_consumed_tokens || 0,
      total_saved_tokens:    stats.total_saved_tokens    || 0,
      total_cost_usd:        stats.total_cost_usd        || 0,
      total_saved_usd:       stats.total_saved_usd       || 0,
      bash_waste_tokens:     stats.bash_waste_tokens     || 0,
      tools:                 stats.tools                 || {},
    };
    delete stats.total_consumed_tokens;
    delete stats.total_saved_tokens;
    delete stats.total_cost_usd;
    delete stats.total_saved_usd;
    delete stats.bash_waste_tokens;
    delete stats.session_start;
    delete stats.last_event;
    delete stats.tools;
  }
  stats.all_time = stats.all_time || {};
  stats.daily    = stats.daily    || {};
  writeFileSync(STATS_F, JSON.stringify(stats, null, 2));
}

function updateSessionStats(event) {
  ensureCache();
  let stats = {};
  try { stats = existsSync(STATS_F) ? JSON.parse(readFileSync(STATS_F, 'utf8')) : {}; }
  catch { stats = {}; }

  const today = new Date().toISOString().slice(0, 10); // "2026-04-25"

  // all_time: never resets ─────────────────────────────────────
  const at = stats.all_time = stats.all_time || {};
  at.total_consumed_tokens = (at.total_consumed_tokens || 0) + (event.output_tokens || 0);
  at.total_saved_tokens    = (at.total_saved_tokens    || 0) + (event.saved_tokens  || 0);
  at.total_cost_usd        = (at.total_cost_usd        || 0) + (event.cost_usd      || 0);
  at.total_saved_usd       = (at.total_saved_usd       || 0) + (event.saved_usd     || 0);
  at.bash_waste_tokens     = (at.bash_waste_tokens     || 0) + (event.waste_tokens  || 0);

  // per-tool in all_time — FIX: count saved for ALL calls, not just cache hits
  if (event.type === 'mcp') {
    const tools = at.tools = at.tools || {};
    const ts = tools[event.tool] = tools[event.tool] || { calls: 0, hits: 0, misses: 0, saved: 0 };
    ts.calls++;
    ts.saved += event.saved_tokens || 0;  // count on every call (hit or miss)
    if (event.cache === 'hit') ts.hits++;
    else ts.misses++;
  }

  // daily: keyed YYYY-MM-DD, pruned after 30 days ──────────────
  const daily = stats.daily = stats.daily || {};
  const day   = daily[today] = daily[today] || { consumed: 0, saved: 0, cost_usd: 0 };
  day.consumed += event.output_tokens || 0;
  day.saved    += event.saved_tokens  || 0;
  day.cost_usd += event.cost_usd      || 0;

  const cutoffDate = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  for (const d of Object.keys(daily)) { if (d < cutoffDate) delete daily[d]; }

  // current_session: tracks only this shell-proxy process lifetime ──────────
  const cs = stats.current_session = stats.current_session ||
    { session_start: new Date().toISOString(), consumed: 0, saved: 0 };
  cs.last_event = new Date().toISOString();
  cs.consumed  += event.output_tokens || 0;
  cs.saved     += event.saved_tokens  || 0;

  writeFileSync(STATS_F, JSON.stringify(stats, null, 2));
}

// ── Cache helpers ─────────────────────────────────────────────

function readGen() {
  if (!existsSync(GEN_FILE)) return { git: 0, state: 0 };
  try { return JSON.parse(readFileSync(GEN_FILE, 'utf8')); }
  catch { return { git: 0, state: 0 }; }
}

function cacheGet(key) {
  ensureCache();
  const f = join(CACHE, `${key}.json`);
  if (!existsSync(f)) return null;
  try {
    const entry = JSON.parse(readFileSync(f, 'utf8'));
    const gen = readGen();
    const now = Date.now();
    if (entry.strategy === 'static') return entry.data;
    if (entry.strategy === 'git'    && entry.gen === gen.git)   return entry.data;
    if (entry.strategy === 'state'  && entry.gen === gen.state) return entry.data;
    if (entry.strategy === 'ttl'    && now - entry.ts < entry.ttl * 1000) return entry.data;
    if (entry.strategy === 'mtime') {
      const target = join(REPO, entry.path);
      if (existsSync(target) && statSync(target).mtimeMs === entry.mtime) return entry.data;
    }
  } catch { /* stale */ }
  return null;
}

function cacheSet(key, data, strategy, extra = {}) {
  ensureCache();
  const gen = readGen();
  const entry = { strategy, data, ts: Date.now() };
  if (strategy === 'git')   entry.gen = gen.git;
  if (strategy === 'state') entry.gen = gen.state;
  if (strategy === 'ttl')   entry.ttl = extra.ttl ?? 60;
  if (strategy === 'mtime') { entry.path = extra.path; entry.mtime = extra.mtime; }
  writeFileSync(join(CACHE, `${key}.json`), JSON.stringify(entry));
}

function invalidateAll(scope = 'all') {
  ensureCache();
  const gen = readGen();
  if (scope === 'all' || scope === 'git')   gen.git   = (gen.git   || 0) + 1;
  if (scope === 'all' || scope === 'state') gen.state = (gen.state || 0) + 1;
  // Atomic write
  const tmp = GEN_FILE + '.tmp';
  writeFileSync(tmp, JSON.stringify(gen));
  renameSync(tmp, GEN_FILE);
  return gen;
}

// ── Wrap tool with event logging ───────────────────────────────

function withLogging(toolName, fn) {
  return function(args) {
    const t0 = Date.now();
    const inputStr = JSON.stringify(args || {});
    const inputTokens = estimateTokens(inputStr);

    const result = fn(args);
    const isHit = result?._cache === 'hit';

    const outputStr = JSON.stringify(result);
    const outputTokens = estimateTokens(outputStr);

    // Savings = what bash would have cost minus what MCP actually costs.
    // Applies on EVERY call (hit or miss) because the compact output is always
    // smaller than raw bash output regardless of caching.
    // Cache hits save additional latency but not additional tokens vs a miss.
    const bashEquiv  = BASH_EQUIV[toolName] ?? outputTokens * 2;
    const savedTokens = Math.max(0, bashEquiv - outputTokens);
    const savedUsd    = costUsd(savedTokens, 0);
    const costUsdVal  = costUsd(inputTokens, outputTokens);

    if (!isHit) {
      // Update baseline with actual MCP output size (informational, used for
      // detecting if tool output grows unexpectedly over time).
      updateBaseline(toolName, outputTokens);
    }

    logEvent({
      type: 'mcp',
      tool: toolName,
      agent: connectionAgent,
      cache: isHit ? 'hit' : 'miss',
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      bash_equiv: bashEquiv,
      saved_tokens: savedTokens,
      cost_usd: costUsdVal,
      saved_usd: savedUsd,
      duration_ms: Date.now() - t0,
    });

    return result;
  };
}

// ── Shell helper ───────────────────────────────────────────────

function sh(cmd) {
  try { return execSync(cmd, { cwd: REPO, encoding: 'utf8', stdio: ['pipe','pipe','pipe'] }).trim(); }
  catch (e) { return (e.stdout || '').trim() || ''; }
}

// ── Tool implementations ───────────────────────────────────────

function tool_wf_state() {
  const cached = cacheGet('wf_state');
  if (cached) return { ...cached, _cache: 'hit' };

  if (!existsSync(STATE)) return { error: 'flowctl-state.json not found', _cache: 'miss' };
  const d = JSON.parse(readFileSync(STATE, 'utf8'));
  const step = String(d.current_step ?? 0);
  const s = (d.steps ?? {})[step] ?? {};
  const openBlockers = (s.blockers ?? []).filter(b => !b.resolved);

  const result = {
    project: d.project_name ?? '',
    status: d.overall_status ?? 'unknown',
    current_step: Number(step),
    step_name: s.name ?? '',
    step_status: s.status ?? 'pending',
    agent: s.agent ?? '',
    support_agents: s.support_agents ?? [],
    started_at: s.started_at ?? null,
    approval_status: s.approval_status ?? 'pending',
    open_blockers: openBlockers.length,
    blockers: openBlockers.map(b => b.description),
    recent_decisions: (s.decisions ?? []).slice(-3).map(d => d.description),
    deliverable_count: (s.deliverables ?? []).length,
    _cache: 'miss',
  };
  cacheSet('wf_state', result, 'state');
  return result;
}

function tool_git_context({ commits = 5 } = {}) {
  const key = `git_ctx_${commits}`;
  const cached = cacheGet(key);
  if (cached) return { ...cached, _cache: 'hit' };

  const branch   = sh('git rev-parse --abbrev-ref HEAD');
  const logRaw   = sh(`git log --oneline -${commits} --format="%h|%s|%cr"`);
  const statusRaw= sh('git status --short');
  const ab       = sh('git rev-list --left-right --count HEAD...@{u} 2>/dev/null || echo "0\t0"');

  const recentCommits = logRaw.split('\n').filter(Boolean).map(l => {
    const [hash, msg, when] = l.split('|');
    return { hash, msg, when };
  });
  const changed = statusRaw.split('\n').filter(Boolean).map(l => ({
    status: l.slice(0,2).trim(), file: l.slice(3),
  }));
  const [ahead='0', behind='0'] = ab.split(/\s+/);

  const result = {
    branch, recent_commits: recentCommits,
    changed_files: changed.length, changes: changed.slice(0,10),
    ahead: Number(ahead), behind: Number(behind),
    is_clean: changed.length === 0, _cache: 'miss',
  };
  cacheSet(key, result, 'git');
  // git status part expires sooner
  cacheSet(`git_status_${commits}`, { changed_files: changed.length, is_clean: result.is_clean }, 'ttl', { ttl: 15 });
  return result;
}

function tool_step_context({ step } = {}) {
  const stateData = existsSync(STATE) ? JSON.parse(readFileSync(STATE, 'utf8')) : null;
  const currentStep = step ?? stateData?.current_step ?? 0;
  const key = `step_ctx_${currentStep}`;
  const cached = cacheGet(key);
  if (cached) return { ...cached, _cache: 'hit' };
  if (!stateData) return { error: 'flowctl-state.json not found', _cache: 'miss' };

  const s = (stateData.steps ?? {})[String(currentStep)] ?? {};
  const priorDecisions = [];
  for (let n = 1; n < currentStep; n++) {
    const ps = (stateData.steps ?? {})[String(n)] ?? {};
    for (const d of ps.decisions ?? []) {
      if (d.type !== 'rejection') priorDecisions.push({ step: n, text: d.description });
    }
  }
  const allBlockers = [];
  for (const [n, ps] of Object.entries(stateData.steps ?? {})) {
    for (const b of ps.blockers ?? []) {
      if (!b.resolved) allBlockers.push({ step: Number(n), text: b.description });
    }
  }

  const digestPath = join(REPO, 'workflows', 'dispatch', `step-${currentStep}`, 'context-digest.md');
  let digestSummary = null;
  if (existsSync(digestPath)) {
    const raw = readFileSync(digestPath, 'utf8').split('\n');
    digestSummary = raw.filter(l => l.startsWith('- ') || l.startsWith('## ') || l.startsWith('### ')).slice(0, 25).join('\n');
  }

  const wrDir   = join(REPO, 'workflows', 'dispatch', `step-${currentStep}`, 'war-room');
  const mercDir = join(REPO, 'workflows', 'dispatch', `step-${currentStep}`, 'mercenaries');

  const result = {
    step: currentStep, step_name: s.name ?? '',
    agent: s.agent ?? '', support_agents: s.support_agents ?? [],
    status: s.status ?? 'pending',
    prior_decisions: priorDecisions.slice(-10),
    open_blockers: allBlockers,
    war_room_complete: existsSync(join(wrDir, 'pm-analysis.md')) && existsSync(join(wrDir, 'tech-lead-assessment.md')),
    context_digest_summary: digestSummary,
    mercenary_outputs: existsSync(mercDir) ? readdirSync(mercDir).filter(f => f.endsWith('-output.md')) : [],
    deliverables: s.deliverables ?? [],
    wf_tools_hint: [
      'wf_step_context()   ← state + decisions + blockers in 1 call',
      'wf_state()          ← step/status only',
      'wf_git()            ← branch + recent commits',
    ],
    _cache: 'miss',
  };
  cacheSet(key, result, 'state');
  return result;
}

function tool_project_files({ dir = '.', pattern = '', depth = 2 } = {}) {
  const key = `files_${dir}_${pattern}_${depth}`;
  const cached = cacheGet(key);
  if (cached) return { ...cached, _cache: 'hit' };

  const absDir = resolve(REPO, dir);
  const IGNORE = new Set(['node_modules','.git','.cache','__pycache__','.graphify','dist','build']);

  function scan(d, curDepth) {
    if (curDepth > depth) return [];
    let entries; try { entries = readdirSync(d, { withFileTypes: true }); } catch { return []; }
    const results = [];
    for (const e of entries) {
      if (IGNORE.has(e.name)) continue;
      const rel = relative(REPO, join(d, e.name));
      if (pattern && !e.name.includes(pattern) && !rel.includes(pattern)) {
        if (e.isDirectory()) results.push(...scan(join(d, e.name), curDepth + 1));
        continue;
      }
      if (e.isDirectory()) { results.push({ type: 'dir', path: rel }); results.push(...scan(join(d, e.name), curDepth + 1)); }
      else { let size = 0; try { size = statSync(join(d, e.name)).size; } catch {} results.push({ type: 'file', path: rel, size, ext: extname(e.name) }); }
    }
    return results;
  }

  const entries = scan(absDir, 0);
  const result = { dir: relative(REPO, absDir) || '.', total_files: entries.filter(e => e.type === 'file').length, total_dirs: entries.filter(e => e.type === 'dir').length, entries, _cache: 'miss' };
  cacheSet(key, result, 'ttl', { ttl: 120 });
  return result;
}

function tool_read_file({ path: filePath, max_lines = 100, compress = true } = {}) {
  if (!filePath) return { error: 'path required' };
  const absPath = resolve(REPO, filePath);
  if (!existsSync(absPath)) return { error: `File not found: ${filePath}`, _cache: 'miss' };

  const mtime = statSync(absPath).mtimeMs;
  const key   = `file_${filePath.replace(/[^a-z0-9]/gi, '_')}`;
  const cached = cacheGet(key);
  if (cached) return { ...cached, _cache: 'hit' };

  const raw   = readFileSync(absPath, 'utf8');
  const lines = raw.split('\n');

  // Smart compression by file type
  let content = raw;
  let compressed = false;
  if (compress) {
    if (filePath.endsWith('.json') && lines.length > 50) {
      try {
        const obj = JSON.parse(raw);
        content = compressJson(obj);
        compressed = true;
      } catch { /* fallback */ }
    }
    if (!compressed && lines.length > max_lines) {
      content = lines.slice(0, max_lines).join('\n') + `\n... [${lines.length - max_lines} more lines truncated]`;
      compressed = true;
    }
  }

  const result = { path: filePath, lines: lines.length, size_bytes: statSync(absPath).size, compressed, content, _cache: 'miss' };
  cacheSet(key, result, 'mtime', { path: filePath, mtime });
  return result;
}

function compressJson(obj, depth = 0) {
  if (depth > 2) return typeof obj === 'object' ? `{...}` : String(obj);
  if (Array.isArray(obj)) return `[${obj.length} items]`;
  if (typeof obj !== 'object' || obj === null) return String(obj);
  const lines = [];
  for (const [k, v] of Object.entries(obj).slice(0, 20)) {
    if (Array.isArray(v))           lines.push(`  ${k}: [${v.length} items]`);
    else if (typeof v === 'object' && v !== null) lines.push(`  ${k}: {${Object.keys(v).join(', ')}}`);
    else                            lines.push(`  ${k}: ${JSON.stringify(v)}`);
  }
  return `{\n${lines.join(',\n')}\n}`;
}

function tool_env_info() {
  const cached = cacheGet('env_static');
  if (cached) return { ...cached, _cache: 'hit' };
  const result = { node: sh('node --version'), npm: sh('npm --version'), python: sh('python3 --version'), git: sh('git --version'), os: sh('uname -s'), arch: sh('uname -m'), cwd: REPO, _cache: 'miss' };
  cacheSet('env_static', result, 'static');
  return result;
}

function tool_wf_reports_status({ step } = {}) {
  const stateData = existsSync(STATE) ? JSON.parse(readFileSync(STATE, 'utf8')) : null;
  const currentStep = step ?? stateData?.current_step ?? 0;
  const key = `reports_status_${currentStep}`;
  const cached = cacheGet(key);
  if (cached) return { ...cached, _cache: 'hit' };

  const s = (stateData?.steps ?? {})[String(currentStep)] ?? {};
  const primary = s.agent ?? '';
  const supports = s.support_agents ?? [];
  const expected = [primary, ...supports].filter(Boolean);

  const reportsDir = join(REPO, 'workflows', 'dispatch', `step-${currentStep}`, 'reports');
  const submitted = [];
  const needsSpecialist = [];

  if (existsSync(reportsDir)) {
    for (const f of readdirSync(reportsDir).filter(f => f.endsWith('-report.md'))) {
      const role = f.replace('-report.md', '');
      submitted.push(role);
      const content = readFileSync(join(reportsDir, f), 'utf8');
      if (content.includes('## NEEDS_SPECIALIST')) needsSpecialist.push(role);
    }
  }

  const result = { step: currentStep, expected_roles: expected, submitted, missing: expected.filter(r => !submitted.includes(r)), needs_specialist: needsSpecialist, all_done: expected.every(r => submitted.includes(r)), _cache: 'miss' };
  cacheSet(key, result, 'ttl', { ttl: 30 });
  return result;
}

function tool_set_agent({ agent_id } = {}) {
  connectionAgent = agent_id || 'unknown';
  return { agent_set: connectionAgent };
}

function tool_cache_invalidate({ scope = 'all' } = {}) {
  const gen = invalidateAll(scope);
  logEvent({ type: 'invalidate', scope, agent: connectionAgent });
  return { invalidated: scope, new_generations: gen };
}

function tool_cache_stats() {
  ensureCache();
  let stats = {};
  try { stats = existsSync(STATS_F) ? JSON.parse(readFileSync(STATS_F, 'utf8')) : {}; } catch {}
  const tools = stats.tools || {};
  const toolStats = Object.entries(tools).map(([name, t]) => ({
    name, calls: t.calls, hit_rate: t.calls ? `${Math.round(t.hits / t.calls * 100)}%` : '0%', saved_tokens: t.saved,
  }));
  return {
    session_start: stats.session_start,
    total_consumed_tokens: stats.total_consumed_tokens || 0,
    total_saved_tokens: stats.total_saved_tokens || 0,
    total_cost_usd: Number((stats.total_cost_usd || 0).toFixed(4)),
    total_saved_usd: Number((stats.total_saved_usd || 0).toFixed(4)),
    bash_waste_tokens: stats.bash_waste_tokens || 0,
    // efficiency = saved / (saved + consumed) — what fraction of potential cost we avoided
    efficiency_pct: (stats.total_saved_tokens || 0) + (stats.total_consumed_tokens || 0) > 0
      ? Math.round((stats.total_saved_tokens || 0) / ((stats.total_saved_tokens || 0) + (stats.total_consumed_tokens || 0)) * 100)
      : 0,
    tools: toolStats,
  };
}

// ── Tool registry ──────────────────────────────────────────────

const TOOLS = [
  { name: 'wf_state',          description: 'Current flowctl state. Replaces cat flowctl-state.json + bash status. ~95% fewer tokens.',                           inputSchema: { type: 'object', properties: {} },                                                                                                fn: withLogging('wf_state', tool_wf_state) },
  { name: 'wf_git',            description: 'Git snapshot (branch, commits, changes). Replaces git log/status/diff. ~92% fewer tokens.',                           inputSchema: { type: 'object', properties: { commits: { type: 'number' } } },                                                               fn: withLogging('wf_git', (a) => tool_git_context(a)) },
  { name: 'wf_step_context',   description: 'Full step context including prior decisions, blockers, war room, digest summary. Replaces reading 5+ files.',          inputSchema: { type: 'object', properties: { step: { type: 'number' } } },                                                                 fn: withLogging('wf_step_context', (a) => tool_step_context(a)) },
  { name: 'wf_files',          description: 'Project file listing. Replaces ls + find.',                                                                            inputSchema: { type: 'object', properties: { dir: { type: 'string' }, pattern: { type: 'string' }, depth: { type: 'number' } } },          fn: withLogging('wf_files', (a) => tool_project_files(a)) },
  { name: 'wf_read',           description: 'Read file with caching + smart compression (JSON/Markdown aware). Replaces cat.',                                      inputSchema: { type: 'object', properties: { path: { type: 'string' }, max_lines: { type: 'number' }, compress: { type: 'boolean' } }, required: ['path'] }, fn: withLogging('wf_read', (a) => tool_read_file(a)) },
  { name: 'wf_env',            description: 'Static env info (OS, versions). Cached forever.',                                                                     inputSchema: { type: 'object', properties: {} },                                                                                               fn: withLogging('wf_env', tool_env_info) },
  { name: 'wf_reports_status', description: 'Check which roles have submitted reports and if any need specialist. Replaces ls reports/ + reading files.',           inputSchema: { type: 'object', properties: { step: { type: 'number' } } },                                                                 fn: withLogging('wf_reports_status', (a) => tool_wf_reports_status(a)) },
  { name: 'wf_set_agent',      description: 'Set agent identity for this connection (for attribution tracking). Call at start of each agent session.',              inputSchema: { type: 'object', properties: { agent_id: { type: 'string' } }, required: ['agent_id'] },                                    fn: tool_set_agent },
  { name: 'wf_cache_stats',    description: 'Token savings stats for current session — consumed, saved, cost USD, per-tool hit rates.',                             inputSchema: { type: 'object', properties: {} },                                                                                               fn: tool_cache_stats },
  { name: 'wf_cache_invalidate', description: 'Invalidate cached data. Call after modifying state.',                                                               inputSchema: { type: 'object', properties: { scope: { type: 'string', enum: ['all','git','state','files'] } } },                           fn: tool_cache_invalidate },
];

// ── MCP Server ─────────────────────────────────────────────────

const server = new Server({ name: 'shell-proxy', version: '2.0.0' }, { capabilities: { tools: {} } });

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map(t => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })),
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = TOOLS.find(t => t.name === req.params.name);
  if (!tool) return { content: [{ type: 'text', text: JSON.stringify({ error: `Unknown tool: ${req.params.name}` }) }], isError: true };
  try {
    const result = tool.fn(req.params.arguments ?? {});
    return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
  } catch (err) {
    return { content: [{ type: 'text', text: JSON.stringify({ error: String(err.message) }) }], isError: true };
  }
});

// ── Registry startup + heartbeat ──────────────────────────────
// Initialize stats: migrate legacy schema + reset current_session
initSessionStats();
// Register this project in ~/.flowctl/registry.json on startup
registryUpsert();
// Heartbeat: refresh last_seen + step/status every 60 seconds
setInterval(() => registryUpsert(), 60_000).unref();

const transport = new StdioServerTransport();
await server.connect(transport);
