'use strict';

// PowerShell's ConvertTo-Json emits a bare object for a single-element collection,
// so every list coming from the API goes through this.
const asArray = v => (v === null || v === undefined) ? [] : (Array.isArray(v) ? v : [v]);

const SEV = {
  BLOCKER: { label: 'Blocker', cls: 'dot-critical', color: 'var(--critical)', rank: 0 },
  HIGH:    { label: 'High',    cls: 'dot-serious',  color: 'var(--serious)',  rank: 1 },
  MEDIUM:  { label: 'Medium',  cls: 'dot-warning',  color: 'var(--warning)',  rank: 2 },
  LOW:     { label: 'Low',     cls: 'dot-neutral',  color: 'var(--baseline)', rank: 3 }
};

const state = { report: null, category: 'ALL', showPassed: false, open: {} };

const $ = id => document.getElementById(id);
const esc = s => String(s === null || s === undefined ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function toast(msg) {
  const t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(t._timer);
  t._timer = setTimeout(() => { t.hidden = true; }, 3200);
}

// Every button on this page calls the local server. If it is not running the buttons can
// only fail silently, so say so plainly instead.
function showServerDown() {
  if ($('serverDown')) return;
  const bar = document.createElement('div');
  bar.id = 'serverDown';
  bar.className = 'server-down';
  bar.innerHTML = `<span><strong>The analyzer server is not running.</strong> ` +
    `Nothing on this page can work until it is started again — run <code>.\\Run-Cvi.ps1</code> ` +
    `in the cvi-readiness folder (closing its console window stops it).</span>` +
    `<button class="btn" id="serverRetry">Retry</button>`;
  document.body.prepend(bar);
  $('serverRetry').onclick = () => location.reload();
}

async function api(path, opts) {
  let res;
  try {
    res = await fetch(path, opts);
  } catch (e) {
    showServerDown();
    throw new Error('the analyzer server is not reachable');
  }
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

// ---------------------------------------------------------------- rendering

function renderHeader(r) {
  $('systemLine').textContent =
    `${r.SystemId}/${r.Client} · ${r.SourceRelease} → ${r.TargetRelease} · ${r.Strategy.replace('_', ' ').toLowerCase()} strategy · analysed ${r.GeneratedAt} in ${r.DurationMs} ms`;
  const badge = $('aiBadge');
  badge.textContent = `judgment layer: ${r.AiMode}`;
  badge.title = r.AiDetail;
}

function renderScore(r) {
  const C = 2 * Math.PI * 52;
  const gateColor = r.Gate === 'NOT READY' ? 'var(--critical)'
                  : r.Gate === 'READY WITH ACTIONS' ? 'var(--warning)' : 'var(--good)';
  const ring = $('ringValue');
  ring.style.stroke = gateColor;
  // Must be set as a style property, not an attribute: the stylesheet's own
  // `stroke-dasharray` declaration outranks an SVG presentation attribute, which left the
  // ring stuck at zero length - drawn as nothing but the round line cap.
  ring.style.strokeDasharray = `${(r.Score / 100) * C} ${C}`;
  $('scoreNumber').textContent = `${r.Score}%`;
  $('gateIcon').style.background = gateColor;
  $('gateText').textContent = r.Gate;

  const c = r.Counts;
  $('tBlocker').textContent = c.Blocker;
  $('tHigh').textContent = c.High;
  $('tMedium').textContent = c.Medium + c.Low;
  $('tAffected').textContent = c.Affected;
  $('tScope').textContent = `of ${c.Customers} customers, ${c.Vendors} vendors, ${c.Contacts} contacts`;
  $('tPassed').textContent = c.Passed;
  $('tChecks').textContent = `of ${c.Checks} checks · ${c.Candidates} judged candidates`;
}

function renderDistribution(r) {
  const checks = asArray(r.Checks).filter(c => c.Status === 'FAIL');
  const rows = Object.keys(SEV).map(k => {
    const inSev = checks.filter(c => c.Severity === k);
    return {
      key: k,
      checks: inSev.length,
      objects: inSev.reduce((a, c) => a + (c.Count || 0), 0)
    };
  }).filter(x => x.checks > 0);

  const total = rows.reduce((a, x) => a + Math.max(x.objects, 1), 0) || 1;
  $('distBar').innerHTML = rows.map(x =>
    `<div class="dist-seg" style="flex:${Math.max(x.objects, 1) / total};background:${SEV[x.key].color}" title="${SEV[x.key].label}: ${x.objects} object(s)"></div>`
  ).join('');

  $('distLegend').innerHTML = rows.map(x =>
    `<span class="legend-item"><span class="dot ${SEV[x.key].cls}"></span>${SEV[x.key].label}
      <b>${x.checks}</b> check${x.checks === 1 ? '' : 's'} · <b>${x.objects}</b> object${x.objects === 1 ? '' : 's'}</span>`
  ).join('');

  const blockers = rows.find(x => x.key === 'BLOCKER');
  $('distNote').textContent = blockers
    ? 'Blockers first — the run does not start until those are cleared.'
    : 'No blockers: the run can start, and the rest is post-processing volume.';
}

function renderChips(r) {
  const checks = asArray(r.Checks);
  const cats = ['ALL'].concat([...new Set(checks.map(c => c.Category))]);
  $('catChips').innerHTML = cats.map(cat => {
    const n = (cat === 'ALL' ? checks : checks.filter(c => c.Category === cat)).filter(c => c.Status === 'FAIL').length;
    const label = cat === 'ALL' ? 'All findings' : cat;
    return `<button class="chip" data-cat="${esc(cat)}" aria-pressed="${state.category === cat}">${esc(label)}<span class="n">${n}</span></button>`;
  }).join('');
  $('catChips').querySelectorAll('.chip').forEach(b => {
    b.onclick = () => { state.category = b.dataset.cat; renderChips(state.report); renderFindings(state.report); };
  });
}

function confidenceOf(value) {
  const m = /([0-9]*\.?[0-9]+)/.exec(value || '');
  return m ? parseFloat(m[1]) : null;
}

function evidenceTable(check) {
  const rows = asArray(check.Evidence);
  if (!rows.length) return '';
  const judgment = check.Layer === 'JUDGMENT';
  const head = judgment
    ? ['Object', 'Key', 'Verdict', 'Confidence', 'Reasoning', 'Proposed action']
    : ['Object', 'Key', 'Field', 'Value', 'Finding', 'Proposed action'];

  const body = rows.map(e => {
    let third = `<td>${esc(e.Field)}</td>`;
    let fourth = `<td class="val">${esc(e.Value)}</td>`;
    if (judgment) {
      const conf = confidenceOf(e.Value);
      third = `<td><span class="verdict">${esc(e.Field)}</span></td>`;
      fourth = conf === null ? `<td>${esc(e.Value)}</td>` :
        `<td><span class="conf"><span class="conf-bar"><i style="width:${Math.round(conf * 100)}%"></i></span>${conf.toFixed(2)}</span></td>`;
    }
    const table = e.Table && e.Table !== e.Object ? `<br><span class="muted">${esc(e.Table)}</span>` : '';
    return `<tr>
      <td class="key">${esc(e.Object)}${table}</td>
      <td class="key">${esc(e.Key)}</td>
      ${third}${fourth}
      <td class="detail">${esc(e.Detail)}</td>
      <td class="detail">${esc(e.Proposal)}</td>
    </tr>`;
  }).join('');

  const more = check.Truncated ? `<p class="muted" style="margin-top:8px">Showing the first ${rows.length} of ${check.Count}. The generated worklist contains every row.</p>` : '';
  return `<div class="table-wrap"><table><thead><tr>${head.map(h => `<th>${h}</th>`).join('')}</tr></thead><tbody>${body}</tbody></table></div>${more}`;
}

function cardHtml(check) {
  const sev = SEV[check.Severity] || SEV.LOW;
  const passed = check.Status === 'PASS';
  const stripe = passed ? 'var(--good)' : sev.color;
  const open = state.open[check.Id] ? '1' : '0';
  const layerTag = check.Layer === 'JUDGMENT' ? '<span class="tag">judgment</span>' : '';
  const statusTag = passed ? '<span class="tag">passed</span>' : '';

  return `<article class="card ${passed ? 'pass' : ''}" open-state="${open}" data-id="${esc(check.Id)}">
    <div class="card-head">
      <div class="stripe" style="background:${stripe}"></div>
      <div class="sev"><span class="dot ${passed ? 'dot-good' : sev.cls}"></span>${passed ? 'Passed' : sev.label}</div>
      <div class="card-title">
        <div class="row1">
          <span class="card-id">${esc(check.Id)}</span>
          <span class="card-name">${esc(check.Title)}</span>
          <span class="tag">${esc(check.Category)}</span>${layerTag}${statusTag}
        </div>
        <div class="card-summary">${esc(check.Summary)}</div>
      </div>
      <div class="card-meta">
        ${passed ? '' : `<div class="count">${check.Count}<small>objects</small></div>`}
        <div class="caret">›</div>
      </div>
    </div>
    <div class="card-body">
      <div class="body-grid">
        <div><h3>Why it matters</h3><p>${esc(check.Why)}</p></div>
        <div><h3>What to do</h3><p>${esc(check.Fix)}</p></div>
      </div>
      <div class="img-path"><strong>Where:</strong> ${esc(check.ImgPath)}</div>
      ${evidenceTable(check)}
      ${passed ? '' : `<div class="card-actions">
        <button class="btn btn-primary pack" data-id="${esc(check.Id)}">Generate fix pack</button>
        <span class="pack-result" data-result="${esc(check.Id)}"></span>
      </div>`}
    </div>
  </article>`;
}

function renderFindings(r) {
  let checks = asArray(r.Checks).filter(c => c.Status !== 'NA');
  if (!state.showPassed) checks = checks.filter(c => c.Status === 'FAIL');
  if (state.category !== 'ALL') checks = checks.filter(c => c.Category === state.category);

  $('findings').innerHTML = checks.length
    ? checks.map(cardHtml).join('')
    : '<p class="muted">Nothing matches this filter.</p>';

  $('findings').querySelectorAll('.card-head').forEach(head => {
    head.onclick = () => {
      const card = head.closest('.card');
      const id = card.dataset.id;
      state.open[id] = card.getAttribute('open-state') !== '1';
      card.setAttribute('open-state', state.open[id] ? '1' : '0');
    };
  });

  $('findings').querySelectorAll('button.pack').forEach(btn => {
    btn.onclick = async ev => {
      ev.stopPropagation();
      await generatePack(btn.dataset.id, btn);
    };
  });
}

// ---------------------------------------------------------------- actions

async function generatePack(checkId, btn) {
  const target = document.querySelector(`[data-result="${checkId}"]`);
  if (btn) { btn.disabled = true; btn.textContent = 'Generating…'; }
  try {
    const res = await api(`/api/fixpack?check=${encodeURIComponent(checkId)}`, { method: 'POST' });
    if (!res.ok) throw new Error(res.error || 'failed');
    const links = asArray(res.files).map(f =>
      `<a href="/api/download?file=${encodeURIComponent(f)}" download>${esc(f)}</a>`).join(' · ');
    if (target) target.innerHTML = `${res.rows} row(s) written — ${links}`;
    toast(`${checkId}: ${asArray(res.files).length} file(s) written to .\\out`);
    await refreshFiles();
  } catch (e) {
    if (target) target.textContent = `Failed: ${e.message}`;
    toast(`Could not generate the fix pack for ${checkId}`);
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Generate fix pack'; }
  }
}

async function refreshFiles() {
  try {
    const res = await api('/api/files');
    const files = asArray(res.files);
    $('outNote').innerHTML = `Fix packs are written to <code>${esc(res.outDir)}</code>.`;
    $('fileList').innerHTML = files.length
      ? files.map(f => `<a href="/api/download?file=${encodeURIComponent(f.name)}" download>${esc(f.name)} <span>${f.size} B</span></a>`).join('')
      : '<p class="muted">Nothing generated yet.</p>';
  } catch (e) { /* the panel is not worth breaking the page over */ }
}

function renderAll(r) {
  state.report = r;
  renderHeader(r);
  renderScore(r);
  renderDistribution(r);
  renderChips(r);
  renderFindings(r);
}

// ---------------------------------------------------------------- boot

$('showPassed').onchange = e => { state.showPassed = e.target.checked; renderFindings(state.report); };

$('rerunBtn').onclick = async () => {
  const btn = $('rerunBtn');
  btn.disabled = true; btn.textContent = 'Analysing…';
  try {
    renderAll(await api('/api/analyze', { method: 'POST' }));
    toast('Analysis re-run against the current extract');
  } catch (e) {
    toast('Re-run failed: ' + e.message);
  } finally {
    btn.disabled = false; btn.textContent = 'Re-run analysis';
  }
};

$('allPacksBtn').onclick = async () => {
  const btn = $('allPacksBtn');
  btn.disabled = true; btn.textContent = 'Generating…';
  try {
    const res = await api('/api/fixpack?check=ALL', { method: 'POST' });
    toast(`${asArray(res.files).length} file(s) written to .\\out`);
    await refreshFiles();
  } catch (e) {
    toast('Generation failed: ' + e.message);
  } finally {
    btn.disabled = false; btn.textContent = 'Generate all fix packs';
  }
};

// The assistant links findings as /?check=CFG-06 - open that card and scroll to it.
function focusCheckFromUrl() {
  const id = new URLSearchParams(location.search).get('check');
  if (!id) return;
  const known = asArray(state.report.Checks).some(c => c.Id === id);
  if (!known) return;
  state.open[id] = true;
  state.showPassed = true;
  $('showPassed').checked = true;
  state.category = 'ALL';
  renderChips(state.report);
  renderFindings(state.report);
  const card = document.querySelector(`.card[data-id="${CSS.escape(id)}"]`);
  if (card) {
    card.scrollIntoView({ behavior: 'smooth', block: 'center' });
    card.classList.add('highlight');
    setTimeout(() => card.classList.remove('highlight'), 2600);
  }
}

(async function init() {
  try {
    renderAll(await api('/api/report'));
    focusCheckFromUrl();
    await refreshFiles();
  } catch (e) {
    $('systemLine').textContent = 'Could not load the report: ' + e.message;
  }
})();
