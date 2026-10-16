// 9sync web UI server. Node standard library only - no npm install, no
// dependencies to keep current.
//
// The engine is a separate process. This file never reads or writes a tool
// config itself, so there is exactly one implementation of the sync and the
// CLI and the browser can never disagree about what happened.

import http from 'node:http';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const ENGINE = path.join(ROOT, 'engine', 'sync.ps1');
const SETUP = path.join(ROOT, 'engine', 'setup.ps1');
const PUBLIC = path.join(HERE, 'public');
const CONFIG_PATH = process.env.NINESYNC_CONFIG || path.join(ROOT, 'sync-9router.config.json');

const PORT = Number(process.env.NINESYNC_PORT || 8787);
const HOST = '127.0.0.1'; // loopback only; see the Origin check below

// A token in the page URL. A page on any other site can issue requests to
// 127.0.0.1, and without this it could read your bridge key and rewrite your
// tool configs. Same-origin is checked too, but the token is what stops a
// cross-site request that manages to look same-origin.
const TOKEN = process.env.NINESYNC_TOKEN || Math.random().toString(36).slice(2) + Date.now().toString(36);

// ---------------------------------------------------------------------------
// engine calls
// ---------------------------------------------------------------------------

function runEngine(args, { timeoutMs = 120000 } = {}) {
  return new Promise((resolve) => {
    const ps = spawn(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ENGINE, ...args],
      { cwd: ROOT, windowsHide: true }
    );
    let out = '';
    let err = '';
    const timer = setTimeout(() => {
      ps.kill();
    }, timeoutMs);

    ps.stdout.on('data', (d) => { out += d.toString(); });
    ps.stderr.on('data', (d) => { err += d.toString(); });
    ps.on('close', (code) => {
      clearTimeout(timer);
      const text = out.trim();
      let json = null;
      if (text.startsWith('{') || text.startsWith('[')) {
        try { json = JSON.parse(text); } catch { /* fall through to raw */ }
      }
      resolve({ code, json, stdout: text, stderr: err.trim() });
    });
    ps.on('error', (e) => {
      clearTimeout(timer);
      resolve({ code: -1, json: null, stdout: '', stderr: e.message });
    });
  });
}

// BOM-tolerant. Notepad and PowerShell 5.1 both write UTF-8 with a BOM, and
// JSON.parse rejects the leading U+FEFF outright - which looks exactly like a
// missing config file.
function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function readConfig() {
  try {
    return JSON.parse(stripBom(fs.readFileSync(CONFIG_PATH, 'utf8')));
  } catch {
    return {};
  }
}

function writeConfig(cfg) {
  const ordered = {
    remoteUrl: cfg.remoteUrl ?? '',
    bridgeKey: cfg.bridgeKey ?? '',
    defaultModel: cfg.defaultModel ?? '',
    tools: Array.isArray(cfg.tools) ? cfg.tools : [],
    backupKeep: Number(cfg.backupKeep) || 5,
    urlHistory: Array.isArray(cfg.urlHistory) ? cfg.urlHistory : []
  };
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(ordered, null, 2) + '\n', 'utf8');
}

const CONFIG_ARGS = CONFIG_PATH !== path.join(ROOT, 'sync-9router.config.json')
  ? ['-ConfigPath', CONFIG_PATH]
  : [];

// ---------------------------------------------------------------------------
// masking
// ---------------------------------------------------------------------------

// The browser is not sent the bridge key or any API key. The UI only ever needs
// to show the first few characters so a user can tell two keys apart.
function mask(s) {
  const v = String(s ?? '').trim();
  if (!v) return '';
  if (v.length <= 8) return '*'.repeat(v.length);
  return v.slice(0, 4) + '*'.repeat(12) + v.slice(-4);
}

function publicConfig(cfg) {
  return {
    remoteUrl: cfg.remoteUrl ?? '',
    bridgeKeyMasked: mask(cfg.bridgeKey),
    hasBridgeKey: Boolean(String(cfg.bridgeKey ?? '').trim()),
    defaultModel: cfg.defaultModel ?? '',
    tools: Array.isArray(cfg.tools) ? cfg.tools : [],
    backupKeep: Number(cfg.backupKeep) || 5,
    urlHistory: Array.isArray(cfg.urlHistory) ? cfg.urlHistory : []
  };
}

// ---------------------------------------------------------------------------
// routes
// ---------------------------------------------------------------------------

const routes = {
  async 'GET /api/state'() {
    const [diag, conn] = await Promise.all([
      runEngine([...CONFIG_ARGS, '-Diagnostics']),
      runEngine([...CONFIG_ARGS, '-TestConnection'], { timeoutMs: 45000 })
    ]);
    const cfg = readConfig();
    const state = diag.json || {};
    return {
      config: publicConfig(cfg),
      tools: state.tools || [],
      lastRun: state.lastRun || null,
      log: state.log || [],
      versions: state.versions || {},
      paths: { config: state.configPath || CONFIG_PATH, state: state.statePath || null },
      connection: conn.json
        ? {
            ok: Boolean(conn.json.ok && conn.json.apiKeyOk),
            ms: conn.json.ms ?? null,
            note: conn.json.note ?? '',
            apiKeyOk: Boolean(conn.json.apiKeyOk),
            modelCount: conn.json.modelCount ?? 0,
            catalogMs: conn.json.catalogMs ?? 0
          }
        : { ok: false, note: conn.stderr || 'no response' }
    };
  },

  async 'GET /api/models'() {
    const r = await runEngine([...CONFIG_ARGS, '-PreviewModels'], { timeoutMs: 60000 });
    return r.json || { ok: false, error: r.stderr || 'no response', models: [] };
  },

  async 'POST /api/sync'(_body, url) {
    const dryRun = url.searchParams.get('dry') === '1';
    const r = await runEngine([...CONFIG_ARGS, '-Json', ...(dryRun ? ['-WhatIf'] : [])], { timeoutMs: 180000 });
    if (!r.json) {
      return { ok: false, error: r.stderr || r.stdout || 'engine produced no output', rows: [] };
    }
    return r.json;
  },

  async 'POST /api/probe'() {
    const r = await runEngine([...CONFIG_ARGS, '-ProbeModels'], { timeoutMs: 900000 });
    return r.json || { ok: false, error: r.stderr || 'no response', results: [] };
  },

  async 'POST /api/config/save'(_body, url) {
    const cfg = readConfig();
    const incoming = url.searchParams;
    const body = _body || {};

    const pick = (name, current) => {
      const v = body[name];
      if (v === undefined || v === null) return current;
      return String(v).trim();
    };

    const nextRemote = pick('remoteUrl', cfg.remoteUrl ?? '');
    if (nextRemote && !/^https?:\/\//i.test(nextRemote)) {
      return { ok: false, error: 'Endpoint must start with http:// or https://' };
    }
    const nextKeyRaw = body.bridgeKey !== undefined ? String(body.bridgeKey).trim() : '';
    if (body.bridgeKey !== undefined && !nextKeyRaw) {
      return { ok: false, error: 'Bridge key cannot be empty. Leave the field out to keep the current one.' };
    }
    if (nextKeyRaw && !/^[0-9a-f]{64}$/i.test(nextKeyRaw)) {
      return { ok: false, error: `Bridge key must be 64 hex characters; got ${nextKeyRaw.length}. A short paste is nearly always a dropped character.` };
    }

    let tools = Array.isArray(body.tools) ? body.tools : cfg.tools;
    tools = tools.map((t) => String(t).trim().toLowerCase()).filter(Boolean);
    const KNOWN = ['opencode', 'pi', 'omp', 'hermes', 'claude', 'codex'];
    const unknown = tools.filter((t) => !KNOWN.includes(t));
    if (unknown.length) return { ok: false, error: `Unknown tool: ${unknown.join(', ')}` };
    if (!tools.length) return { ok: false, error: 'Pick at least one tool.' };

    const keep = Number(body.backupKeep);
    const backupKeep = Number.isFinite(keep) && keep >= 1 && keep <= 50 ? keep : (Number(cfg.backupKeep) || 5);

    const next = {
      ...cfg,
      remoteUrl: nextRemote.replace(/\/+$/, ''),
      defaultModel: pick('defaultModel', cfg.defaultModel ?? ''),
      tools,
      backupKeep,
      urlHistory: Array.isArray(cfg.urlHistory) ? cfg.urlHistory : []
    };
    // Only overwritten when actually sent. The browser never receives the real
    // key, so it cannot round-trip it - writing back what it happens to display
    // would replace the key with its own mask.
    if (nextKeyRaw) next.bridgeKey = nextKeyRaw.toLowerCase();

    const hist = [next.remoteUrl, ...(next.urlHistory || []).filter((u) => u && u !== next.remoteUrl)];
    next.urlHistory = hist.slice(0, 6);

    try {
      writeConfig(next);
    } catch (e) {
      return { ok: false, error: `Could not save the config: ${e.message}` };
    }
    return { ok: true, config: publicConfig(next) };
  },

  async 'POST /api/restore'(_body, url) {
    const target = url.searchParams.get('path') || '';
    const backup = url.searchParams.get('backup') || '';
    if (!target || !backup) return { ok: false, error: 'path and backup are required' };
    // Only files the engine itself manages are restorable. An arbitrary path
    // from the browser would turn this endpoint into a file-write primitive.
    const known = [
      path.join(process.env.USERPROFILE || '', '.config', 'opencode', 'opencode.json'),
      path.join(process.env.USERPROFILE || '', '.pi', 'agent', 'models.json'),
      path.join(process.env.USERPROFILE || '', '.pi', 'agent', 'settings.json'),
      path.join(process.env.USERPROFILE || '', '.omp', 'agent', 'models.yml'),
      path.join(process.env.USERPROFILE || '', '.omp', 'agent', 'config.yml'),
      path.join(process.env.USERPROFILE || '', '.claude', 'settings.json'),
      path.join(process.env.USERPROFILE || '', '.codex', 'config.toml'),
      path.join(process.env.LOCALAPPDATA || '', 'hermes', 'config.yaml'),
      path.join(process.env.LOCALAPPDATA || '', 'hermes', '.env')
    ].map((p) => path.resolve(p).toLowerCase());
    const resolved = path.resolve(target);
    if (!known.includes(resolved.toLowerCase())) {
      return { ok: false, error: 'That file is not one this tool manages.' };
    }
    // The backup must sit next to the file it restores, or the check is theatre.
    const backupResolved = path.resolve(backup);
    if (path.dirname(backupResolved).toLowerCase() !== path.dirname(resolved).toLowerCase()) {
      return { ok: false, error: 'The backup must sit beside the file it restores.' };
    }
    if (!fs.existsSync(backupResolved)) return { ok: false, error: 'No such backup.' };
    try {
      const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15);
      fs.copyFileSync(resolved, `${resolved}.${stamp}.pre-restore.bak`);
      fs.copyFileSync(backupResolved, resolved);
    } catch (e) {
      return { ok: false, error: e.message };
    }
    return { ok: true, restored: path.basename(resolved) };
  },

  async 'GET /api/backups'() {
    const candidates = [
      path.join(process.env.USERPROFILE || '', '.config', 'opencode', 'opencode.json'),
      path.join(process.env.USERPROFILE || '', '.pi', 'agent', 'models.json'),
      path.join(process.env.USERPROFILE || '', '.pi', 'agent', 'settings.json'),
      path.join(process.env.USERPROFILE || '', '.omp', 'agent', 'models.yml'),
      path.join(process.env.USERPROFILE || '', '.omp', 'agent', 'config.yml'),
      path.join(process.env.USERPROFILE || '', '.claude', 'settings.json'),
      path.join(process.env.USERPROFILE || '', '.codex', 'config.toml'),
      path.join(process.env.LOCALAPPDATA || '', 'hermes', 'config.yaml'),
      path.join(process.env.LOCALAPPDATA || '', 'hermes', '.env')
    ];
    const out = [];
    for (const file of candidates) {
      const dir = path.dirname(file);
      const leaf = path.basename(file);
      let items = [];
      try {
        items = fs.readdirSync(dir).filter((n) => n.startsWith(leaf + '.') && n.endsWith('.bak'));
      } catch { continue; }
      items.sort().reverse();
      for (const name of items) {
        const full = path.join(dir, name);
        let size = 0; let mtime = null;
        try { const st = fs.statSync(full); size = st.size; mtime = st.mtime.toISOString(); } catch { /* skip */ }
        out.push({ file, name, path: full, size, mtime });
      }
    }
    return { ok: true, backups: out };
  },

  async 'GET /api/diagnostics'() {
    const r = await runEngine([...CONFIG_ARGS, '-Diagnostics']);
    return r.json || { ok: false, error: r.stderr || 'no response' };
  },

  async 'POST /api/import-setup'(_body, url) {
    const file = url.searchParams.get('file') || '';
    if (!file) return { ok: false, error: 'No file given.' };
    if (!fs.existsSync(file)) return { ok: false, error: `File not found: ${file}` };
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SETUP, '-SetupFile', file, ...CONFIG_ARGS];
    if (url.searchParams.get('dry') === '1') args.push('-WhatIf');
    const r = await new Promise((resolve) => {
      const ps = spawn('powershell.exe', args, { cwd: ROOT, windowsHide: true });
      let out = ''; let err = '';
      ps.stdout.on('data', (d) => { out += d.toString(); });
      ps.stderr.on('data', (d) => { err += d.toString(); });
      ps.on('close', (code) => resolve({ code, stdout: out, stderr: err }));
      ps.on('error', (e) => resolve({ code: -1, stdout: '', stderr: e.message }));
    });
    return { ok: r.code === 0, detail: (r.stdout || r.stderr).trim() };
  }
};

// ---------------------------------------------------------------------------
// http
// ---------------------------------------------------------------------------

function send(res, code, body, type = 'application/json') {
  const payload = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(code, {
    'content-type': type,
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store'
  });
  res.end(payload);
}

function authorized(req, url) {
  // The token can arrive in the query (so the page can open) or a header.
  const provided = url.searchParams.get('token') || req.headers['x-9sync-token'];
  if (provided && provided === TOKEN) return true;
  // A same-origin GET from the UI itself is allowed through, so the page can
  // load its first data without threading the token through every fetch.
  const origin = req.headers.origin;
  if (origin) {
    try {
      const o = new URL(origin);
      if ((o.hostname === '127.0.0.1' || o.hostname === 'localhost') && Number(o.port) === PORT) return true;
    } catch { /* fall through */ }
  }
  if (!origin && req.headers['sec-fetch-site'] === 'same-origin') return true;
  return false;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);

  // Static files.
  if (req.method === 'GET' && !url.pathname.startsWith('/api/')) {
    let rel = url.pathname === '/' ? '/index.html' : url.pathname;
    // No traversal: everything outside public/ resolves to index.html.
    const full = path.resolve(PUBLIC, '.' + rel);
    if (!full.startsWith(path.resolve(PUBLIC))) {
      rel = '/index.html';
    }
    const file = path.join(PUBLIC, rel === '/' ? 'index.html' : rel);
    try {
      const data = fs.readFileSync(file);
      const ext = path.extname(file);
      const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };
      send(res, 200, data.toString('utf8'), types[ext] || 'application/octet-stream');
    } catch {
      send(res, 404, { error: 'not found' });
    }
    return;
  }

  if (!authorized(req, url)) {
    send(res, 403, { error: 'This page was not opened from 9sync. Open the URL printed in the terminal.' });
    return;
  }

  const key = `${req.method} ${url.pathname}`;
  const handler = routes[key];
  if (!handler) {
    send(res, 404, { error: `no route for ${key}` });
    return;
  }

  let body = {};
  if (req.method === 'POST') {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const raw = Buffer.concat(chunks).toString('utf8');
    if (raw) {
      try { body = JSON.parse(raw); } catch { body = {}; }
    }
  }

  try {
    const result = await handler(body, url);
    send(res, 200, result);
  } catch (e) {
    send(res, 500, { error: e.message });
  }
});

server.listen(PORT, HOST, () => {
  const url = `http://${HOST}:${PORT}/?token=${TOKEN}`;
  console.log('');
  console.log('  9sync');
  console.log('');
  console.log(`  ${url}`);
  console.log('');
  console.log('  The token in the URL is what stops another website from driving this');
  console.log('  server. Keep the tab open; it stays valid for as long as the process runs.');
  console.log('');
  console.log('  Ctrl+C to stop.');
  console.log('');
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.error(`  Port ${PORT} is already in use. Set NINESYNC_PORT to pick another.`);
    process.exit(1);
  }
  throw e;
});