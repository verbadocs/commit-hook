// ==UserScript==
// @name         GitHub Diff: Prompt History Sidebar
// @namespace    local.verba
// @version      2.0.5
// @description  Per-file "Prompt History" sidebar (pulls latest verba/prompt_history log and filters by file). Collapsible code with arrows.
// @author       you
// @match        https://github.com/*/*/commit/*
// @match        https://github.com/*/*/pull/*/files*
// @run-at       document-idle
// @grant        none
// ==/UserScript==

(function () {
  'use strict';

  const BTN_CLASS = 'gh-open-modal-btn';
  const SIDEBAR_ID = 'gh-mini-sidebar';
  const STYLE_ID = 'gh-mini-sidebar-styles';
  const SIDEBAR_WIDTH = 420;

  const doc = document;

  // ---------- styles (once)
  function ensureStyles() {
    if (doc.getElementById(STYLE_ID)) return;
    const st = doc.createElement('style');
    st.id = STYLE_ID;
    st.textContent = `
      :root { --ghms-width: ${SIDEBAR_WIDTH}px; }
      #${SIDEBAR_ID} {
        position: fixed; top: 0; right: 0; height: 100vh;
        width: var(--ghms-width); max-width: 92vw;
        background: #0d1117; color: #c9d1d9;
        border-left: 1px solid #30363d; box-shadow: -8px 0 40px rgba(0,0,0,.35);
        font: 13px ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
        transform: translateX(100%); transition: transform .2s ease-in-out;
        z-index: 99999; display: flex; flex-direction: column;
      }
      #${SIDEBAR_ID}.open { transform: translateX(0); }
      #${SIDEBAR_ID} .ghms-header {
        display:flex; align-items:center; justify-content:space-between;
        padding: 12px 16px; border-bottom: 1px solid #30363d;
      }
      #${SIDEBAR_ID} .ghms-title { font-weight:600; font-size:14px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      #${SIDEBAR_ID} .ghms-close {
        border:1px solid #30363d; background:#161b22; color:inherit;
        border-radius:6px; padding:4px 8px; cursor:pointer;
      }
      #${SIDEBAR_ID} .ghms-body { padding:16px; overflow:auto; height:100%; }
      #${SIDEBAR_ID} .ghms-empty { opacity:.75 }
      #${SIDEBAR_ID} .ghms-item { margin-bottom:16px; }
      #${SIDEBAR_ID} .ghms-item h4 { margin:0 0 6px 0; font-size:12px; font-weight:700; color:#a5d6ff; }

      #${SIDEBAR_ID} details {
        background:#0b1020; border:1px solid #30363d; border-radius:8px;
      }
      #${SIDEBAR_ID} details > summary {
        list-style:none; cursor:pointer; padding:10px 12px; font-weight:700; color:#a5d6ff;
        display:flex; align-items:center; gap:8px;
      }
      #${SIDEBAR_ID} details > summary::before { content: "▶"; font-size: 12px; transform: translateY(1px); }
      #${SIDEBAR_ID} details[open] > summary::before { content: "▼"; }
      #${SIDEBAR_ID} details > summary::-webkit-details-marker { display:none; }
      #${SIDEBAR_ID} details[open] > summary { border-bottom:1px solid #30363d; }
      #${SIDEBAR_ID} pre { margin:0; padding:10px 12px; background:transparent; border:none; overflow:auto; }

      body.ghms-pushed { padding-right: var(--ghms-width) !important; transition: padding-right .2s ease-in-out; }
      .header-logged-in, .AppHeader-globalBar { transition: padding-right .2s ease-in-out; }
    `;
    doc.head.appendChild(st);
  }

  // ---------- sidebar (once)
  function ensureSidebar() {
    let sidebar = doc.getElementById(SIDEBAR_ID);
    if (sidebar) return sidebar;

    sidebar = doc.createElement('div');
    sidebar.id = SIDEBAR_ID;
    sidebar.innerHTML = `
      <div class="ghms-header">
        <strong class="ghms-title" id="gh-mini-title">File</strong>
        <button class="ghms-close" id="gh-mini-close">Close</button>
      </div>
      <div class="ghms-body" id="gh-mini-body">
        <div class="ghms-empty">Loading…</div>
      </div>
    `;
    doc.body.appendChild(sidebar);

    doc.getElementById('gh-mini-close').onclick = () => {
      sidebar.classList.remove('open');
      doc.body.classList.remove('ghms-pushed');
    };

    return sidebar;
  }

  function openSidebar(title) {
    const sidebar = ensureSidebar();
    ensureStyles();
    doc.getElementById('gh-mini-title').textContent = title || 'File';
    const w = sidebar.getBoundingClientRect().width || SIDEBAR_WIDTH;
    doc.documentElement.style.setProperty('--ghms-width', `${w}px`);
    doc.body.classList.add('ghms-pushed');
    sidebar.classList.add('open');
  }

  // ---------- utilities
  function getRepoContext() {
    const parts = location.pathname.split('/').filter(Boolean);
    const owner = parts[0], repo = parts[1];
    const page = parts[2];
    let ref = 'HEAD';
    if (page === 'commit' && parts[3]) ref = parts[3];
    else if (page === 'pull' && parts.includes('files')) {
      const meta = document.querySelector('div[data-pull-state] [data-hovercard-type="commit"] a[href*="/commit/"]');
      const m = meta?.getAttribute('href')?.match(/\/commit\/([0-9a-f]{7,40})/i);
      if (m) ref = m[1];
    }
    return { owner, repo, ref };
  }

  function getFilePathFromRow(row) {
    let el = row;
    while (el && el !== document.body) {
      const link = el.querySelector('[class*="DiffFileHeader-module__file-name"] a, a.Link--primary[href*="/blob/"]');
      if (link) {
        const txt = (link.textContent || '').trim();
        if (txt) return txt;
        try {
          const u = new URL(link.href, location.origin);
          const parts = u.pathname.split('/').filter(Boolean);
          const i = parts.indexOf('blob');
          if (i >= 0) return decodeURIComponent(parts.slice(i + 2).join('/'));
        } catch {}
      }
      el = el.parentElement;
    }
    return null;
  }

  async function fetchNewestPromptLog({ owner, repo, ref }) {
    const url = `https://api.github.com/repos/${owner}/${repo}/contents/verba/prompt_history?ref=${encodeURIComponent(ref)}`;
    const res = await fetch(url, { headers: { 'Accept': 'application/vnd.github+json' } });
    if (!res.ok) throw new Error(`Failed to list prompt_history (${res.status})`);
    const items = await res.json();
    const mdFiles = (Array.isArray(items) ? items : []).filter(x => x.type === 'file' && /\.md$/i.test(x.name));
    if (!mdFiles.length) throw new Error('No prompt logs found in verba/prompt_history');
    mdFiles.sort((a, b) => a.name.localeCompare(b.name));
    const newest = mdFiles[mdFiles.length - 1];
    const mdRes = await fetch(newest.download_url);
    if (!mdRes.ok) throw new Error(`Failed to download ${newest.name} (${mdRes.status})`);
    return await mdRes.text();
  }

  const lc = s => String(s||'').toLowerCase();
  const norm = s => String(s||'')
    .replace(/[\u200B-\u200D\uFEFF]/g, '')
    .normalize('NFC')
    .replace(/^\.\//, '')
    .replace(/\/{2,}/g, '/')
    .trim();

  function parseLogForFile(markdown, targetPath) {
    const target = lc(norm(targetPath));
    const lines = markdown.split(/\r?\n/);

    const rHead  = /^\s*##\s+\[[^\]]+\]\s+User Prompt:\s*(.*)$/i;
    const rFile  = /^\s*\*\*FILE:\s+(.+?)\*\*\s*$/i;
    const rFence = /^\s*```/;

    const heads = [];
    const files = [];
    for (let i=0;i<lines.length;i++){
      if (rHead.test(lines[i])) heads.push(i);
      const m = lines[i].match(rFile);
      if (m) files.push({ i, pathRaw: m[1], path: lc(norm(m[1])) });
    }

    const matches = files.filter(f =>
      f.path.includes(target) || target.includes(f.path) ||
      f.path.endsWith('/'+target) || target.endsWith('/'+f.path)
    );

    const results = [];
    for (const { i: fi } of matches) {
      let hPrev = -1;
      for (let k=heads.length-1; k>=0; k--) { if (heads[k] < fi) { hPrev = heads[k]; break; } }
      if (hPrev < 0) continue;

      let hNext = lines.length;
      for (let k=0; k<heads.length; k++) { if (heads[k] > fi) { hNext = heads[k]; break; } }

      const block = lines.slice(hPrev, hNext);
      const prompt = (block[0].match(rHead)?.[1] || '(no prompt)').trim();

      const localFileIdx = block.findIndex(l => rFile.test(l));
      let code = '';
      if (localFileIdx >= 0) {
        let j = localFileIdx + 1;
        while (j < block.length && !rFence.test(block[j])) j++;
        if (j < block.length && rFence.test(block[j])) {
          j++;
          const buf = [];
          while (j < block.length && !rFence.test(block[j])) buf.push(block[j++]);
          code = buf.join('\n');
        } else {
          code = block.slice(localFileIdx + 1).join('\n');
        }
      }

      results.push({ prompt, code });
    }

    return results;
  }

  function renderEntries(entries, filePath) {
    const body = doc.getElementById('gh-mini-body');
    if (!body) return;

    body.innerHTML = '';
    if (!entries.length) {
      body.innerHTML = `<div class="ghms-empty">No prompt history found for <code>${escapeHtml(filePath || '')}</code> in the latest log.</div>`;
      return;
    }

    entries.forEach((e, idx) => {
      const wrap = doc.createElement('div');
      wrap.className = 'ghms-item';
      wrap.innerHTML = `
        <h4>#${idx + 1} Prompt</h4>
        <div class="ghms-prompt">${escapeHtml(e.prompt)}</div>
        ${
          e.code
            ? `<details>
                 <summary>File Changes</summary>
                 <pre>${escapeHtml(e.code)}</pre>
               </details>`
            : ''
        }
      `;
      body.appendChild(wrap);
    });
  }

  function escapeHtml(s) {
    return String(s)
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  }

  function guessFileTitle(row) {
    const link = row.closest('.file, .Box, div')
      ?.querySelector('[class*="DiffFileHeader-module__file-name"] a, a.Link--primary[href*="/blob/"]');
    return (link?.textContent?.trim()) || 'File';
  }

  function findHeaderRows(documentRoot) {
    const rows = new Set();

    const utilRows = Array.from(
      documentRoot.querySelectorAll('div.d-flex.flex-justify-end.flex-items-center')
    ).filter(el => {
      const cls = el.className || '';
      return /\bflex-order-2\b/.test(cls) || /\bflex-sm-order-2\b/.test(cls);
    });
    utilRows.forEach(el => rows.add(el));

    documentRoot
      .querySelectorAll('.file-header .file-actions, .file-header div[role="group"]')
      .forEach(el => rows.add(el));

    documentRoot.querySelectorAll('button[aria-haspopup="menu"], button[aria-haspopup="true"]').forEach(btn => {
      let cand = btn.closest('div.d-flex') || btn.closest('div');
      if (!cand) return;
      const right =
        cand.classList.contains('flex-justify-end') ||
        getComputedStyle(cand).justifyContent === 'flex-end';
      const center =
        cand.classList.contains('flex-items-center') ||
        getComputedStyle(cand).alignItems === 'center';
      if (right && center) rows.add(cand);
    });

    return Array.from(rows);
  }

  function inject() {
    const rows = findHeaderRows(doc);
    rows.forEach(row => {
      if (row.querySelector(`.${BTN_CLASS}`)) return;

      const btn = doc.createElement('button');
      btn.className = BTN_CLASS;
      btn.textContent = 'Prompt History';
      btn.style.cssText = 'margin-left:8px;padding:4px 8px;border:1px solid #30363d;border-radius:6px;background:#161b22;color:#c9d1d9;cursor:pointer';

      btn.addEventListener('click', async (e) => {
        e.stopPropagation();

        const filePath = getFilePathFromRow(row) || guessFileTitle(row);
        openSidebar(filePath);

        const body = document.getElementById('gh-mini-body');
        if (body) body.innerHTML = `<div class="ghms-empty">Loading history for <code>${escapeHtml(filePath)}</code>…</div>`;

        try {
          const ctx = getRepoContext();
          const md = await fetchNewestPromptLog(ctx);
          const entries = parseLogForFile(md, filePath);
          renderEntries(entries, filePath);
        } catch (err) {
          if (body) body.innerHTML = `<div class="ghms-empty">Error: ${escapeHtml(err.message || String(err))}</div>`;
        }
      });

      row.appendChild(btn);
    });
  }

  // ---- boot (hoisted) ----
  function boot() { ensureStyles(); ensureSidebar(); inject(); }

  // initial run
  boot();

  // keep your existing observers
  const mo = new MutationObserver(() => inject());
  mo.observe(doc.documentElement, { childList: true, subtree: true });

  // existing GitHub events
  window.addEventListener('turbo:load', boot);
  document.addEventListener('pjax:end', boot);

  // --- SPA nav hooks (minimal; same idea as the pill) ---
  function _fireRoute() { window.dispatchEvent(new Event('verba:locationchange')); }
  const _push = history.pushState;
  const _replace = history.replaceState;
  history.pushState = function (...a) { const r = _push.apply(this, a); _fireRoute(); return r; };
  history.replaceState = function (...a) { const r = _replace.apply(this, a); _fireRoute(); return r; };
  window.addEventListener('verba:locationchange', boot);
  window.addEventListener('popstate', boot);
})();
