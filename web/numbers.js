'use strict';

const asArray = v => (v === null || v === undefined) ? [] : (Array.isArray(v) ? v : [v]);
const $ = id => document.getElementById(id);
const esc = s => String(s === null || s === undefined ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const num = s => /^[0-9]+$/.test(String(s || '')) ? Number(s) : null;

// Status colour is meaning, not decoration: every pill carries its own word as well.
const STATUS = {
  'OK':                'good',
  'KEEP':              'good',
  'UNUSED':            'neutral',
  'CATCH-ALL':         'warning',
  'NEARLY FULL':       'warning',
  'INTERNAL':          'warning',
  'TIGHTEN':           'warning',
  'EDIT INTERVAL':     'serious',
  'MOVE':              'serious',
  'SET EXTERNAL':      'serious',
  'ADD INTERVAL':      'serious',
  'EDITED':            'warning',
  'DOES NOT COVER':    'critical',
  'OUT OF RANGE':      'critical',
  'TOO NARROW':        'critical',
  'NO RANGE':          'critical',
  'CREATE':            'critical',
  'CREATE GROUPING':   'critical',
  'RESOLVE COLLISION': 'critical'
};

const pill = s => `<span class="pill pill-${STATUS[s] || 'neutral'}"><span class="dot dot-${STATUS[s] || 'neutral'}"></span>${esc(s)}</span>`;

function toast(msg) {
  const t = $('toast');
  t.textContent = msg; t.hidden = false;
  clearTimeout(t._timer);
  t._timer = setTimeout(() => { t.hidden = true; }, 3200);
}

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

function table(el, cols, rows, cellFns) {
  el.innerHTML =
    `<thead><tr>${cols.map(c => `<th>${esc(c)}</th>`).join('')}</tr></thead>` +
    `<tbody>${rows.map(r => `<tr>${cellFns.map(fn => fn(r)).join('')}</tr>`).join('')}</tbody>`;
}

// ---------------------------------------------------------------- range map

function renderMap(proposals) {
  // Only the external converted intervals go on the map - the internal interval for new
  // partners sits billions away and would flatten everything else to a hairline.
  const rows = proposals
    .filter(p => p.External && num(p.From) !== null && num(p.To) !== null)
    .map(p => ({
      grouping: p.Part ? `${p.Grouping} (${p.Part})` : p.Grouping,
      action: p.Action,
      from: num(p.From), to: num(p.To),
      usedFrom: num(p.UsedFrom), usedTo: num(p.UsedTo),
      records: p.Records
    }));

  if (!rows.length) { $('map').innerHTML = '<p class="muted">No external interval to plot.</p>'; return; }

  const lo = Math.min(...rows.map(r => r.from));
  const hi = Math.max(...rows.map(r => r.to));
  const span = (hi - lo) || 1;
  const pct = v => ((v - lo) / span) * 100;

  $('map').innerHTML = rows.map(r => {
    const left = pct(r.from);
    const width = Math.max(pct(r.to) - left, 0.4);
    let used = '';
    if (r.usedFrom !== null && r.usedTo !== null) {
      const uLeft = ((r.usedFrom - r.from) / ((r.to - r.from) || 1)) * 100;
      const uWidth = Math.max((((r.usedTo - r.usedFrom) || 1) / ((r.to - r.from) || 1)) * 100, 1.5);
      used = `<i class="map-used" style="left:${uLeft}%;width:${uWidth}%"></i>`;
    }
    return `<div class="map-row">
      <div class="map-label">${esc(r.grouping)}<small>${r.records} rec</small></div>
      <div class="map-track">
        <div class="map-band" style="left:${left}%;width:${width}%">${used}</div>
      </div>
      <div class="map-value">${esc(String(r.from).padStart(10, '0'))}–${esc(String(r.to).padStart(10, '0'))}</div>
    </div>`;
  }).join('');
}

// ---------------------------------------------------------------- render

function render(r) {
  const plan = r.NumberPlan;
  const c = plan.Counts;

  $('systemLine').textContent =
    `${plan.Strategy.replace('_', ' ').toLowerCase()} strategy · analysed ${r.GeneratedAt}`;

  $('tSource').textContent = c.SourceRanges;
  $('tSourceNote').textContent = `${c.SourceIssues} with a finding`;
  $('tBp').textContent = c.BpRanges;
  $('tBpNote').textContent = `${c.BpIssues} unusable as they stand`;
  $('tChanges').textContent = c.Changes;
  $('tChangesNote').textContent = `of ${c.Proposals} proposed intervals`;
  $('tCollisions').textContent = c.Collisions;
  $('tOverlaps').textContent = c.Overlaps;
  $('tCovered').textContent = c.RecordsCovered;
  $('tCoveredNote').textContent = `of ${c.RecordsTotal} records reach a grouping`;

  const proposals = asArray(plan.Proposals);
  let note = `${c.Changes} of ${c.Proposals} intervals need a change before the mass run.`;
  if (c.Edited) note += ` ${c.Edited} edited by hand.`;
  if (c.Invalid) note += ` ${c.Invalid} do not cover their records.`;
  $('planNote').textContent = note;

  const outstanding = proposals.filter(p => p.Action !== 'KEEP' && !p.Confirmed).length;
  $('sendNote').textContent = c.Confirmed
    ? `${c.Confirmed} interval(s) confirmed${outstanding ? `, ${outstanding} still unconfirmed` : ' — all changes signed off'}.`
    : 'Nothing confirmed yet — only confirmed intervals go into the package.';

  renderMap(proposals);

  table($('proposalTable'),
    ['Grouping', 'Sources', 'Records', 'Used band', 'Current interval', 'Proposed interval (editable)', 'Ext', 'Confirm', 'Headroom', 'Action', 'Why'],
    proposals,
    [
      p => `<td class="key"><strong>${esc(p.Grouping)}</strong>${p.Part ? `<br><span class="muted">interval ${esc(p.Part)}</span>` : ''}<br><span class="muted">${esc(p.Text)}</span></td>`,
      p => `<td class="detail">${esc(p.AccountGroups || '—')}</td>`,
      p => `<td class="val">${p.Records || ''}</td>`,
      p => `<td class="val">${p.UsedFrom ? esc(p.UsedFrom) + '–' + esc(p.UsedTo) : '—'}</td>`,
      p => `<td class="val">${esc(p.CurrentRange)}</td>`,
      p => `<td class="edit-cell">
              <input class="in in-range" data-id="${esc(p.Id)}" data-field="rangeNo" value="${esc(p.RangeNo)}" maxlength="10" aria-label="Range key for ${esc(p.Grouping)}">
              <input class="in in-num" data-id="${esc(p.Id)}" data-field="from" value="${esc(p.From)}" maxlength="10" inputmode="numeric" aria-label="From number">
              <span class="dash">–</span>
              <input class="in in-num" data-id="${esc(p.Id)}" data-field="to" value="${esc(p.To)}" maxlength="10" inputmode="numeric" aria-label="To number">
              ${p.Edited ? `<div class="edit-flag">edited · tool proposed ${esc(p.BaseRangeNo)}: ${esc(p.BaseFrom)}–${esc(p.BaseTo)}</div>` : ''}
              ${p.Valid ? '' : `<div class="edit-bad">${esc(p.ValidationNote)}</div>`}
            </td>`,
      p => `<td class="val"><input type="checkbox" class="in-ext" data-id="${esc(p.Id)}" data-field="external" ${p.External ? 'checked' : ''} aria-label="External numbering"></td>`,
      p => `<td class="val"><input type="checkbox" class="in-ext in-confirm" data-id="${esc(p.Id)}" data-field="confirmed" ${p.Confirmed ? 'checked' : ''} ${p.Valid ? '' : 'title="This interval does not cover its records"'} aria-label="Confirm this interval"></td>`,
      p => `<td class="val">${p.Headroom ? Number(p.Headroom).toLocaleString() : '—'}</td>`,
      p => `<td>${pill(p.Action)}${p.Valid ? '' : '<br>' + pill('DOES NOT COVER')}</td>`,
      p => `<td class="detail">${esc(p.Rationale)}</td>`
    ]);

  wireEditors(proposals);

  const collisions = asArray(plan.Collisions);
  const overlaps = asArray(plan.Overlaps);
  if (collisions.length || overlaps.length) {
    $('conflictSection').hidden = false;
    let html = '';
    if (collisions.length) {
      html += `<h3 class="sub-head">${collisions.length} number(s) claimed by both a customer and a vendor</h3>
        <p class="muted" style="margin-bottom:10px">Each becomes one BP number. Decide a single partner carrying both roles, or move one side to its own interval.</p>
        <div class="table-wrap"><table><thead><tr><th>Number</th><th>Grouping</th><th>Records</th></tr></thead><tbody>` +
        collisions.map(x => `<tr><td class="key">${esc(x.Number)}</td><td class="key">${esc(x.Groupings)}</td><td class="detail">${esc(x.Names)}</td></tr>`).join('') +
        '</tbody></table></div>';
    }
    if (overlaps.length) {
      html += `<h3 class="sub-head" style="margin-top:16px">${overlaps.length} overlapping proposed interval(s)</h3>` +
        overlaps.map(o => `<p class="muted">${esc(o.Left)} overlaps ${esc(o.Right)}. ${esc(o.Note)}</p>`).join('');
    }
    $('conflicts').innerHTML = html;
  }

  table($('sourceTable'),
    ['Object', 'Range', 'Interval', 'Ext', 'Current', 'Account groups', 'Records', 'Used band', 'Left', 'Status', 'Note'],
    asArray(plan.SourceRanges),
    [
      s => `<td class="key">${esc(s.Object)}</td>`,
      s => `<td class="key">${esc(s.RangeNo)}</td>`,
      s => `<td class="val">${esc(s.From)}–${esc(s.To)}</td>`,
      s => `<td class="val">${s.External ? 'X' : ''}</td>`,
      s => `<td class="val">${esc(s.Current)}</td>`,
      s => `<td class="detail">${esc(s.AccountGroups || '—')}</td>`,
      s => `<td class="val">${s.Records}</td>`,
      s => `<td class="val">${s.MinUsed ? esc(s.MinUsed) + '–' + esc(s.MaxUsed) : '—'}</td>`,
      s => `<td class="val">${s.Remaining === null || s.Remaining === undefined ? '—' : Number(s.Remaining).toLocaleString()}</td>`,
      s => `<td>${pill(s.Status)}</td>`,
      s => `<td class="detail">${esc(s.Note)}</td>`
    ]);

  table($('bpTable'),
    ['Grouping', 'Range', 'Interval', 'Ext', 'Routed here', 'Records', 'Used band', 'Outside', 'Status', 'Note'],
    asArray(plan.BpRanges),
    [
      b => `<td class="key"><strong>${esc(b.Grouping)}</strong><br><span class="muted">${esc(b.Text)}</span></td>`,
      b => `<td class="key">${esc(b.RangeNo)}</td>`,
      b => `<td class="val">${b.From ? esc(b.From) + '–' + esc(b.RawTo) : '—'}</td>`,
      b => `<td class="val">${b.External ? 'X' : ''}</td>`,
      b => `<td class="detail">${esc(b.AccountGroups || '—')}</td>`,
      b => `<td class="val">${b.Records}</td>`,
      b => `<td class="val">${b.MinUsed ? esc(b.MinUsed) + '–' + esc(b.MaxUsed) : '—'}</td>`,
      b => `<td class="val">${b.Outside || ''}</td>`,
      b => `<td>${pill(b.Status)}</td>`,
      b => `<td class="detail">${esc(b.Note)}</td>`
    ]);
}

// ---------------------------------------------------------------- editing

const dirty = new Map();   // id -> {id, grouping, rangeNo, from, to, external, confirmed, note}
let lastProposals = [];

function currentRow(id, proposals) {
  const p = proposals.find(x => x.Id === id);
  const base = dirty.get(id) || {
    id,
    grouping: p ? p.Grouping : '',
    rangeNo: p ? p.RangeNo : '',
    from: p ? p.From : '',
    to: p ? p.To : '',
    external: p ? !!p.External : false,
    confirmed: p ? !!p.Confirmed : false,
    note: p ? (p.Note || '') : ''
  };
  dirty.set(id, base);
  return base;
}

function refreshEditState() {
  const n = dirty.size;
  $('saveBtn').disabled = n === 0;
  $('editState').textContent = n === 0 ? '' : `${n} row(s) changed and not saved`;
}

function wireEditors(proposals) {
  lastProposals = proposals;
  document.querySelectorAll('#proposalTable .in, #proposalTable .in-ext').forEach(input => {
    const commit = () => {
      const id = input.dataset.id;
      const row = currentRow(id, proposals);
      const value = input.type === 'checkbox' ? input.checked : input.value.trim();
      row[input.dataset.field] = value;

      // Nothing actually changed? drop the row so Save does not rewrite it.
      const p = proposals.find(x => x.Id === id);
      if (p && row.rangeNo === p.RangeNo && row.from === p.From && row.to === p.To
          && row.external === !!p.External && row.confirmed === !!p.Confirmed) {
        dirty.delete(id);
      }
      refreshEditState();
    };
    input.addEventListener('change', commit);
    input.addEventListener('input', commit);
  });
  refreshEditState();
}

async function saveEdits() {
  const btn = $('saveBtn');
  btn.disabled = true; btn.textContent = 'Saving…';
  try {
    const res = await api('/api/numbers/save', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ overrides: [...dirty.values()] })
    });
    if (!res.ok) throw new Error(res.error || 'failed');
    dirty.clear();
    render(res.report);
    const bad = asArray(res.report.NumberPlan.Proposals).filter(p => !p.Valid).length;
    toast(bad ? `Saved — ${bad} interval(s) no longer cover their records` : 'Saved and re-checked');
  } catch (e) {
    toast('Save failed: ' + e.message);
  } finally {
    btn.textContent = 'Save changes';
    refreshEditState();
  }
}

async function resetEdits() {
  const btn = $('resetBtn');
  btn.disabled = true; btn.textContent = 'Resetting…';
  try {
    const res = await api('/api/numbers/reset', { method: 'POST' });
    if (!res.ok) throw new Error(res.error || 'failed');
    dirty.clear();
    render(res.report);
    toast('Edits cleared — back to the proposed intervals');
  } catch (e) {
    toast('Reset failed: ' + e.message);
  } finally {
    btn.disabled = false; btn.textContent = 'Reset to proposed';
  }
}

$('saveBtn').onclick = saveEdits;
$('resetBtn').onclick = resetEdits;

// ---------------------------------------------------------------- sending

function renderSendResult(res) {
  const parts = [];
  if (res.blockers && res.blockers.length) {
    parts.push(`<p class="send-bad"><strong>Not ready to apply:</strong></p><ul>${
      asArray(res.blockers).map(b => `<li>${esc(b)}</li>`).join('')}</ul>`);
  }
  if (res.warnings && res.warnings.length) {
    parts.push(`<p><strong>Read before applying:</strong></p><ul>${
      asArray(res.warnings).map(w => `<li>${esc(w)}</li>`).join('')}</ul>`);
  }
  const links = asArray(res.files).map(f =>
    `<a href="/api/download?file=${encodeURIComponent(f)}" download>${esc(f.replace('send\\', ''))}</a>`).join(' · ');
  parts.push(`<p>${esc(res.message)} ${res.intervals} interval(s) and ${res.mappings} account group assignment(s), written to <code>${esc(res.sendDir)}</code>.</p>`);
  if (links) parts.push(`<p>${links}</p>`);

  const t = res.target || {};
  if (t.enabled) {
    parts.push(`<p>Target system <strong>${esc(t.systemId)}</strong> at <code>${esc(t.baseUrl)}</code> is configured${res.posted ? ' — payload posted.' : '.'}</p>`);
    $('pushBtn').hidden = !res.ready;
  } else {
    parts.push(`<p class="muted">No direct push: ${esc(t.note || 'no target system configured')}. The package is applied by hand — see the runbook.</p>`);
    $('pushBtn').hidden = true;
  }
  $('sendResult').innerHTML = parts.join('');
}

async function buildPackage(push) {
  const btn = push ? $('pushBtn') : $('sendBtn');
  const label = btn.textContent;
  btn.disabled = true; btn.textContent = push ? 'Pushing…' : 'Building…';
  try {
    const res = await api('/api/numbers/send', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ push: !!push })
    });
    if (!res.ok) throw new Error(res.error || 'failed');
    renderSendResult(res);
    toast(res.ready ? (push ? res.message : `Package built for ${res.intervals} interval(s)`) : 'Confirmed set is not ready — see the blockers');
  } catch (e) {
    toast('Send failed: ' + e.message);
  } finally {
    btn.disabled = false; btn.textContent = label;
  }
}

$('sendBtn').onclick = () => buildPackage(false);

$('pushBtn').onclick = () => {
  const ok = window.confirm('Post the confirmed intervals to the configured target system? This writes to that system.');
  if (ok) buildPackage(true);
};

$('confirmAllBtn').onclick = async () => {
  let n = 0;
  for (const p of lastProposals) {
    if (!p.Valid || p.Confirmed || p.Action === 'KEEP') continue;
    dirty.set(p.Id, {
      id: p.Id, grouping: p.Grouping, rangeNo: p.RangeNo, from: p.From, to: p.To,
      external: !!p.External, confirmed: true, note: p.Note || ''
    });
    n++;
  }
  if (n === 0) { toast('Nothing left to confirm'); return; }
  refreshEditState();
  await saveEdits();
};

// ---------------------------------------------------------------- boot

const PROPOSAL_CSV = 'CVI_NUMBER_RANGE_PROPOSAL.csv';

// The server sends these with Content-Disposition: attachment, so this saves the file
// rather than navigating the page to it.
function downloadFile(name) {
  const a = document.createElement('a');
  a.href = `/api/download?file=${encodeURIComponent(name)}`;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

$('exportBtn').onclick = async () => {
  const btn = $('exportBtn');
  btn.disabled = true; btn.textContent = 'Exporting…';
  try {
    const res = await api('/api/fixpack?check=NUMBERS', { method: 'POST' });
    if (!res.ok) throw new Error(res.error || 'failed');
    const files = asArray(res.files);
    downloadFile(PROPOSAL_CSV);   // hand over the spreadsheet straight away
    const links = files.map(f =>
      `<a href="/api/download?file=${encodeURIComponent(f)}" download>${esc(f)}</a>`).join(' · ');
    $('exportResult').innerHTML =
      `${res.rows} proposed interval(s) exported. <strong>${esc(PROPOSAL_CSV)}</strong> is downloading; all ${files.length} file(s) are in <code>${esc(res.outDir)}</code> — ${links}`;
    toast(`${PROPOSAL_CSV} downloaded`);
  } catch (e) {
    toast('Export failed: ' + e.message);
  } finally {
    btn.disabled = false; btn.textContent = 'Export proposal';
  }
};

(async function init() {
  try {
    render(await api('/api/report'));
  } catch (e) {
    $('systemLine').textContent = 'Could not load the report: ' + e.message;
  }
})();
