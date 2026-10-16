// 9sync web UI. No framework, no build step.
//
// The token from the URL is kept for every request: it is what proves this page
// is the one the terminal opened, and without it another site on this machine
// could drive the local server.

let TOKEN = new URLSearchParams(location.search).get('token') || '';
if (TOKEN) {
  try { sessionStorage.setItem('9sync_token', TOKEN); } catch {}
} else {
  try { TOKEN = sessionStorage.getItem('9sync_token') || ''; } catch {}
}
const $ = (id) => document.getElementById(id);

function api(path, options = {}) {
  const sep = path.includes('?') ? '&' : '?';
  const url = `${path}${sep}token=${encodeURIComponent(TOKEN)}`;
  return fetch(url, {
    ...options,
    headers: { 'content-type': 'application/json', 'x-9sync-token': TOKEN, ...(options.headers || {}) }
  }).then(async (r) => {
    const text = await r.text();
    let body;
    try { body = JSON.parse(text); } catch { body = { error: text }; }
    if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
    return body;
  });
}

let toastTimer = null;
function toast(message, kind = '') {
  const el = $('toast');
  el.textContent = message;
  el.className = `toast${kind ? ' toast-' + kind : ''}`;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, kind === 'bad' ? 9000 : 4000);
}

function busy(button, on, label) {
  if (!button) return;
  if (on) {
    button.dataset.was = button.textContent;
    button.textContent = label || 'working…';
    button.disabled = true;
  } else {
    button.textContent = button.dataset.was || button.textContent;
    button.disabled = false;
  }
}

const el = (tag, props = {}, kids = []) => {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') n.className = v;
    else if (k === 'text') n.textContent = v;
    else n.setAttribute(k, v);
  }
  for (const kid of [].concat(kids)) {
    if (!kid && kid !== 0) continue;
    if (typeof kid === 'string' || typeof kid === 'number') n.appendChild(document.createTextNode(String(kid)));
    else n.appendChild(kid);
  }
  return n;
};

// --- state -----------------------------------------------------------------

const state = { config: null, tools: [], models: [], selected: new Set() };

function renderConnection(c) {
  const pill = $('conn');
  if (!c) { pill.textContent = 'unknown'; pill.className = 'pill pill-wait'; return; }
  if (c.ok) {
    pill.textContent = `bridge ok · ${c.modelCount ?? '?'} models`;
    pill.className = 'pill pill-ok';
  } else {
    pill.textContent = 'bridge unreachable';
    pill.className = 'pill pill-bad';
    pill.title = c.note || '';
  }
}

function renderTools(tools, cfg, perTool) {
  const grid = $('tools');
  grid.textContent = '';
  const enabled = new Set(cfg.tools || []);

  for (const t of tools) {
    const on = enabled.has(t.tool);
    const box = el('input', { type: 'checkbox' });
    box.checked = on;
    box.disabled = !t.installed;
    box.addEventListener('change', () => {
      if (box.checked) enabled.add(t.tool); else enabled.delete(t.tool);
      saveTools([...enabled]);
    });

    const status = perTool?.[t.tool];
    let statusNode = null;
    if (!t.installed) {
      statusNode = el('div', { class: 'tool-status st-warn', text: 'not installed on this PC' });
    } else if (status) {
      const cls = status.status === 'updated' ? 'st-ok'
        : status.status === 'failed' ? 'st-bad'
        : status.status === 'unchanged' ? 'st-muted' : 'st-warn';
      statusNode = el('div', { class: `tool-status ${cls}`, text: `${status.status}${status.modelCount ? ` · ${status.modelCount} models` : ''}` });
    }

    grid.appendChild(el('label', { class: 'tool' }, [
      box,
      el('div', { class: 'tool-main' }, [
        el('div', { class: 'tool-name', text: t.label }),
        el('div', { class: 'tool-path', text: (t.exists && t.exists[0]) || t.paths[0] || '' }),
        statusNode
      ])
    ]));
  }
}

function renderLastRun(lastRun, log) {
  const box = $('lastrun');
  if (!lastRun) { box.className = 'empty muted'; box.textContent = 'No sync yet.'; return; }
  const when = new Date(lastRun.at).toLocaleString();
  const cls = lastRun.status === 'ok' ? 'st-ok' : 'st-bad';
  box.className = '';
  box.textContent = '';
  box.appendChild(el('div', {}, [
    el('span', { class: cls, text: lastRun.status === 'ok' ? 'OK' : 'FAILED' }),
    ' · ',
    el('span', { class: 'muted', text: when }),
    ' · ',
    el('span', { text: `${lastRun.modelCount} models` }),
    lastRun.defaultModel ? ' · ' : null,
    lastRun.defaultModel ? el('code', { text: lastRun.defaultModel }) : null
  ]));
  if (lastRun.detail) {
    box.appendChild(el('div', { class: 'small st-bad', text: lastRun.detail }));
  }

  if (log && log.length && $('history')) {
    const table = el('table', {}, [
      el('thead', {}, [el('tr', {}, [
        el('th', { text: 'When' }),
        el('th', { text: 'Result' }),
        el('th', { class: 'num', text: 'Models' }),
        el('th', { text: 'Note' })
      ])])
    ]);
    const tb = el('tbody');
    for (const e of log.slice(0, 12)) {
      tb.appendChild(el('tr', {}, [
        el('td', { text: new Date(e.at).toLocaleString() }),
        el('td', { class: e.ok ? 'st-ok' : 'st-bad', text: e.ok ? 'OK' : 'FAILED' }),
        el('td', { class: 'num', text: String(e.models ?? 0) }),
        el('td', { class: 'muted small', text: e.note || '' })
      ]));
    }
    table.appendChild(tb);
    $('history').textContent = '';
    $('history').appendChild(table);
    if ($('history-wrap')) $('history-wrap').hidden = false;
  }
}

function renderModels(data) {
  const box = $('models');
  const select = $('default-model');
  if (!data.ok) {
    box.className = 'empty muted';
    box.textContent = data.error || 'Could not load models.';
    return;
  }
  if (!data.models.length) {
    box.className = 'empty muted';
    box.textContent = 'No models resolve from the current 9Router config.';
    return;
  }

  box.className = '';
  box.textContent = '';

  // What the next sync will actually use. The config value can be empty
  // (9Router decides) or name a model that no longer exists, so the effective
  // value is what matters and it gets its own line.
  const eff = data.effectiveDefault || '';
  const cfg = data.configuredDefault ?? state.config?.defaultModel ?? '';
  const banner = el('div', { class: 'small' }, [
    el('span', { class: 'muted', text: 'Effective default: ' }),
    eff ? el('code', { text: eff }) : el('span', { class: 'muted', text: '(9Router decides)' }),
    cfg ? el('span', { class: 'muted small', text: `  ·  configured: ${cfg}` }) : null,
    data.sourceTools?.length ? el('span', { class: 'muted small', text: `  ·  from: ${data.sourceTools.join(', ')}` }) : null
  ]);
  box.appendChild(banner);

  const table = el('table', {}, [el('thead', {}, [el('tr', {}, [
    el('th', { text: '' }),
    el('th', { text: 'Model' }),
    el('th', { text: 'Source' }),
    el('th', { class: 'num', text: 'Context' }),
    el('th', { text: 'Vision' }),
    el('th', { text: 'Reasoning' }),
    el('th', { text: 'Tools' }),
    el('th', { text: 'Health' })
  ])])]);
  const tb = el('tbody');
  for (const m of data.models) {
    let health = el('span', { class: 'muted', text: '—' });
    if (m.healthOk === true) health = el('span', { class: 'st-ok', text: 'ok' });
    else if (m.healthOk === false) health = el('span', { class: 'st-bad', text: 'failed' });
    const star = m.isEffectiveDefault ? '*' : '';
    tb.appendChild(el('tr', {}, [
      el('td', { class: m.isEffectiveDefault ? 'st-ok' : 'muted', text: star }),
      el('td', {}, [el('code', { text: m.id }), m.wasRenamed ? el('span', { class: 'muted small', text: ' renamed' }) : null]),
      el('td', { class: 'muted small', text: m.source || '' }),
      el('td', { class: 'num', text: String(m.ctx) }),
      el('td', { text: m.vision ? 'yes' : '' }),
      el('td', { text: m.reasoning ? 'yes' : '' }),
      el('td', { text: m.tools ? 'yes' : 'no' }),
      el('td', {}, [health, m.healthAt ? el('span', { class: 'muted small', text: ' ' + m.healthAt }) : null])
    ]));
  }
  table.appendChild(tb);
  box.appendChild(table);

  if (data.skipped?.length) {
    const wrap = el('div', { class: 'small' }, [
      el('div', { class: 'st-bad', text: `Skipped — on the phone but not in the catalog (${data.skipped.length}):` })
    ]);
    for (const s of data.skipped) {
      wrap.appendChild(el('div', { class: 'muted small', text: `· ${s.id}  [from ${s.source || '?'}]  ${s.reason || ''}` }));
    }
    box.appendChild(wrap);
  }

  const current = select.value;
  select.textContent = '';
  select.appendChild(el('option', { value: '', text: '(follow 9Router — clear default)' }));
  for (const m of data.models) {
    const label = m.isEffectiveDefault ? `* ${m.id}` : m.id;
    select.appendChild(el('option', { value: m.id, text: label }));
  }
  if (current) select.value = current;
  const want = data.configuredDefault ?? state.config?.defaultModel ?? '';
  if (want) {
    // The select holds full ids ("9router/x"); the config may store the
    // stripped form ("x"). Match either, so the current default is selected
    // instead of silently falling back to the first row.
    const match = [...select.options].find((o) => o.value === want || o.value === `9router/${want}` || o.value.replace(/^9router\//, '') === want.replace(/^9router\//, ''));
    if (match) select.value = match.value;
  } else {
    select.value = '';
  }
}

function renderConfig(cfg) {
  state.config = cfg;
  $('endpoint').textContent = cfg.remoteUrl || 'no endpoint set';
  $('in-url').value = cfg.remoteUrl || '';
  $('in-key').value = '';
  $('in-key').placeholder = cfg.hasBridgeKey
    ? `saved: ${cfg.bridgeKeyMasked} — type to replace`
    : '64 hex characters from the phone';
  $('in-default').value = cfg.defaultModel || '';
  $('in-keep').value = String(cfg.backupKeep || 5);
}

async function refresh() {
  try {
    const d = await api('/api/state');
    renderConfig(d.config);
    state.tools = d.tools || [];
    renderTools(state.tools, d.config, d.lastRun?.perTool);
    renderLastRun(d.lastRun, d.log);
    renderConnection(d.connection);
  } catch (e) {
    $('endpoint').textContent = 'could not reach the local server';
    toast(e.message, 'bad');
  }
}

async function saveTools(tools) {
  try {
    const r = await api('/api/config/save', { method: 'POST', body: JSON.stringify({ tools }) });
    if (!r.ok) throw new Error(r.error || 'Failed to save tools');
    if (r.config) state.config = r.config;
  } catch (e) { toast(e.message, 'bad'); }
}

async function doSync(dry) {
  const btn = dry ? $('btn-preview') : $('btn-sync');
  busy(btn, true, dry ? 'checking…' : 'syncing…');
  $('conn').textContent = dry ? 'checking' : 'syncing';
  $('conn').className = 'pill pill-wait';
  try {
    const r = await api(`/api/sync${dry ? '?dry=1' : ''}`, { method: 'POST' });
    if (r.rows) {
      $('rows').textContent = '';
      const table = el('table', {}, [el('thead', {}, [el('tr', {}, [
        el('th', { text: 'Tool' }), el('th', { text: 'Status' }), el('th', { text: 'Detail' })
      ])])]);
      const tb = el('tbody');
      for (const row of r.rows) {
        const tool = row.tool || row.Tool || '';
        const status = row.status || row.Status || '';
        const detail = row.detail || row.Detail || '';
        const cls = status === 'updated' ? 'st-ok'
          : status === 'failed' ? 'st-bad'
          : status === 'not-installed' ? 'st-warn' : 'st-muted';
        tb.appendChild(el('tr', {}, [
          el('td', { text: tool }),
          el('td', { class: cls, text: status }),
          el('td', { class: 'muted small', text: detail })
        ]));
      }
      table.appendChild(tb);
      $('rows').appendChild(table);
      $('rows-wrap').hidden = false;
    }
    if (!r.ok) {
      toast(r.error || 'Sync failed.', 'bad');
    } else if (r.dangling?.length) {
      toast(`Released ${r.dangling.length} stale pin(s): ${r.dangling.map((d) => d.where || d.Where).join(', ')}`);
    } else if (dry) {
      toast('Preview only. Nothing was written.');
    } else {
      toast(`Done. ${(r.modelIds || []).length} models, default ${r.defaultModel}`);
    }
  } catch (e) {
    toast(e.message, 'bad');
  } finally {
    busy(btn, false);
    await refresh();
  }
}

// --- wiring ----------------------------------------------------------------

$('btn-sync').addEventListener('click', () => doSync(false));
$('btn-preview').addEventListener('click', () => doSync(true));

$('btn-models').addEventListener('click', async () => {
  busy($('btn-models'), true, 'loading…');
  try { renderModels(await api('/api/models')); }
  catch (e) { toast(e.message, 'bad'); }
  finally { busy($('btn-models'), false); }
});

$('btn-probe').addEventListener('click', async () => {
  busy($('btn-probe'), true, 'checking…');
  toast('Health check running. Cold providers can be slow; this can take a few minutes.', '');
  try {
    const r = await api('/api/probe', { method: 'POST' });
    if (!r.ok) { toast(r.error || 'Probe failed.', 'bad'); return; }
    toast(`${r.healthy} of ${r.total} models healthy.`);
    renderModels(await api('/api/models'));
  } catch (e) { toast(e.message, 'bad'); }
  finally { busy($('btn-probe'), false); }
});

$('btn-save').addEventListener('click', async () => {
  busy($('btn-save'), true, 'saving…');
  try {
    const payload = {
      remoteUrl: $('in-url').value,
      defaultModel: $('in-default').value,
      backupKeep: Number($('in-keep').value),
      tools: [...(state.config?.tools || [])]
    };
    // Only sent when typed: the field is blank after load, and sending the mask
    // back would replace the real key with it.
    if ($('in-key').value.trim()) payload.bridgeKey = $('in-key').value.trim();
    const r = await api('/api/config/save', { method: 'POST', body: JSON.stringify(payload) });
    if (!r.ok) throw new Error(r.error || 'Failed to save settings');
    renderConfig(r.config);
    toast('Settings saved.');
    await refresh();
  } catch (e) { toast(e.message, 'bad'); }
  finally { busy($('btn-save'), false); }
});

$('btn-set-default').addEventListener('click', async () => {
  const value = $('default-model').value;
  try {
    const r = await api('/api/config/save', {
      method: 'POST',
      body: JSON.stringify({ defaultModel: value, tools: [...(state.config?.tools || [])] })
    });
    if (!r.ok) throw new Error(r.error || 'Failed to set default model');
    renderConfig(r.config);
    toast(value ? `Default model set to ${value}. Run Sync now to apply it.` : 'Default cleared; 9Router decides.');
    try { renderModels(await api('/api/models')); } catch {}
  } catch (e) { toast(e.message, 'bad'); }
});

$('btn-test').addEventListener('click', async () => {
  busy($('btn-test'), true, 'testing…');
  try {
    const r = await api('/api/config/save', {
      method: 'POST',
      body: JSON.stringify({ remoteUrl: $('in-url').value, tools: [...(state.config?.tools || [])] })
    });
    if (!r.ok) throw new Error(r.error || 'Failed to save endpoint');
  } catch (e) { busy($('btn-test'), false); toast(e.message, 'bad'); return; }
  await refresh();
  busy($('btn-test'), false);
});

$('btn-backups').addEventListener('click', async () => {
  busy($('btn-backups'), true, 'listing…');
  try {
    const r = await api('/api/backups');
    const box = $('backups');
    box.className = '';
    box.textContent = '';
    if (!r.backups.length) { box.className = 'empty muted'; box.textContent = 'No backups found.'; return; }
    const table = el('table', {}, [el('thead', {}, [el('tr', {}, [
      el('th', { text: 'File' }), el('th', { text: 'Version' }),
      el('th', { class: 'num', text: 'Bytes' }), el('th', { text: '' })
    ])])]);
    const tb = el('tbody');
    for (const b of r.backups) {
      const btn = el('button', { text: 'Restore' });
      btn.addEventListener('click', async () => {
        if (!confirm(`Restore ${b.name} over ${b.file}? The current file is backed up first.`)) return;
        try {
          const r2 = await api(`/api/restore?path=${encodeURIComponent(b.file)}&backup=${encodeURIComponent(b.path)}`, { method: 'POST' });
          toast(r2.ok ? `Restored ${r2.restored}.` : (r2.error || 'failed'), r2.ok ? '' : 'bad');
        } catch (e) { toast(e.message, 'bad'); }
      });
      tb.appendChild(el('tr', {}, [
        el('td', {}, [el('code', { text: b.file })]),
        el('td', { class: 'muted', text: b.name.replace(b.file.split(/[\\/]/).pop() + '.', '').replace('.bak', '') }),
        el('td', { class: 'num', text: String(b.size) }),
        el('td', {}, [btn])
      ]));
    }
    table.appendChild(tb);
    box.appendChild(table);
  } catch (e) { toast(e.message, 'bad'); }
  finally { busy($('btn-backups'), false); }
});

$('btn-diag').addEventListener('click', async () => {
  busy($('btn-diag'), true, 'gathering…');
  try {
    const d = await api('/api/diagnostics');
    $('diag').className = '';
    $('diag').textContent = JSON.stringify(d, null, 2);
  } catch (e) { toast(e.message, 'bad'); }
  finally { busy($('btn-diag'), false); }
});

$('btn-copy').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText($('diag').textContent);
    toast('Copied. Secrets are masked.');
  } catch { toast('Clipboard blocked; select the text and copy manually.', 'bad'); }
});

async function importSetup(dry) {
  const file = $('in-setup').value.trim();
  if (!file) { toast('Give the path to 9sync-setup.local.md first.', 'bad'); return; }
  const btn = dry ? $('btn-setup-dry') : $('btn-setup');
  busy(btn, true, dry ? 'reading…' : 'importing…');
  try {
    const r = await api(`/api/import-setup?file=${encodeURIComponent(file)}${dry ? '&dry=1' : ''}`, { method: 'POST' });
    $('setup-out').className = r.ok ? '' : 'st-bad';
    $('setup-out').textContent = r.detail || (r.ok ? 'Done.' : 'Failed.');
    toast(r.ok ? (dry ? 'Preview only, nothing written.' : 'Imported. Sync now to apply.') : 'Import failed.', r.ok ? '' : 'bad');
    if (r.ok && !dry) await refresh();
  } catch (e) {
    $('setup-out').className = 'st-bad';
    $('setup-out').textContent = e.message;
    toast(e.message, 'bad');
  } finally { busy(btn, false); }
}

$('btn-setup').addEventListener('click', () => importSetup(false));
$('btn-setup-dry').addEventListener('click', () => importSetup(true));

refresh();