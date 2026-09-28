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
    `${r.Strategy.replace('_', ' ').toLowerCase()} strategy · analysed ${r.GeneratedAt} in ${r.DurationMs} ms`;
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

  // The score counts recorded checks, so the header has to say how much of it is somebody's
  // word rather than the extract. Without this the number reads as verified when it is not.
  const banner = $('recordedBanner');
  if (c.Done > 0) {
    const one = c.Done === 1;
    const objs = c.DoneObjects === 1 ? '1 object was' : `${c.DoneObjects} objects were`;
    const blk = c.DoneBlockers > 0
      ? `, including ${c.DoneBlockers} blocker${c.DoneBlockers === 1 ? '' : 's'}` : '';
    banner.hidden = false;
    banner.innerHTML = `<strong>${c.Done} of the ${c.Passed + c.Done} checks behind this score
      ${one ? 'is' : 'are'} recorded as done, not verified.</strong>
      ${objs} still failing in the extract when ${one ? 'it was' : 'they were'} recorded${blk}.
      Re-extract the data to see whether ${one ? 'it actually passes' : 'they actually pass'}.`;
  } else {
    banner.hidden = true;
  }
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
  const done = r.Counts.Done;
  $('distNote').textContent = (blockers
    ? 'Blockers first — the run does not start until those are cleared.'
    : 'No blockers: the run can start, and the rest is post-processing volume.')
    + (done > 0 ? ` ${done} check(s) recorded as done are not counted here.` : '');
}

function renderChips(r) {
  const checks = asArray(r.Checks);
  const cats = ['ALL'].concat([...new Set(checks.map(c => c.Category))]);
  $('catChips').innerHTML = cats.map(cat => {
    const n = (cat === 'ALL' ? checks : checks.filter(c => c.Category === cat))
      .filter(c => c.Status === 'FAIL' || c.Status === 'DONE').length;
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

// What this object should become. Where the extract carries the set of valid values the cell
// is a dropdown built from it; where it does not - a region, a postal code, a tax number -
// it is a typed value, because offering a made-up list would be worse than asking.
function choiceCell(check, e) {
  const opts = asArray(e.Options);
  const chosen = e.Choice || '';
  const attrs = `data-check="${esc(check.Id)}" data-key="${esc(e.Key)}" data-field="${esc(e.Field)}"`;
  if (!opts.length) {
    return `<td class="choice-cell"><input class="in choice-input" ${attrs} value="${esc(chosen)}"
      placeholder="new value" title="No table of valid values for this field is in the extract — type the corrected value."></td>`;
  }
  const options = [`<option value=""${chosen ? '' : ' selected'}>— not decided —</option>`].concat(
    opts.map(o => `<option value="${esc(o.Value)}"${o.Value === chosen ? ' selected' : ''}>${esc(o.Label)}</option>`)
  ).join('');
  return `<td class="choice-cell"><select class="in choice-select" ${attrs}>${options}</select></td>`;
}

function evidenceTable(check) {
  const rows = asArray(check.Evidence);
  if (!rows.length) return '';
  const judgment = check.Layer === 'JUDGMENT';
  // Only the note check gets a per-row action: a note is the one kind of finding that is
  // cleared by somebody going away and doing it, rather than by correcting data here.
  const notes = check.ActionKind === 'note';
  const head = judgment
    ? ['Object', 'Key', 'Verdict', 'Confidence', 'Reasoning', 'Proposed action']
    : ['Object', 'Key', 'Field', 'Value', 'Finding', 'Proposed action'];
  head.push('Change to');
  if (notes) head.push('Implemented?');

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
    const action = notes
      ? `<td><button class="btn btn-small note-impl" data-note="${esc(e.Key)}"
           title="Records that note ${esc(e.Key)} is implemented in the system. It does not implement it.">Mark implemented</button></td>`
      : '';
    return `<tr>
      <td class="key">${esc(e.Object)}${table}</td>
      <td class="key">${esc(e.Key)}</td>
      ${third}${fourth}
      <td class="detail">${esc(e.Detail)}</td>
      <td class="detail">${esc(e.Proposal)}</td>
      ${choiceCell(check, e)}
      ${action}
    </tr>`;
  }).join('');

  const more = check.Truncated ? `<p class="muted" style="margin-top:8px">Showing the first ${rows.length} of ${check.Count}. The generated worklist contains every row.</p>` : '';
  return `<div class="table-wrap"><table><thead><tr>${head.map(h => `<th>${h}</th>`).join('')}</tr></thead><tbody>${body}</tbody></table></div>${more}`;
}

function cardHtml(check) {
  const sev = SEV[check.Severity] || SEV.LOW;
  const passed = check.Status === 'PASS';
  // DONE is not PASS and is never drawn as one: the data still says this check fails, and
  // the card has to keep saying so while showing that somebody has taken it on.
  const recorded = check.Status === 'DONE';
  const stripe = passed ? 'var(--good)' : recorded ? 'var(--recorded)' : sev.color;
  const open = state.open[check.Id] ? '1' : '0';
  const layerTag = check.Layer === 'JUDGMENT' ? '<span class="tag">judgment</span>' : '';
  const statusTag = passed ? '<span class="tag">passed</span>'
    : recorded ? '<span class="tag tag-recorded">recorded as done</span>' : '';

  // The note card keeps its reset button after it passes - marking every note implemented is
  // exactly how it passes, and that is the moment somebody is most likely to want it undone.
  const isNotes = check.ActionKind === 'note';
  const noteFootnote = isNotes
    ? `<p class="muted" style="margin-top:10px">Marking a note implemented records the confirmation
       in <code>data\\config\\CVI_NOTE_STATUS.csv</code> and drops it from this check. It does not
       implement anything — the note is implemented in SNOTE, and nothing here reaches an SAP system.</p>`
    : '';
  const noteReset = isNotes
    ? `<button class="btn note-reset" title="Clears every confirmation made from this report. The catalog's own statuses stay as extracted.">Reset confirmations</button>`
    : '';
  const reopen = recorded
    ? `<button class="btn reopen" data-id="${esc(check.Id)}" title="Drops the record that this check was taken on. It goes back to failing, with its objects and its weight on the score.">Reopen check</button>`
    : '';
  const recordedNote = recorded
    ? `<p class="recorded-note">Recorded as done by <strong>${esc(check.RecordedBy)}</strong> on ${esc(check.RecordedAt)}.
       ${check.Count === 1 ? 'The object below was' : `The ${check.Count} objects below were`} still failing when that was
       recorded — this is a record that somebody took the check on, not evidence that the system was corrected.
       Re-extract the data and it fails again if it is still wrong.</p>`
    : '';
  const actions = (passed && !isNotes) ? '' : `<div class="card-actions">
        ${passed || recorded ? '' : `<button class="btn btn-primary pack" data-id="${esc(check.Id)}">Generate fix pack</button>`}
        ${recorded ? `<button class="btn pack" data-id="${esc(check.Id)}">Regenerate fix pack</button>` : ''}
        ${reopen}
        ${noteReset}
        <span class="pack-result" data-result="${esc(check.Id)}"></span>
      </div>`;

  return `<article class="card ${passed ? 'pass' : ''} ${recorded ? 'recorded' : ''}" open-state="${open}" data-id="${esc(check.Id)}">
    <div class="card-head">
      <div class="stripe" style="background:${stripe}"></div>
      <div class="sev"><span class="dot ${passed ? 'dot-good' : recorded ? 'dot-recorded' : sev.cls}"></span>${passed ? 'Passed' : recorded ? 'On record' : sev.label}</div>
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
      ${recordedNote}
      ${evidenceTable(check)}
      ${noteFootnote}
      ${actions}
    </div>
  </article>`;
}

function renderFindings(r) {
  let checks = asArray(r.Checks).filter(c => c.Status !== 'NA');
  // Recorded checks always stay on screen. They are the ones somebody claimed, so they are
  // exactly what a reviewer needs to see - and the card carries the only way to undo them.
  // The note check earns the same treatment once its notes have been ticked off.
  if (!state.showPassed) {
    checks = checks.filter(c => c.Status === 'FAIL' || c.Status === 'DONE'
      || (c.ActionKind === 'note' && r.NoteConfirmations > 0));
  }
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

  $('findings').querySelectorAll('button.note-impl').forEach(btn => {
    btn.onclick = async ev => {
      ev.stopPropagation();
      await markNoteImplemented(btn.dataset.note, btn);
    };
  });

  $('findings').querySelectorAll('button.note-reset').forEach(btn => {
    btn.onclick = async ev => {
      ev.stopPropagation();
      await resetNoteConfirmations(btn);
    };
  });

  $('findings').querySelectorAll('button.reopen').forEach(btn => {
    btn.onclick = async ev => {
      ev.stopPropagation();
      await reopenCheck(btn.dataset.id, btn);
    };
  });

  // A choice is saved on its own, without re-running the report: picking a value for twenty
  // rows should not mean twenty full analyses.
  $('findings').querySelectorAll('.choice-select, .choice-input').forEach(el => {
    el.onclick = ev => ev.stopPropagation();
    el.onchange = async () => { await saveChoice(el); };
  });
}

// ---------------------------------------------------------------- actions

async function saveChoice(el) {
  const previous = el.dataset.saved === undefined ? '' : el.dataset.saved;
  try {
    const res = await api('/api/decisions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        checkId: el.dataset.check,
        decisions: [{ checkId: el.dataset.check, key: el.dataset.key, field: el.dataset.field, choice: el.value }]
      })
    });
    if (!res.ok) throw new Error(res.error || 'failed');
    el.dataset.saved = el.value;
    el.classList.add('choice-saved');
    setTimeout(() => el.classList.remove('choice-saved'), 1400);
  } catch (e) {
    el.value = previous;
    toast('Could not save that choice: ' + e.message);
  }
}

// Generating a fix pack for a single check also records that somebody has taken it on, so the
// card moves to 'on record'. Generating every pack at once does not - see the server.
async function generatePack(checkId, btn) {
  const target = document.querySelector(`[data-result="${checkId}"]`);
  const label = btn ? btn.textContent : 'Generate fix pack';
  if (btn) { btn.disabled = true; btn.textContent = 'Generating…'; }
  try {
    const res = await api(`/api/fixpack?check=${encodeURIComponent(checkId)}`, { method: 'POST' });
    if (!res.ok) throw new Error(res.error || 'failed');
    const links = asArray(res.files).map(f =>
      `<a href="/api/download?file=${encodeURIComponent(f)}" download>${esc(f)}</a>`).join(' · ');
    toast(res.marked
      ? `${checkId} recorded as done — ${res.rows} row(s) written to .\\out`
      : `${checkId}: ${asArray(res.files).length} file(s) written to .\\out`);
    if (res.marked && res.report) {
      state.open[checkId] = true;
      renderAll(res.report);
      const t2 = document.querySelector(`[data-result="${checkId}"]`);
      if (t2) t2.innerHTML = `${res.rows} row(s) written — ${links}`;
    } else if (target) {
      target.innerHTML = `${res.rows} row(s) written — ${links}`;
    }
    await refreshFiles();
  } catch (e) {
    if (target) target.textContent = `Failed: ${e.message}`;
    toast(`Could not generate the fix pack for ${checkId}`);
  } finally {
    if (btn && document.body.contains(btn)) { btn.disabled = false; btn.textContent = label; }
  }
}

async function reopenCheck(checkId, btn) {
  if (btn) { btn.disabled = true; btn.textContent = 'Reopening…'; }
  try {
    const res = await api('/api/check/reopen', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ checkId: checkId })
    });
    if (!res.ok) throw new Error(res.error || 'failed');
    state.open[checkId] = true;
    renderAll(res.report);
    toast(`${checkId} is back on the failing list`);
  } catch (e) {
    toast(`Could not reopen ${checkId}: ${e.message}`);
    if (btn) { btn.disabled = false; btn.textContent = 'Reopen check'; }
  }
}

// The server saves the confirmation and re-runs the analysis in one call, so the card that
// held the button is re-rendered from a fresh report rather than patched in place.
async function markNoteImplemented(note, btn) {
  if (btn) { btn.disabled = true; btn.textContent = 'Recording…'; }
  try {
    const res = await api('/api/notes/status', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ notes: [{ note: note, status: 'IMPLEMENTED' }] })
    });
    if (!res.ok) throw new Error(res.error || 'failed');
    state.open['NOTE-01'] = true;
    // Confirming the last outstanding note makes the check pass, and a passed card is hidden
    // by default - which would take the reset button away with it.
    const noteCheck = asArray(res.report.Checks).find(c => c.ActionKind === 'note');
    if (noteCheck && noteCheck.Status === 'PASS') {
      state.showPassed = true;
      $('showPassed').checked = true;
    }
    renderAll(res.report);
    toast(`Note ${note} recorded as implemented — confirm it in SNOTE if you have not already`);
  } catch (e) {
    toast(`Could not record note ${note}: ${e.message}`);
    if (btn) { btn.disabled = false; btn.textContent = 'Mark implemented'; }
  }
}

async function resetNoteConfirmations(btn) {
  if (btn) { btn.disabled = true; btn.textContent = 'Resetting…'; }
  try {
    const res = await api('/api/notes/reset', { method: 'POST' });
    if (!res.ok) throw new Error(res.error || 'failed');
    state.open['NOTE-01'] = true;
    state.showPassed = true;
    $('showPassed').checked = true;
    renderAll(res.report);
    toast('Note confirmations cleared — the catalog statuses apply again');
  } catch (e) {
    toast('Could not reset the confirmations: ' + e.message);
    if (btn) { btn.disabled = false; btn.textContent = 'Reset confirmations'; }
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

// Writing the file into .\out is not exporting it - the person pressing the button wants the
// workbook, not a note that it exists somewhere on disk. The server already serves it as an
// attachment, so an anchor click hands it straight to the browser's downloads.
function downloadFile(name) {
  const a = document.createElement('a');
  a.href = `/api/download?file=${encodeURIComponent(name)}`;
  a.download = name;
  a.style.display = 'none';
  document.body.appendChild(a);
  a.click();
  setTimeout(() => a.remove(), 0);
}

$('excelBtn').onclick = async () => {
  const btn = $('excelBtn');
  btn.disabled = true; btn.textContent = 'Exporting…';
  try {
    const res = await api('/api/excel', { method: 'POST' });
    if (!res.ok) throw new Error(res.error || 'failed');
    downloadFile(res.file);
    toast(`${res.file} downloaded — ${res.rows} record(s) across ${asArray(res.sheets).length} sheet(s), ${res.flagged} carrying a finding`);
    await refreshFiles();
  } catch (e) {
    toast('Excel export failed: ' + e.message);
  } finally {
    btn.disabled = false; btn.textContent = 'Export to Excel';
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
