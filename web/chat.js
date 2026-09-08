'use strict';

// Self-contained chat widget - it builds its own DOM, so a page only has to include it.
(function () {

  const asArray = v => (v === null || v === undefined) ? [] : (Array.isArray(v) ? v : [v]);
  const esc = s => String(s === null || s === undefined ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  const SUGGESTIONS = [
    'What should I fix first?',
    'Explain CFG-06',
    'Number ranges',
    'Which records are duplicates?',
    'What passed?'
  ];

  const history = [];   // {role, content} - the last few turns, sent back for continuity

  const el = document.createElement('div');
  el.innerHTML = `
    <button class="chat-launcher" id="chatLauncher" aria-label="Open the assistant">
      <span class="chat-launcher-dot"></span>Ask about this report
    </button>
    <section class="chat-panel" id="chatPanel" hidden aria-label="Report assistant">
      <header class="chat-head">
        <div>
          <strong>Report assistant</strong>
          <span class="chat-mode" id="chatMode">answers from the loaded report</span>
        </div>
        <button class="chat-close" id="chatClose" aria-label="Close">×</button>
      </header>
      <div class="chat-log" id="chatLog"></div>
      <div class="chat-suggest" id="chatSuggest"></div>
      <form class="chat-input" id="chatForm">
        <input id="chatText" type="text" autocomplete="off" placeholder="Ask about a finding, a record, or a number range…">
        <button class="btn btn-primary" id="chatSend" type="submit">Send</button>
      </form>
    </section>`;
  document.body.appendChild(el);

  const $ = id => document.getElementById(id);
  const log = $('chatLog');

  // Plain text with '- ' bullets and **bold** - deliberately not a markdown renderer.
  function format(text) {
    const lines = String(text).split(/\r?\n/);
    let html = '';
    let inList = false;
    for (const raw of lines) {
      const line = esc(raw).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
      const bullet = /^\s*-\s+(.*)$/.exec(line);
      if (bullet) {
        if (!inList) { html += '<ul>'; inList = true; }
        html += `<li>${bullet[1]}</li>`;
      } else {
        if (inList) { html += '</ul>'; inList = false; }
        if (line.trim() === '') { html += '<div class="chat-gap"></div>'; }
        else { html += `<p>${line}</p>`; }
      }
    }
    if (inList) html += '</ul>';
    return html;
  }

  function bubble(role, text, refs) {
    const wrap = document.createElement('div');
    wrap.className = `chat-msg chat-${role}`;
    let chips = '';
    if (refs && refs.length) {
      const unique = [...new Set(refs)];
      chips = `<div class="chat-refs">${unique.map(r =>
        `<a class="chat-ref" href="/?check=${encodeURIComponent(r)}">${esc(r)}</a>`).join('')}</div>`;
    }
    wrap.innerHTML = (role === 'user' ? `<p>${esc(text)}</p>` : format(text)) + chips;
    log.appendChild(wrap);
    log.scrollTop = log.scrollHeight;
    return wrap;
  }

  function renderSuggestions() {
    $('chatSuggest').innerHTML = SUGGESTIONS.map(s =>
      `<button class="chat-chip" type="button">${esc(s)}</button>`).join('');
    $('chatSuggest').querySelectorAll('.chat-chip').forEach(b => {
      b.onclick = () => { $('chatText').value = b.textContent; send(); };
    });
  }

  let busy = false;

  async function send() {
    const input = $('chatText');
    const text = input.value.trim();
    if (!text || busy) return;
    busy = true;
    input.value = '';
    bubble('user', text);
    history.push({ role: 'user', content: text });

    const thinking = bubble('bot', '…');
    thinking.classList.add('chat-thinking');
    $('chatSend').disabled = true;

    try {
      const res = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ message: text, history: history.slice(-8, -1) })
      });
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      thinking.remove();
      bubble('bot', data.answer, asArray(data.refs));
      history.push({ role: 'assistant', content: String(data.answer).slice(0, 4000) });
      while (history.length > 8) history.shift();
      $('chatMode').textContent = data.mode;
    } catch (e) {
      thinking.remove();
      bubble('bot', 'Could not reach the assistant: ' + e.message);
    } finally {
      busy = false;
      $('chatSend').disabled = false;
      input.focus();
    }
  }

  function open() {
    $('chatPanel').hidden = false;
    $('chatLauncher').hidden = true;
    $('chatText').focus();
    if (!log.childElementCount) {
      bubble('bot', 'I answer from the report that is loaded — findings, affected records, and the number range proposal. I cannot see or change the SAP system.');
    }
  }

  function close() {
    $('chatPanel').hidden = true;
    $('chatLauncher').hidden = false;
  }

  $('chatLauncher').onclick = open;
  $('chatClose').onclick = close;
  $('chatForm').onsubmit = ev => { ev.preventDefault(); send(); };
  document.addEventListener('keydown', ev => {
    if (ev.key === 'Escape' && !$('chatPanel').hidden) close();
  });

  renderSuggestions();
})();
