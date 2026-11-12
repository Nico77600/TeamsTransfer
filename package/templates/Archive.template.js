/* TeamsTransfer - offline Teams-like preview (viewer).
 *
 * Single page, no library, no network. Data comes from the manifest (<script type="application/json" id="tt-manifest">) and from
 * per-conversation chunks loaded lazily: folder archive = data/<conv>/<month>.js files (JSONP: TT.chunk(path, [...]), works from file://),
 * single-file archive = gzip+base64 blocks embedded in the page (<script type="application/x-tt-gzip" id="...">).
 * Format: package\schemas\preview-v1.schema.json.
 *
 * SECURITY: message HTML is untrusted. sanitize() parses it with DOMParser (inert document, nothing loads, nothing runs) and BUILDS a new
 * DOM from an allow-list; it never re-serializes into innerHTML. Allowed tags: p br div span b strong i em u s strike sub sup blockquote pre
 * code ul ol li a img table thead tbody tr th td h1-h6 hr, at (-> span.mention), emoji (-> its alt text), codeblock (-> pre).
 * Allowed attributes: a[href] (http, https, mailto only; rel=noopener noreferrer; target=_blank), img[src] (ONLY tt:<sha256>.<ext> content
 * references written by the generator, resolved to a local file or an embedded blob; never a URL), img[alt|title|width|height], a[title],
 * td/th[colspan|rowspan], dir (ltr|rtl|auto). No style attribute at all, no class, no id, no event handler, no data-*.
 * script style iframe object embed form svg math ... are dropped WITH their content; unknown benign tags are unwrapped (text is kept).
 * Everything else the UI shows (names, subjects, file names, card texts) goes through textContent.
 */
(function () {
  'use strict';
  var HTML_NS = 'http://www.w3.org/1999/xhtml';

  /* ================================================================ i18n */
  var I18N = {
    en: {
      readOnly: 'Offline read-only archive', chats: 'Chat', railChats: 'Chat', appSearch: 'Search', tabChat: 'Chat', tabFiles: 'Files', filesEmpty: 'No file was shared in this conversation.', filesBy: 'Shared by {n}', showInChat: 'Show in chat', teams: 'Teams', filter: 'Filter…', searchPh: 'Search the archive  ( / )',
      scopeConv: 'This conversation', scopeAll: 'All conversations', noConv: 'No conversation', pickConv: 'Select a conversation',
      pickHint: 'Pick a conversation in the list to read it. This archive is an offline, read-only copy.',
      statConv: 'conversations', statMsg: 'messages', statFiles: 'files',
      members: '{n} members', member1: '1 member', messages: '{n} messages', message1: '1 message', period: 'from {a} to {b}',
      k_oneOnOne: '1:1', k_group: 'Group', k_meeting: 'Meeting', k_channel_standard: 'Channel', k_channel_private: 'Private channel', k_channel_shared: 'Shared channel',
      edited: 'Edited', editedAt: 'Edited on {d}', deleted: 'This message has been deleted.', deletedAt: 'Deleted on {d}', urgent: 'Urgent', important: 'Important',
      replies: '{n} replies', reply1: '1 reply', hideReplies: 'Collapse replies', lastReply: 'last reply {d}',
      exported: 'Exported copy', open: 'Open', notExported: 'Not exported',
      fs_notfound: 'File not found at export time', fs_forbidden: 'Access denied at export time', fs_toolarge: 'Too large, not copied', fs_excluded: 'Excluded from the export',
      fs_failed: 'Download failed', fs_pending: 'Not downloaded', fs_unknown: 'Not exported', fs_notembedded: 'Not embedded in this single file (see the folder archive)',
      card: 'Card', quote: 'Quote', attachment: 'Attachment', imgMissing: 'Image not exported', imgRemote: 'Remote image (not loaded)', imgNotEmbedded: 'Image not embedded',
      jumpDate: 'Jump to date', jumpDateHint: 'YYYY-MM-DD', jumpDateBad: 'Enter a date as YYYY-MM-DD', toBottom: 'Latest message', results: '{n} results', result1: '1 result', noResults: 'No result', moreResults: 'more than {n} results, refine the search',
      searching: 'Searching… {a}/{b} conversations', searchDone: 'Search complete: {b} conversations', searchTitle: 'Results for "{q}"', loading: 'Loading…', loadError: 'Unreadable data',
      themeAuto: 'Theme: automatic', themeLight: 'Theme: light', themeDark: 'Theme: dark', langBtn: 'FR', helpTitle: 'Keyboard shortcuts', close: 'Close', showMore: 'Show more',
      sk_search: 'Search', sk_search2: 'Search (also Ctrl+K)', sk_nav: 'Previous / next conversation', sk_list: 'Browse the list', sk_open: 'Open the conversation', sk_date: 'Jump to a date',
      sk_esc: 'Close / cancel', sk_scroll: 'Scroll the messages', sk_help: 'This help',
      you: 'You', unknownAuthor: 'Unknown author', bot: 'app', s_deleted: 'former account', s_external: 'external', s_guest: 'guest', empty: 'No message in this conversation.',
      generated: 'Exported on {d}', scope: 'Scope: {s}', emptyChat: '(empty conversation)', membersTitle: 'Members', unavailable: 'Message unavailable',
      ev_default: 'System event ({t})', ev_membersAdded: '{by} added {who}', ev_membersAdded0: '{who} was added to the conversation', ev_membersDeleted: '{by} removed {who}', ev_membersDeleted0: '{who} was removed from the conversation',
      ev_membersJoined: '{who} joined the conversation', ev_membersLeft: '{who} left the conversation', ev_chatRenamed: '{by} renamed the conversation to "{nm}"', ev_chatRenamed0: 'The conversation was renamed to "{nm}"',
      ev_callStarted: 'Call or meeting started', ev_callEnded: 'Call or meeting ended · duration {dur}', ev_callEnded0: 'Call or meeting ended', ev_callRecording: 'Meeting recording available',
      ev_callTranscript: 'Meeting transcript available', ev_teamsAppInstalled: 'App "{nm}" added', ev_teamsAppRemoved: 'App "{nm}" removed',
      ev_channelAdded: 'Channel "{nm}" created', ev_channelDeleted: 'Channel "{nm}" deleted', ev_channelRenamed: 'Channel renamed to "{nm}"', ev_teamRenamed: 'Team renamed to "{nm}"'
    }
  };
  var lang = 'en';   // English only; add a table to I18N (and a switch) to translate
  function t(k, a) {
    var s = (I18N[lang] && I18N[lang][k]) || I18N.en[k] || k;
    if (a) for (var p in a) if (Object.prototype.hasOwnProperty.call(a, p)) s = s.split('{' + p + '}').join(a[p]);
    return s;
  }

  /* ================================================================ DOM helpers (no innerHTML anywhere) */
  function $(id) { return document.getElementById(id); }
  function el(tag, props, kids) {
    var e = document.createElement(tag);
    if (props) for (var k in props) {
      if (!Object.prototype.hasOwnProperty.call(props, k)) continue;
      var v = props[k];
      if (v == null || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = v;
      else if (k === 'on') for (var ev in v) e.addEventListener(ev, v[ev]);
      else e.setAttribute(k, v === true ? '' : String(v));
    }
    if (kids) for (var i = 0; i < kids.length; i++) if (kids[i] != null) e.appendChild(typeof kids[i] === 'string' ? document.createTextNode(kids[i]) : kids[i]);
    return e;
  }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }
  var ICONS = {
    chat: 'M4 5h16v11H9l-5 4z', teams: 'M9 11a3 3 0 100-6 3 3 0 000 6zM3 20c0-3.3 2.7-6 6-6s6 2.7 6 6M17 10a2.5 2.5 0 100-5M17 14c2.5 0 4 2 4 5',
    search: 'M11 4a7 7 0 100 14 7 7 0 000-14zM21 21l-5-5', sun: 'M12 8a4 4 0 100 8 4 4 0 000-8zM12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M5 19l1.5-1.5M17.5 6.5L19 5',
    moon: 'M20 14A8 8 0 1110 4a6.5 6.5 0 0010 10z', auto: 'M12 3a9 9 0 100 18 9 9 0 000-18zM12 3v18', calendar: 'M4 6h16v14H4zM4 10h16M8 3v4M16 3v4',
    down: 'M12 5v14M6 13l6 6 6-6', lock: 'M6 11h12v9H6zM8 11V8a4 4 0 018 0v3', back: 'M15 5l-7 7 7 7', users: 'M9 11a3 3 0 100-6 3 3 0 000 6zM3 20c0-3.3 2.7-6 6-6s6 2.7 6 6M17 10a2.5 2.5 0 100-5M17 14c2.5 0 4 2 4 5',
    caret: 'M6 9l6 6 6-6', files: 'M7 3h7l5 5v13H7zM14 3v5h5'
  };
  function icon(name) {
    var s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('aria-hidden', 'true');
    var p = document.createElementNS('http://www.w3.org/2000/svg', 'path'); p.setAttribute('d', ICONS[name] || ''); s.appendChild(p);
    return s;
  }

  /* ================================================================ sanitizer */
  var DROP = {};
  ('script style iframe frame frameset object embed applet form svg math noscript template head title meta link base audio video source track canvas select option optgroup ' +
   'textarea input button dialog portal noembed noframes xmp plaintext datalist map area attachment systemeventmessage slot').split(' ').forEach(function (x) { DROP[x] = 1; });
  var KEEP = {};
  ('p br div span b strong i em u s sub sup blockquote pre code ul ol li a img table thead tbody tr th td h1 h2 h3 h4 h5 h6 hr').split(' ').forEach(function (x) { KEEP[x] = 1; });
  var RENAME = { strike: 's', del: 's', codeblock: 'pre' };
  var MAX_NODES = 20000, MAX_DEPTH = 40;

  function squash(s) {   // remove whitespace, controls and invisible characters: "jav&#9;ascript:" must not survive as a scheme
    var o = "";
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c <= 0x20 || (c >= 0x7f && c <= 0x9f) || c === 0xad || (c >= 0x200b && c <= 0x200f) || c === 0x2028 || c === 0x2029 || c === 0x2060 || c === 0xfeff) continue;
      o += s.charAt(i);
    }
    return o;
  }
  function safeHref(v) {
    var s = String(v == null ? '' : v);
    var squashed = squash(s);
    if (!/^(https?:|mailto:)/i.test(squashed) || squashed.length > 2048) return null;
    try {
      var u = new URL(s.trim());
      if (u.protocol !== 'http:' && u.protocol !== 'https:' && u.protocol !== 'mailto:') return null;
      return u.href;
    } catch (e) { return null; }
  }
  var IMG_REF = /^tt:(?:([0-9a-f]{64}\.[a-z0-9]{1,5})|(missing|remote))$/;

  function textOf(n) { return n.textContent || ''; }

  /* ctx: { img(ref) -> url|null  (ref = '<sha>.<ext>'), at: {id: userIndex}, viewer: userIndex|null } */
  function sanitizeInto(src, dst, st, depth, ctx) {
    for (var n = src.firstChild; n; n = n.nextSibling) {
      if (st.nodes > MAX_NODES) { st.truncated = true; return; }
      if (n.nodeType === 3) { dst.appendChild(document.createTextNode(n.nodeValue)); st.nodes++; continue; }
      if (n.nodeType !== 1) continue;
      if (n.namespaceURI !== HTML_NS) continue;                 // svg / math / foreign content: dropped with its subtree
      var tag = String(n.localName).toLowerCase();
      if (DROP[tag]) continue;
      st.nodes++;
      if (depth >= MAX_DEPTH) { dst.appendChild(document.createTextNode(textOf(n))); continue; }
      var out;
      if (tag === 'emoji') { dst.appendChild(document.createTextNode((n.getAttribute('alt') || textOf(n) || '').slice(0, 16))); continue; }
      if (tag === 'at') {
        out = document.createElement('span'); out.className = 'mention';
        var aid = n.getAttribute('id');
        if (ctx && ctx.viewer != null && ctx.at && aid != null && ctx.at[aid] === ctx.viewer) out.className = 'mention me';
        sanitizeInto(n, out, st, depth + 1, ctx); dst.appendChild(out); continue;
      }
      if (tag === 'a') {
        var href = safeHref(n.getAttribute('href'));
        if (href) {
          out = document.createElement('a'); out.setAttribute('href', href); out.setAttribute('rel', 'noopener noreferrer'); out.setAttribute('target', '_blank');
          out.setAttribute('title', (n.getAttribute('title') || href).slice(0, 300));
        } else out = document.createElement('span');
        sanitizeInto(n, out, st, depth + 1, ctx); dst.appendChild(out); continue;
      }
      if (tag === 'img') {
        var m = IMG_REF.exec(String(n.getAttribute('src') || '').trim());
        var url = m && m[1] && ctx && ctx.img ? ctx.img(m[1]) : null;
        if (url) {
          out = document.createElement('img'); out.className = 'inl'; out.setAttribute('src', url);
          out.setAttribute('alt', String(n.getAttribute('alt') || '').slice(0, 200));
          if (n.getAttribute('title')) out.setAttribute('title', String(n.getAttribute('title')).slice(0, 200));
          var w = n.getAttribute('width'), h = n.getAttribute('height');
          if (w && /^\d{1,4}$/.test(w)) out.setAttribute('width', w);
          if (h && /^\d{1,4}$/.test(h)) out.setAttribute('height', h);
        } else {
          out = document.createElement('span'); out.className = 'imgx';
          out.textContent = '▣ ' + (m && m[2] === 'remote' ? t('imgRemote') : m && m[1] && ctx && ctx.embedded === false ? t('imgNotEmbedded') : t('imgMissing'));
        }
        dst.appendChild(out); continue;
      }
      var name = RENAME[tag] || tag;
      if (!KEEP[name]) { sanitizeInto(n, dst, st, depth + 1, ctx); continue; }   // unknown benign tag: unwrap, keep the text
      out = document.createElement(name);
      var dir = n.getAttribute('dir');
      if (dir && /^(ltr|rtl|auto)$/i.test(dir)) out.setAttribute('dir', dir.toLowerCase());
      if (name === 'td' || name === 'th') {
        var cs = n.getAttribute('colspan'), rs = n.getAttribute('rowspan');
        if (cs && /^\d{1,2}$/.test(cs) && +cs > 0) out.setAttribute('colspan', cs);
        if (rs && /^\d{1,2}$/.test(rs) && +rs > 0) out.setAttribute('rowspan', rs);
      }
      if (name !== 'br' && name !== 'hr') sanitizeInto(n, out, st, depth + 1, ctx);
      dst.appendChild(out);
    }
  }
  // style attributes and event handlers are never used; renaming them before parsing avoids a (harmless, the CSP blocks them anyway) violation report for each one
  function neutralize(html) { return html.replace(/<[a-zA-Z][^>]*>/g, function (tag) { return tag.replace(/([\s\/"'])(style|on[a-z]+)(\s*=)/gi, '$1x-$2$3'); }); }
  function sanitize(html, ctx) {
    var frag = document.createDocumentFragment();
    var doc;
    try { doc = new DOMParser().parseFromString(neutralize(String(html == null ? '' : html)), 'text/html'); } catch (e) { frag.appendChild(document.createTextNode('')); return frag; }
    var st = { nodes: 0, truncated: false };
    if (doc.body) sanitizeInto(doc.body, frag, st, 0, ctx || {});
    if (st.truncated) frag.appendChild(document.createTextNode(' …'));
    return frag;
  }
  function sanitizeToString(html, ctx) {   // test helper: reading innerHTML of a CLEAN detached tree is safe
    var d = document.createElement('div'); d.appendChild(sanitize(html, ctx)); return d.innerHTML;
  }

  /* ================================================================ state */
  var M = null, U = [], C = [], CBY = {}, V = null, viewer = null;
  var S = { tab: 'chats', filter: '', limit: 300, theme: 'auto', teamOpen: {}, scopeAll: false, visible: [], query: '', hits: null, runId: 0 };
  var waiters = {}, loadedSearch = [], pop = null;
  var fmt = {};

  function safeStore(k, v) { try { if (v === undefined) return window.localStorage.getItem('tt.' + k); window.localStorage.setItem('tt.' + k, v); } catch (e) { } return null; }

  /* ---------------------------------------------------------------- formatting */
  function setupFormats() {
    var loc = 'en-US';
    fmt.time = new Intl.DateTimeFormat(loc, { hour: '2-digit', minute: '2-digit' });
    fmt.day = new Intl.DateTimeFormat(loc, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
    fmt.date = { format: function (d) { return isoDate(d.getTime ? d.getTime() : d); } };   // yyyy-MM-dd: unambiguous whatever the reader's locale
    fmt.wd = new Intl.DateTimeFormat(loc, { weekday: 'short' });
    fmt.full = new Intl.DateTimeFormat(loc, { dateStyle: 'full', timeStyle: 'medium' });
  }
  function pad2(n) { return n < 10 ? '0' + n : '' + n; }
  function dayKey(ms) { var d = new Date(ms); return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate(); }
  function fullTime(ms) { var d = new Date(ms); return isoDate(ms) + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds()) + '  (UTC ' + new Date(ms).toISOString().replace('T', ' ').replace(/\.\d+Z$/, '') + ')'; }
  function listDate(ms) {
    if (!ms) return '';
    var ref = M.refMs || Date.now(), k = dayKey(ms);
    if (k === dayKey(ref)) return fmt.time.format(new Date(ms));
    if (ref - ms < 6 * 86400000 && ms < ref) return fmt.wd.format(new Date(ms));
    return fmt.date.format(new Date(ms));
  }
  function fmtSize(b) {
    if (b == null) return '';
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0, v = b;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)).toString() + ' ' + u[i];
  }
  function fmtDur(sec) {
    sec = Math.round(sec || 0); var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60, p = [];
    if (h) p.push(h + ' h'); if (m) p.push(m + ' min'); if (s || !p.length) p.push(s + ' s');
    return p.join(' ');
  }
  function fold(s) {   // length-preserving: lower case + strip accents of Latin letters
    return String(s).replace(/[À-ɏḀ-ỿ]/g, function (c) { return c.normalize('NFD').charAt(0); }).toLowerCase();
  }
  function colorOf(key) {
    var h = 0, s = String(key); for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
    return 'hsl(' + (h % 360) + ',42%,40%)';
  }
  function initials(n) {
    var p = String(n || '?').replace(/[<>()@._\-\/\\]+/g, ' ').trim().split(/\s+/).filter(Boolean);
    if (!p.length) return '?';
    var a = Array.from(p[0])[0] || '?', b = p.length > 1 ? (Array.from(p[p.length - 1])[0] || '') : '';
    return (a + b).toUpperCase();
  }
  function avatar(color, text, cls) { var a = el('div', { class: 'av' + (cls ? ' ' + cls : ''), text: text, 'aria-hidden': 'true' }); a.style.background = color; return a; }

  /* ================================================================ boot */
  function boot() {
    try { M = JSON.parse($('tt-manifest').textContent); } catch (e) { document.body.textContent = 'Invalid manifest'; return; }
    var hash = parseHash();
    lang = 'en';
    document.documentElement.setAttribute('data-accent', M.accent === 'Teams' ? 'teams' : 'house');
    S.theme = hash.theme || safeStore('theme') || 'auto';
    if (!/^(auto|light|dark)$/.test(S.theme)) S.theme = 'auto';
    U = (M.users || []).map(function (u, i) { return { i: i, id: u.i, name: u.n || '?', upn: u.u || '', state: u.s || 'active', color: colorOf(u.i || u.n), ini: initials(u.n) }; });
    viewer = M.viewer != null ? M.viewer : null;
    C = M.conversations || [];
    C.forEach(function (c) {
      CBY[c.id] = c; c.fold = fold((c.title || '') + ' ' + (c.team || ''));
      c.color = colorOf(c.key); c.ini = initials(c.title);
      if (c.kind === 'oneOnOne') {
        var o = (c.members || []).filter(function (x) { return x !== viewer; })[0];
        if (o != null && U[o]) { c.color = U[o].color; c.ini = U[o].ini; }
      }
      c.chunks = c.chunks || [];
    });
    M.refMs = C.reduce(function (a, c) { return Math.max(a, c.last || 0); }, 0);
    setupFormats();
    applyTheme(); applyStatic(); renderList();
    wire();
    var cid = hash.c;
    if (hash.tab === 'teams') S.tab = 'teams';
    if (cid && CBY[cid]) { S.tab = CBY[cid].kind === 'channel' ? 'teams' : 'chats'; renderList(); openConv(CBY[cid], { item: hash.i != null ? +hash.i : null }); }
    else showEmpty();
    document.documentElement.setAttribute('data-ready', '1');
  }
  function parseHash() {
    var o = {}, h = String(location.hash || '').replace(/^#/, '');
    h.split('&').forEach(function (kv) { var p = kv.split('='); if (p[0]) o[p[0]] = decodeURIComponent(p.slice(1).join('=')); });
    return o;
  }
  function applyTheme() {
    var r = document.documentElement;
    if (S.theme === 'auto') r.removeAttribute('data-theme'); else r.setAttribute('data-theme', S.theme);
    var b = $('btnTheme'); clear(b); b.appendChild(icon(S.theme === 'dark' ? 'moon' : S.theme === 'light' ? 'sun' : 'auto'));
    b.title = t(S.theme === 'dark' ? 'themeDark' : S.theme === 'light' ? 'themeLight' : 'themeAuto'); b.setAttribute('aria-label', b.title);
  }
  function applyStatic() {
    document.documentElement.setAttribute('lang', lang);
    $('archiveTitle').textContent = M.title || 'Teams';
    var sub = [];
    if (M.generatedUtc) sub.push(t('generated', { d: fmt.date.format(new Date(M.generatedUtc)) }));
    if (M.scopeLabel) sub.push(t('scope', { s: M.scopeLabel }));
    $('archiveSub').textContent = sub.join(' · ');
    $('q').placeholder = t('searchPh');
    var sc = $('scope'), cur = S.scopeAll ? 'all' : 'conv'; clear(sc);
    sc.appendChild(el('option', { value: 'conv', text: t('scopeConv') })); sc.appendChild(el('option', { value: 'all', text: t('scopeAll') })); sc.value = cur;
    var tc = $('tabChats'), tt = $('tabTeams'); clear(tc); clear(tt);
    tc.appendChild(icon('chat')); tc.appendChild(el('span', { text: t('railChats') })); tt.appendChild(icon('teams')); tt.appendChild(el('span', { text: t('teams') }));
    tc.setAttribute('aria-label', t('chats')); tt.setAttribute('aria-label', t('teams'));
    var tf = $('tabFiles'); clear(tf); tf.appendChild(icon('files')); tf.appendChild(el('span', { text: t('tabFiles') })); tf.setAttribute('aria-label', t('tabFiles'));
    $('filter').placeholder = t('filter'); $('filter').setAttribute('aria-label', t('filter'));
    
    $('btnHelp').title = t('helpTitle'); $('toBottom').textContent = ''; $('toBottom').appendChild(icon('down')); $('toBottom').appendChild(document.createTextNode(t('toBottom')));
    $('helpClose').textContent = t('close');
    applyTheme();
  }

  /* ================================================================ conversation list */
  function kindLabel(c) { return c.kind === 'channel' ? t('k_channel_' + (c.membership || 'standard')) : t('k_' + c.kind); }
  function convRow(c, cls) {
    var av = c.kind === 'channel' ? null : avatar(c.color, c.ini);
    var row = el('div', { class: 'li' + (cls ? ' ' + cls : ''), role: 'option', tabindex: '-1', 'data-id': c.id, 'aria-selected': V && V.c === c ? 'true' : 'false' });
    if (av) row.appendChild(av);
    var l1 = el('div', { class: 'l1' }, [el('span', { class: 'name', text: (c.kind === 'channel' && c.membership !== 'standard' ? '\u{1F512} ' : c.kind === 'channel' ? '# ' : '') + (c.title || '?') }), el('span', { class: 'date', text: listDate(c.last) })]);
    var prev = (c.previewBy ? c.previewBy + ': ' : '') + (c.preview || '');
    row.appendChild(el('div', { class: 'lt' }, [l1, el('div', { class: 'l2', text: prev })]));
    return row;
  }
  function renderList() {
    var list = $('convList'); clear(list);
    var f = fold(S.filter.trim());
    $('listTitle').textContent = t(S.tab === 'teams' ? 'teams' : S.tab === 'files' ? 'tabFiles' : 'chats');
    [['tabChats', 'chats'], ['tabTeams', 'teams'], ['tabFiles', 'files']].forEach(function (p) { $(p[0]).setAttribute('aria-selected', String(p[1] === S.tab)); });
    S.visible = [];
    var shown = 0;
    if (S.tab === 'files') {
      var withFiles = C.filter(function (c) { return (c.files || []).length && (!f || c.fold.indexOf(f) >= 0); }).sort(function (a, b) { return (b.last || 0) - (a.last || 0); });
      withFiles.forEach(function (c) { S.visible.push(c); list.appendChild(convRow(c, c.kind === 'channel' ? 'ch' : '')); });
      if (!withFiles.length) list.appendChild(el('div', { class: 'empty', text: t('noConv') }));
    } else if (S.tab === 'chats') {
      var cs = C.filter(function (c) { return c.kind !== 'channel' && (!f || c.fold.indexOf(f) >= 0); }).sort(function (a, b) { return (b.last || 0) - (a.last || 0); });
      cs.forEach(function (c) { S.visible.push(c); if (shown < S.limit) { list.appendChild(convRow(c)); shown++; } });
      if (cs.length > shown) list.appendChild(el('button', { class: 'more', type: 'button', text: t('showMore') + ' (' + (cs.length - shown) + ')', on: { click: function () { S.limit += 300; renderList(); } } }));
      if (!cs.length) list.appendChild(el('div', { class: 'empty', text: t('noConv') }));
    } else {
      var teams = {}, order = [];
      C.forEach(function (c) {
        if (c.kind !== 'channel') return;
        if (f && c.fold.indexOf(f) < 0) return;
        var k = c.teamId || c.team || '?'; if (!teams[k]) { teams[k] = { name: c.team || '?', ch: [], last: 0 }; order.push(k); }
        teams[k].ch.push(c); teams[k].last = Math.max(teams[k].last, c.last || 0);
      });
      order.sort(function (a, b) { return teams[b].last - teams[a].last; });
      order.forEach(function (k) {
        var tm = teams[k], open = S.teamOpen[k] !== false;
        var head = el('div', { class: 'thead', role: 'button', tabindex: '-1', 'aria-expanded': String(open), 'data-team': k }, [el('span', { class: 'caret' }, [icon('caret')]), avatar(colorOf(k), initials(tm.name), 'sm sq'), el('span', { text: tm.name })]);
        head.firstChild.firstChild.style.width = '14px'; head.firstChild.firstChild.style.height = '14px';
        list.appendChild(head);
        if (open) tm.ch.sort(function (a, b) { var ga = /^(general|général)$/i.test(a.title) ? 0 : 1, gb = /^(general|général)$/i.test(b.title) ? 0 : 1; return ga - gb || String(a.title).localeCompare(b.title); })
          .forEach(function (c) { S.visible.push(c); list.appendChild(convRow(c, 'ch')); });
      });
      if (!order.length) list.appendChild(el('div', { class: 'empty', text: t('noConv') }));
    }
  }
  function markSelected() {
    var rows = $('convList').querySelectorAll('.li');
    for (var i = 0; i < rows.length; i++) rows[i].setAttribute('aria-selected', String(!!V && rows[i].getAttribute('data-id') === V.c.id));
  }

  /* ================================================================ data loading */
  window.TT = {
    chunk: function (key, data) { var w = waiters[key]; if (w) { delete waiters[key]; w(data); } },
    search: function (key, data) { var w = waiters[key]; if (w) { delete waiters[key]; w(data); } }
  };
  function loadScript(path) {
    return new Promise(function (resolve, reject) {
      waiters[path] = resolve;
      var s = document.createElement('script'); s.src = path; s.async = true;
      s.onerror = function () { delete waiters[path]; reject(new Error('load ' + path)); };
      s.onload = function () { if (s.parentNode) s.parentNode.removeChild(s); };
      document.head.appendChild(s);
    });
  }
  function gunzipText(b64) {
    var bin = atob(b64.trim()), u8 = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    var stream = new Blob([u8]).stream().pipeThrough(new DecompressionStream('gzip'));
    return new Response(stream).text();
  }
  function readEmbedded(id) {
    var n = $(id); if (!n) return Promise.reject(new Error('missing block ' + id));
    return gunzipText(n.textContent).then(function (txt) { return JSON.parse(txt); });
  }
  function fetchData(path) { return M.mode === 'single' ? readEmbedded(path) : loadScript(path); }

  var blobCache = {};
  function embeddedBlob(ref) {
    if (blobCache[ref]) return blobCache[ref];
    var n = $('i-' + ref); if (!n) return null;
    var b = atob(n.textContent.trim()), u8 = new Uint8Array(b.length);
    for (var i = 0; i < b.length; i++) u8[i] = b.charCodeAt(i);
    blobCache[ref] = URL.createObjectURL(new Blob([u8], { type: n.getAttribute('data-type') || 'application/octet-stream' }));
    return blobCache[ref];
  }
  function imageUrl(ref) {
    if (!/\.(png|jpe?g|gif|webp|bmp)$/.test(ref)) return null;
    if (M.mode === 'single') { var n = $('i-' + ref); return n && /^image\//.test(n.getAttribute('data-type') || '') ? embeddedBlob(ref) : null; }
    return 'content/' + ref;
  }

  /* ================================================================ virtual list (Fenwick tree of heights) */
  var EST = 76, MAXLOADED = 24;
  function fenBuild(h) {
    var n = h.length, tr = new Float64Array(n + 1);
    for (var i = 1; i <= n; i++) { tr[i] += h[i - 1]; var j = i + (i & -i); if (j <= n) tr[j] += tr[i]; }
    return tr;
  }
  function fenAdd(i, d) { var tr = V.fen, n = V.total; for (i++; i <= n; i += i & -i) tr[i] += d; }
  function fenPrefix(k) { var tr = V.fen, s = 0; for (; k > 0; k -= k & -k) s += tr[k]; return s; }
  function fenFind(y) {   // index of the item containing offset y
    var tr = V.fen, n = V.total, pos = 0, pw = 1; while (pw * 2 <= n) pw *= 2;
    for (; pw; pw >>= 1) if (pos + pw <= n && tr[pos + pw] <= y) { pos += pw; y -= tr[pos]; }
    return Math.min(pos, n - 1);
  }
  function setH(i, h) { var d = h - V.h[i]; if (d) { V.h[i] = h; fenAdd(i, d); } }
  function estH(it) {
    var m = it.m; if (m.k === 1) return 40; if (m.k === 2) return 60;
    var len = (m.b || '').replace(/<[^>]*>/g, '').length, h = 52 + Math.ceil(len / 70) * 20;
    if (m.b && m.b.indexOf('<img') >= 0) h += 180;
    if (m.at) h += 58 * m.at.length;
    if (m.rx) h += 26;
    if (V.c.kind === 'channel') h += 60 + (it.r && it.r.length ? 30 : 0);
    return h;
  }
  function chunkIndexOf(idx) {
    var a = V.chunks, lo = 0, hi = a.length - 1;
    while (lo < hi) { var mid = (lo + hi + 1) >> 1; if (a[mid].start <= idx) lo = mid; else hi = mid - 1; }
    return lo;
  }
  function buildItems(c, arr) {
    if (c.kind !== 'channel') return arr.map(function (m) { return { m: m, r: null }; });
    var out = [], cur = null;
    for (var i = 0; i < arr.length; i++) {
      var m = arr[i];
      if (m.r && cur && cur.m.i === m.r) cur.r.push(m); else { cur = { m: m, r: [] }; out.push(cur); }
    }
    return out;
  }
  function loadChunk(v, ch) {
    if (ch.items) return Promise.resolve();
    if (ch.p) return ch.p;
    ch.p = fetchData(ch.m.f).then(function (arr) {
      var items = buildItems(v.c, arr);
      while (items.length < ch.n) items.push({ m: { k: 2, t: ch.m.a, i: 'err' + items.length }, r: null });
      ch.items = items.slice(0, ch.n);
    }, function () {
      var items = []; for (var i = 0; i < ch.n; i++) items.push({ m: { k: 2, t: ch.m.a, i: 'err' + i }, r: null });
      ch.items = items;
    }).then(function () { ch.p = null; if (v === V) onChunkLoaded(v, ch); });
    return ch.p;
  }
  function onChunkLoaded(v, ch) {
    for (var i = 0; i < ch.n; i++) {
      var idx = ch.start + i;
      if (!v.meas[idx]) setH(idx, estH(ch.items[i]));
      dropNode(idx);
    }
    var loaded = v.chunks.filter(function (c) { return c.items; });
    if (loaded.length > MAXLOADED) {   // evict the chunks farthest from the visible area
      var mid = chunkIndexOf(Math.max(0, Math.min(v.total - 1, fenFind(v.box.scrollTop + v.box.clientHeight / 2))));
      loaded.sort(function (a, b) { return Math.abs(v.chunks.indexOf(b) - mid) - Math.abs(v.chunks.indexOf(a) - mid); });
      for (var k = 0; k < loaded.length - MAXLOADED; k++) { var e = loaded[k]; for (var j = 0; j < e.n; j++) dropNode(e.start + j); e.items = null; }
    }
    scheduleLayout();
  }
  function dropNode(idx) { var n = V.nodes.get(idx); if (n) { if (n.parentNode) n.parentNode.removeChild(n); V.nodes.delete(idx); } }

  /* ---------------------------------------------------------------- open a conversation */
  function openConv(c, opt) {
    opt = opt || {};
    closePop();
    var box = $('msgs');
    var chunks = [], start = 0;
    c.chunks.forEach(function (m) { chunks.push({ m: m, start: start, n: m.n, items: null, p: null }); start += m.n; });
    V = { tab: 'chat', c: c, chunks: chunks, total: start, h: null, fen: null, meas: null, nodes: new Map(), stick: opt.item == null && opt.ts == null, open: {}, hl: opt.hl || null, iter: 0, box: box, expect: -1, busy: false, go: false };
    V.h = new Float64Array(start); V.h.fill(EST); V.meas = new Uint8Array(start); V.fen = fenBuild(V.h);
    S.cur = c;
    $('empty').hidden = true; $('conv').hidden = false; $('app').classList.add('inconv');
    clear($('rows'));
    box.scrollTop = 0;
    renderHeader(); renderFooter(); markSelected();
    $('msgs').hidden = false; $('filesview').hidden = true;
    try { history.replaceState(null, '', '#c=' + encodeURIComponent(c.id)); } catch (e) { }
    $('toBottom').hidden = true;
    if (!start) { $('rows').appendChild(el('div', { class: 'empty', text: t('empty') })); return; }
    if (opt.item != null) goTo(Math.max(0, Math.min(start - 1, opt.item)));
    else if (opt.ts != null) jumpToTs(opt.ts);
    else scheduleLayout();
    box.focus({ preventScroll: true });
  }
  function showEmpty() {
    V = null; S.cur = null;
    $('conv').hidden = true; $('app').classList.remove('inconv');
    var e = $('empty'); e.hidden = false; clear(e);
    if (S.tab === 'files') { renderAllFiles(e); return; }
    var st = M.stats || {};
    e.appendChild(el('h1', { text: t('pickConv') }));
    e.appendChild(el('p', { text: t('pickHint') }));
    e.appendChild(el('div', { class: 'stats' }, [
      el('div', null, [el('b', { text: String(C.length) }), t('statConv')]),
      el('div', null, [el('b', { text: String(st.messages != null ? st.messages : 0) }), t('statMsg')]),
      el('div', null, [el('b', { text: String(st.files != null ? st.files : 0) }), t('statFiles')])]));
  }
  function renderHeader() {
    var c = V.c, h = $('chead'); clear(h);
    h.appendChild(el('button', { class: 'ibtn backbtn', type: 'button', title: t('chats'), on: { click: function () { $('app').classList.remove('inconv'); } } }, [icon('back')]));
    h.appendChild(avatar(c.color, c.kind === 'channel' ? '#' : c.ini, 'lg' + (c.kind === 'channel' ? ' sq' : '')));
    var mc = c.memberCount != null ? c.memberCount : (c.members || []).length;
    var sub = [];
    if (c.kind === 'channel' && c.team) sub.push(c.team);
    var mbtn = el('button', { type: 'button', text: mc === 1 ? t('member1') : t('members', { n: mc }), on: { click: function (ev) { ev.stopPropagation(); toggleMembers(); } } });
    var cnt = c.count || 0;
    var subline = el('div', { class: 'sub' }, [(sub.length ? sub.join(' · ') + ' · ' : ''), mbtn, ' · ' + (cnt === 1 ? t('message1') : t('messages', { n: cnt.toLocaleString('en-US') })) +
      (c.first ? ' · ' + t('period', { a: fmt.date.format(new Date(c.first)), b: fmt.date.format(new Date(c.last)) }) : '')]);
    h.appendChild(el('div', { class: 'ht' }, [el('h1', null, [el('span', { class: 'tt', text: c.title || '?' }), el('span', { class: 'badge' + (c.kind === 'oneOnOne' || c.kind === 'group' ? '' : ' neutral'), text: kindLabel(c) })]), subline]));
    var tabs = el('div', { class: 'tabs', role: 'tablist' });
    ['chat', 'files'].forEach(function (id) {
      tabs.appendChild(el('button', { class: 'tab', type: 'button', role: 'tab', 'data-view': id, 'aria-selected': String((V.tab || 'chat') === id), text: t(id === 'chat' ? 'tabChat' : 'tabFiles'), on: { click: function () { setTab(id); } } }));
    });
    h.appendChild(tabs);
    h.appendChild(el('div', { class: 'grow' }));
    // Text field, not a native date input: the native one follows the browser/OS locale (dd/mm/yyyy, jj/mm/aaaa...); this page is English whatever the locale.
    var di = el('input', { type: 'text', id: 'jumpDate', title: t('jumpDate') + ' (' + t('jumpDateHint') + ')', 'aria-label': t('jumpDate'), placeholder: t('jumpDateHint'), maxlength: '10', autocomplete: 'off', inputmode: 'numeric', spellcheck: 'false' });
    function tryJump() {
      var s = di.value.trim();
      if (!s) { di.classList.remove('bad'); di.title = t('jumpDate') + ' (' + t('jumpDateHint') + ')'; return; }
      var ts = parseIsoDate(s);
      if (ts == null) { di.classList.add('bad'); di.title = t('jumpDateBad'); return; }
      di.classList.remove('bad'); di.title = t('jumpDate') + ' (' + t('jumpDateHint') + ')';
      jumpToTs(ts);
    }
    di.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') { ev.preventDefault(); tryJump(); } else if (ev.key === 'Escape') { di.blur(); } });
    di.addEventListener('input', function () { if (di.classList.contains('bad') && parseIsoDate(di.value.trim()) != null) { di.classList.remove('bad'); di.title = t('jumpDate') + ' (' + t('jumpDateHint') + ')'; } });
    h.appendChild(di);
  }
  function renderAllFiles(e) {
    var all = [];
    C.forEach(function (c) { (c.files || []).forEach(function (f) { all.push({ c: c, f: f }); }); });
    all.sort(function (a, b) { return b.f.t - a.f.t; });
    e.appendChild(el('h1', { text: t('tabFiles') }));
    if (!all.length) e.appendChild(el('p', { text: t('filesEmpty') }));
    var box = el('div', { class: 'allfiles' });
    all.slice(0, 500).forEach(function (x) {
      var f = x.f, ok = f.st === 'ok' && f.ref, who = f.a >= 0 && U[f.a] ? U[f.a].name : '';
      var parts = [x.c.title, who ? t('filesBy', { n: who }) : '', fmt.date.format(new Date(f.t)), f.sz != null ? fmtSize(f.sz) : '', ok ? t('exported') : statusText(f.st)].filter(Boolean);
      var row = el('div', { class: 'frow' + (ok ? '' : ' off') }, [fileTile(f.n), el('div', { class: 'fi' }, [el('div', { class: 'fn', text: f.n }), el('div', { class: 'fs', text: parts.join(' · ') })])]);
      if (ok) row.appendChild(openLink(f.n, f.ref));
      row.appendChild(el('button', { class: 'lnk', type: 'button', text: t('showInChat'), on: { click: function () { S.tab = x.c.kind === 'channel' ? 'teams' : 'chats'; renderList(); openConv(x.c, { item: f.it }); } } }));
      box.appendChild(row);
    });
    e.appendChild(box);
  }  function setTab(id) {
    if (!V) return;
    V.tab = id;
    var tabs = document.querySelectorAll('#chead .tab');
    for (var i = 0; i < tabs.length; i++) tabs[i].setAttribute('aria-selected', String(tabs[i].getAttribute('data-view') === id));
    $('msgs').hidden = id === 'files'; $('filesview').hidden = id !== 'files';
    if (id === 'files') { renderFiles(); $('toBottom').hidden = true; } else { scheduleLayout(); }
  }
  function fileExt(n) { var e = String(n || '').split('.').pop() || ''; return e === n ? '' : e.slice(0, 4); }
  function fileTile(n) { var e = fileExt(n); return el('div', { class: 'ficon' + (e ? ' ft-' + e.toLowerCase().replace(/[^a-z0-9]/g, '') : ''), text: e || 'FILE' }); }
  function statusText(st) { var k = 'fs_' + (st || 'unknown'); return I18N.en[k] ? t(k) : t('notExported'); }
  function openLink(name, ref) {
    var lnk = el('a', { class: 'open', href: M.mode === 'single' ? '#' : 'content/' + ref, download: name || 'file', text: t('open'), rel: 'noopener' });
    if (M.mode === 'single') lnk.addEventListener('click', function (ev) {
      ev.preventDefault(); var u = embeddedBlob(ref); if (!u) return;
      var tmp = document.createElement('a'); tmp.href = u; tmp.download = name || 'file'; document.body.appendChild(tmp); tmp.click(); document.body.removeChild(tmp);
    });
    return lnk;
  }
  function renderFiles() {
    var c = V.c, box = $('filesview'); clear(box);
    var fin = el('div', { class: 'fin' }); fin.appendChild(el('h2', { text: t('tabFiles') }));
    var fl = (c.files || []).slice().sort(function (a, b) { return b.t - a.t; });
    if (!fl.length) fin.appendChild(el('div', { class: 'fempty', text: t('filesEmpty') }));
    fl.forEach(function (f) {
      var ok = f.st === 'ok' && f.ref, who = f.a >= 0 && U[f.a] ? U[f.a].name : '';
      var parts = [who ? t('filesBy', { n: who }) : '', fmt.date.format(new Date(f.t)), f.sz != null ? fmtSize(f.sz) : '', ok ? t('exported') : statusText(f.st)].filter(Boolean);
      var row = el('div', { class: 'frow' + (ok ? '' : ' off') }, [fileTile(f.n), el('div', { class: 'fi' }, [el('div', { class: 'fn', text: f.n }), el('div', { class: 'fs', text: parts.join(' · ') })])]);
      if (ok) row.appendChild(openLink(f.n, f.ref));
      row.appendChild(el('button', { class: 'lnk', type: 'button', text: t('showInChat'), on: { click: function () { setTab('chat'); goTo(f.it); } } }));
      fin.appendChild(row);
    });
    box.appendChild(fin);
  }  // YYYY-MM-DD (a real calendar date) -> local midnight in ms, otherwise null.
  function parseIsoDate(s) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
    if (!m) return null;
    var y = +m[1], mo = +m[2], d = +m[3], dt = new Date(y, mo - 1, d);
    if (dt.getFullYear() !== y || dt.getMonth() !== mo - 1 || dt.getDate() !== d) return null;
    return dt.getTime();
  }
  function isoDate(ms) { var d = new Date(ms); return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()); }
  function renderFooter() {
    var f = $('cfoot'); clear(f);
    f.appendChild(el('span', { text: t('readOnly') }));
    f.appendChild(el('span', { text: M.generatedUtc ? t('generated', { d: fmt.date.format(new Date(M.generatedUtc)) }) : '' }));
  }
  function closePop() { if (pop && pop.parentNode) pop.parentNode.removeChild(pop); pop = null; }
  function toggleMembers() {
    if (pop) { closePop(); return; }
    var c = V.c; pop = el('div', { class: 'pop', role: 'dialog', 'aria-label': t('membersTitle') });
    (c.members || []).forEach(function (ix) {
      var u = U[ix]; if (!u) return;
      pop.appendChild(el('div', { class: 'm' }, [avatar(u.color, u.ini, 'sm'), el('span', { text: u.name }), stateTag(u.state)]));
    });
    if (!pop.firstChild) pop.appendChild(el('div', { class: 'm', text: '—' }));
    $('mainpane').appendChild(pop);
  }
  function stateTag(s) {
    var k = s === 'deleted' ? 's_deleted' : s === 'external' ? 's_external' : s === 'guest' ? 's_guest' : s === 'bot' ? 'bot' : null;
    return k ? el('span', { class: 'tag', text: t(k) }) : null;
  }

  /* ---------------------------------------------------------------- layout */
  var raf = 0;
  function scheduleLayout() { if (!raf) raf = requestAnimationFrame(function () { raf = 0; layout(); }); }
  function setScroll(y) { var b = V.box; b.scrollTop = Math.max(0, y); V.expect = b.scrollTop; }

  function layout() {
    var v = V; if (!v || !v.total || v.busy || $('msgs').hidden) return;
    v.busy = true;
    try { layoutInner(v); } finally { v.busy = false; }
  }
  function layoutInner(v) {
    var box = v.box, vh = box.clientHeight, rows = $('rows');
    var buf = Math.max(500, vh), st = box.scrollTop, total = v.total;
    if (v.stick) { st = Math.max(0, fenPrefix(total) - vh); }
    var first = fenFind(Math.max(0, st - buf)), last = first, y = fenPrefix(first);
    while (last < total && y < st + vh + buf) { y += v.h[last]; last++; }
    // anchor: first rendered node overlapping the viewport
    var boxTop = box.getBoundingClientRect().top, anchor = null, anchorTop = 0;
    v.nodes.forEach(function (n, idx) {
      if (!n.isConnected) return;
      var r = n.getBoundingClientRect();
      if (r.bottom > boxTop + 1 && (anchor === null || idx < anchor.idx)) { anchor = { idx: idx, node: n }; anchorTop = r.top - boxTop; }
    });
    // drop nodes outside the window
    v.nodes.forEach(function (n, idx) { if (idx < first || idx >= last) { if (n.parentNode) n.parentNode.removeChild(n); v.nodes.delete(idx); } });
    // chunks to load
    var c0 = chunkIndexOf(first), c1 = chunkIndexOf(last - 1);
    for (var ci = c0; ci <= c1; ci++) if (!v.chunks[ci].items && !v.chunks[ci].p) loadChunk(v, v.chunks[ci]);
    // (re)build the nodes of the window, in order
    var cursor = rows.firstChild;
    for (var i = first; i < last; i++) {
      var node = v.nodes.get(i);
      if (!node) { node = renderItem(v, i); v.nodes.set(i, node); }
      if (node.classList.contains('skel')) node.style.height = v.h[i] + 'px';
      if (node === cursor) cursor = cursor.nextSibling; else rows.insertBefore(node, cursor);
    }
    // measure
    var changed = false;
    v.nodes.forEach(function (n, idx) {
      if (n.classList.contains('skel')) return;
      var h = n.offsetHeight;
      if (Math.abs(h - v.h[idx]) > 0.5) { setH(idx, h); changed = true; }
      v.meas[idx] = 1;
    });
    $('padTop').style.height = fenPrefix(first) + 'px';
    $('padBot').style.height = Math.max(0, fenPrefix(total) - fenPrefix(last)) + 'px';
    if (v.stick) {
      var target = box.scrollHeight - box.clientHeight;
      if (Math.abs(target - box.scrollTop) > 1) { setScroll(target); if (v.iter++ < 20) scheduleLayout(); }
    } else if (anchor && anchor.node.isConnected && !v.go) {
      var d = anchor.node.getBoundingClientRect().top - boxTop - anchorTop;
      if (Math.abs(d) > 0.5) { setScroll(box.scrollTop + d); }
    }
    if (changed && v.iter++ < 20) scheduleLayout();
    $('toBottom').hidden = v.stick || total === 0;
  }

  function onScroll() {
    if (!V) return;
    var b = V.box;
    if (Math.abs(b.scrollTop - V.expect) > 1.5) {   // user scroll
      V.stick = (b.scrollHeight - b.scrollTop - b.clientHeight) < 6; V.iter = 0;
    }
    scheduleLayout();
  }

  async function goTo(idx, noFlash) {
    var v = V; if (!v) return;
    v.stick = false; v.go = true;
    try {
      var ch = v.chunks[chunkIndexOf(idx)];
      setScroll(fenPrefix(idx) - 8); layout();
      await loadChunk(v, ch); if (v !== V) return;
      for (var k = 0; k < 8; k++) {
        layout();
        var n = v.nodes.get(idx);
        if (!n) { setScroll(fenPrefix(idx) - 8); continue; }
        var d = n.getBoundingClientRect().top - v.box.getBoundingClientRect().top - 8;
        if (Math.abs(d) < 2) break;
        setScroll(v.box.scrollTop + d);
      }
      var node = v.nodes.get(idx);
      if (node && !noFlash) { node.classList.remove('flash'); void node.offsetWidth; node.classList.add('flash'); }
    } finally { v.go = false; }
    scheduleLayout();
  }
  async function jumpToTs(ts) {
    var v = V; if (!v || !v.total) return;
    var ci = v.chunks.findIndex(function (c) { return c.m.b >= ts; });
    if (ci < 0) ci = v.chunks.length - 1;
    var ch = v.chunks[ci];
    await loadChunk(v, ch); if (v !== V) return;
    var lo = 0, hi = ch.items.length - 1;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (ch.items[mid].m.t >= ts) hi = mid; else lo = mid + 1; }
    goTo(ch.start + lo);
  }
  function toBottom() { if (!V) return; V.stick = true; V.iter = 0; scheduleLayout(); }

  /* ================================================================ message rendering */
  function authorOf(m) {
    if (m.a != null && m.a >= 0 && U[m.a]) return U[m.a];
    var n = m.an || t('unknownAuthor');
    return { i: -1, name: n, color: colorOf(n), ini: initials(n), state: m.ab ? 'bot' : 'unknown' };
  }
  function timeEl(ms) { var d = new Date(ms); return el('time', { datetime: d.toISOString(), title: fullTime(ms), text: fmt.time.format(d) }); }
  function renderItem(v, idx) {
    var ci = chunkIndexOf(idx), ch = v.chunks[ci];
    if (!ch.items) { var s = el('div', { class: 'skel', 'data-i': idx }); return s; }
    var i = idx - ch.start, it = ch.items[i], m = it.m;
    var prev = i > 0 ? ch.items[i - 1] : (ci > 0 && v.chunks[ci - 1].items ? v.chunks[ci - 1].items[v.chunks[ci - 1].items.length - 1] : null);
    var prevT = prev ? prev.m.t : (ci > 0 ? v.chunks[ci - 1].m.b : null);
    var node = el('div', { class: 'item', 'data-i': idx });
    if (prevT == null || dayKey(prevT) !== dayKey(m.t)) node.appendChild(el('div', { class: 'daysep' }, [el('span', { text: fmt.day.format(new Date(m.t)) })]));
    if (m.k === 1) node.appendChild(sysLine(m));
    else if (m.k === 2) node.appendChild(el('div', { class: 'sys', text: t('unavailable') + ' (' + t('loadError') + ')' }));
    else if (v.c.kind === 'channel') node.appendChild(postNode(v, idx, it));
    else {
      var grouped = !!(prev && prev.m.k !== 1 && prev.m.k !== 2 && prev.m.a === m.a && (m.a >= 0 || prev.m.an === m.an) && m.t - prev.m.t < 300000 && dayKey(prev.m.t) === dayKey(m.t) && prevT != null);
      node.appendChild(bubbleRow(m, grouped));
    }
    return node;
  }
  function sysLine(m) {
    var sy = m.sy || {}, who = (sy.who || []).join(', '), a = { by: sy.by || '', who: who, nm: sy.nm || '', t: sy.ty || '?', dur: sy.du != null ? fmtDur(sy.du) : '' };
    var key = 'ev_' + (sy.ty || ''), txt;
    var has0 = (sy.ty === 'membersAdded' || sy.ty === 'membersDeleted' || sy.ty === 'chatRenamed') && !sy.by;
    if (sy.ty === 'callEnded' && sy.du == null) key = 'ev_callEnded0';
    else if (has0) key += '0';
    if (!I18N.en[key]) { key = 'ev_default'; }
    txt = t(key, a);
    return el('div', { class: 'sys' }, [txt, timeEl(m.t)]);
  }
  function mineOf(m) { return viewer != null && m.a === viewer; }
  function bubbleRow(m, grouped) {
    var mine = mineOf(m), au = authorOf(m);
    var row = el('div', { class: 'row ' + (mine ? 'mine' : 'theirs') });
    if (!mine) row.appendChild(grouped ? el('div', { class: 'spacer' }) : avatar(au.color, au.ini, 'sm'));
    var col = el('div', { class: 'col' });
    var b = bubbleBody(m);
    if (!grouped) {
      var meta = el('div', { class: 'meta' });
      if (!mine) { meta.appendChild(el('span', { class: 'au', text: au.name })); var tg = stateTag(au.state); if (tg) meta.appendChild(tg); }
      meta.appendChild(timeEl(m.t));
      if (!mine && !m.d) b.insertBefore(meta, b.firstChild); else col.appendChild(meta);   // Teams: the name and time sit inside the card; mine = time only
    }
    col.appendChild(b);
    var rx = reactionsNode(m); if (rx) col.appendChild(rx);
    row.appendChild(col);
    return row;
  }  function bubbleBody(m) {
    var b = el('div', { class: 'bubble' + (m.d ? ' deleted' : '') + (m.im === 'urgent' ? ' imp-urgent' : m.im === 'high' ? ' imp-high' : '') });
    if (m.d) { b.textContent = t('deleted'); b.title = t('deletedAt', { d: fullTime(m.d) }); return b; }
    if (m.im) b.appendChild(el('div', { class: 'impl' + (m.im === 'urgent' ? ' urgent' : ''), text: t(m.im === 'urgent' ? 'urgent' : 'important') }));
    fillContent(b, m);
    return b;
  }
  function fillContent(b, m) {
    var quotes = (m.at || []).filter(function (a) { return a.c === 'quote'; });
    quotes.forEach(function (q) { b.appendChild(el('div', { class: 'quote' }, [el('b', { text: q.sn || t('quote') }), el('span', { text: q.pv || '' })])); });
    var body = bodyNode(m); if (body.firstChild) b.appendChild(body);
    var rest = (m.at || []).filter(function (a) { return a.c !== 'quote'; });
    if (rest.length) { var box = el('div', { class: 'atts' }); rest.forEach(function (a) { box.appendChild(attNode(a)); }); b.appendChild(box); }
    if (m.e) b.appendChild(el('span', { class: 'edited', text: t('edited'), title: t('editedAt', { d: fullTime(m.e) }) }));
  }
  function bodyNode(m) {
    var d = el('div', { class: 'body' + (m.f === 't' ? ' txt' : '') });
    if (m.f === 't') { d.textContent = m.b || ''; }
    else {
      var at = {}; (m.mn || []).forEach(function (x) { at[x[0]] = x[2]; });
      d.appendChild(sanitize(m.b || '', { img: imageUrl, at: at, viewer: viewer, embedded: M.mode !== 'single' }));
    }
    if (V && V.hl) markTerms(d, V.hl);
    return d;
  }
  var RXE = { like: '👍', heart: '❤️', laugh: '😂', surprised: '😮', sad: '😢', angry: '😠' };
  function reactionsNode(m) {
    if (!m.rx || !m.rx.length || m.d) return null;
    var box = el('div', { class: 'rx' });
    m.rx.forEach(function (r) {
      var names = r[1].map(function (w) { return typeof w === 'number' ? (U[w] ? U[w].name : '?') : String(w); });
      var mine = viewer != null && r[1].indexOf(viewer) >= 0;
      box.appendChild(el('span', { class: mine ? 'mine' : null, title: names.join(', ') }, [RXE[r[0]] || String(r[0]).slice(0, 8), el('span', { text: String(r[1].length) })]));
    });
    return box;
  }
  function attNode(a) {
    if (a.c === 'file') return fileNode(a);
    if (a.c === 'card') {
      var c = el('div', { class: 'card' }, [el('div', { class: 'ck', text: t('card') })]);
      if (a.ti) c.appendChild(el('div', { class: 'ct', text: a.ti }));
      (a.tx || []).forEach(function (l) { c.appendChild(el('div', { class: 'cl', text: l })); });
      return c;
    }
    return el('div', { class: 'file off' }, [el('div', { class: 'ficon', text: 'ATT' }), el('div', { class: 'fi' }, [el('div', { class: 'fn', text: a.n || t('attachment') }), el('div', { class: 'fs', text: a.ty || '' })])]);
  }
  function fileNode(a) {
    var ok = a.st === 'ok' && a.ref;
    var node = el('div', { class: 'file' + (ok ? '' : ' off') });
    node.appendChild(fileTile(a.n));
    node.appendChild(el('div', { class: 'fi' }, [el('div', { class: 'fn', text: a.n || t('attachment') }), el('div', { class: 'fs', text: (a.sz != null ? fmtSize(a.sz) + ' · ' : '') + (ok ? t('exported') : statusText(a.st)) })]));
    if (ok) node.appendChild(openLink(a.n, a.ref));
    return node;
  }  function postNode(v, idx, it) {
    var m = it.m, au = authorOf(m);
    var post = el('div', { class: 'post' });
    post.appendChild(el('div', { class: 'ph' }, [avatar(au.color, au.ini), el('div', null, [el('span', { class: 'au', text: au.name }), ' ', stateTag(au.state), el('div', { class: 'ts' }, [timeEl(m.t)])])]));
    if (m.s) post.appendChild(el('h3', { text: m.s }));
    if (m.d) post.appendChild(el('div', { class: 'bubble deleted', text: t('deleted'), title: t('deletedAt', { d: fullTime(m.d) }) }));
    else {
      if (m.im) post.appendChild(el('div', { class: 'impl' + (m.im === 'urgent' ? ' urgent' : ''), text: t(m.im === 'urgent' ? 'urgent' : 'important') }));
      var holder = el('div'); fillContent(holder, m); while (holder.firstChild) post.appendChild(holder.firstChild);
    }
    var rx = reactionsNode(m); if (rx) post.appendChild(rx);
    if (it.r && it.r.length) {
      var open = !!v.open[idx], n = it.r.length;
      var thread = el('div', { class: 'thread' });
      var btn = el('button', { class: 'tbtn', type: 'button', 'aria-expanded': String(open) }, [icon('caret'),
        el('span', { text: open ? t('hideReplies') : (n === 1 ? t('reply1') : t('replies', { n: n })) }),
        open ? null : el('small', { text: ' · ' + t('lastReply', { d: fmt.date.format(new Date(it.r[n - 1].t)) }) })]);
      btn.firstChild.style.width = '14px'; btn.firstChild.style.height = '14px';      btn.addEventListener('click', function () { v.open[idx] = !v.open[idx]; dropNode(idx); scheduleLayout(); });
      thread.appendChild(btn);
      if (open) it.r.forEach(function (r) {
        var ra = authorOf(r);
        var rb = el('div', { class: 'rb' }, [el('div', { class: 'ph' }, [el('span', { class: 'au', text: ra.name }), ' ', stateTag(ra.state), ' ', timeEl(r.t)])]);
        if (r.d) rb.appendChild(el('div', { class: 'bubble deleted', text: t('deleted') }));
        else { var h2 = el('div'); fillContent(h2, r); while (h2.firstChild) rb.appendChild(h2.firstChild); }
        var rrx = reactionsNode(r); if (rrx) rb.appendChild(rrx);
        thread.appendChild(el('div', { class: 'reply' }, [avatar(ra.color, ra.ini, 'sm'), rb]));
      });
      post.appendChild(thread);
    }
    return post;
  }

  function markTerms(root, terms) {
    var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), nodes = [];
    while (w.nextNode()) nodes.push(w.currentNode);
    nodes.forEach(function (tn) {
      var s = tn.nodeValue, f = fold(s), rg = [];
      terms.forEach(function (q) { if (!q) return; var p = 0; while ((p = f.indexOf(q, p)) >= 0) { rg.push([p, p + q.length]); p += q.length; } });
      if (!rg.length) return;
      rg.sort(function (a, b) { return a[0] - b[0]; });
      var frag = document.createDocumentFragment(), pos = 0;
      rg.forEach(function (r) { if (r[0] < pos) { if (r[1] > pos) { frag.lastChild.textContent += s.slice(pos, r[1]); pos = r[1]; } return; } if (r[0] > pos) frag.appendChild(document.createTextNode(s.slice(pos, r[0]))); frag.appendChild(el('mark', { text: s.slice(r[0], r[1]) })); pos = r[1]; });
      if (pos < s.length) frag.appendChild(document.createTextNode(s.slice(pos)));
      tn.parentNode.replaceChild(frag, tn);
    });
  }

  /* ================================================================ search */
  function loadSearch(c) {
    for (var i = 0; i < loadedSearch.length; i++) if (loadedSearch[i].c === c) return Promise.resolve(loadedSearch[i]);
    if (!c.search) return Promise.resolve({ c: c, x: [], f: [], ms: [], au: [], it: [] });
    return fetchData(c.search).then(function (d) {
      var e = { c: c, x: d.x || [], ms: d.ms || [], au: d.au || [], it: d.it || null, f: null };
      loadedSearch.push(e); if (loadedSearch.length > 6) loadedSearch.shift();
      return e;
    }, function () { return { c: c, x: [], f: [], ms: [], au: [], it: [] }; });
  }
  function scan(e, terms, out, max) {
    if (!e.f) e.f = e.x.map(fold);
    for (var i = 0; i < e.f.length && out.length < max; i++) {
      var f = e.f[i], ok = true, p0 = -1;
      for (var k = 0; k < terms.length; k++) { var p = f.indexOf(terms[k]); if (p < 0) { ok = false; break; } if (k === 0) p0 = p; }
      if (ok) out.push({ c: e.c, line: i, pos: p0, item: e.it ? e.it[i] : i, ms: e.ms[i], au: e.au[i], text: e.x[i] });
    }
  }
  var MAXHITS = 500;
  async function runSearch(q) {
    q = q.trim(); S.query = q;
    var run = ++S.runId;
    if (!q) { closeSide(); if (V) { V.hl = null; refreshAll(); } return; }
    var terms = fold(q).split(/\s+/).filter(Boolean);
    openSide(t('searchTitle', { q: q }));
    var out = [], list = S.scopeAll ? C.slice() : (V ? [V.c] : []);
    if (S.scopeAll) list.sort(function (a, b) { return (b.last || 0) - (a.last || 0); });
    var tot = list.length;
    for (var i = 0; i < list.length; i++) {
      if (run !== S.runId) return;
      $('sideProg').textContent = tot > 1 ? t('searching', { a: i, b: tot }) : t('loading');
      var e = await loadSearch(list[i]); if (run !== S.runId) return;
      scan(e, terms, out, MAXHITS + 1);
      renderHits(out, terms, q);
      if (out.length > MAXHITS) break;
      if (i % 3 === 2) await new Promise(function (r) { setTimeout(r, 0); });
    }
    if (run !== S.runId) return;
    $('sideProg').textContent = (out.length > MAXHITS ? t('moreResults', { n: MAXHITS }) : out.length === 0 ? t('noResults') : out.length === 1 ? t('result1') : t('results', { n: out.length })) + (tot > 1 ? ' · ' + t('searchDone', { b: tot }) : '');
    if (V && !S.scopeAll) { V.hl = terms; refreshAll(); }
    $('live').textContent = $('sideProg').textContent;
  }
  function refreshAll() { if (!V) return; V.nodes.forEach(function (n, idx) { dropNode(idx); }); scheduleLayout(); }
  function renderHits(out, terms, q) {
    var box = $('hits'); clear(box);
    out.slice(0, MAXHITS).forEach(function (h) {
      var s = h.text, p = Math.max(0, h.pos - 40), snip = (p > 0 ? '…' : '') + s.slice(p, p + 160) + (p + 160 < s.length ? '…' : '');
      var au = h.au != null && h.au >= 0 && U[h.au] ? U[h.au].name : '';
      var row = el('div', { class: 'hit', tabindex: '0', role: 'button' }, [
        el('div', { class: 'hh' }, [el('b', { text: (S.scopeAll ? h.c.title + (h.c.kind === 'channel' && h.c.team ? ' (' + h.c.team + ')' : '') : au) || '…' }), el('span', { text: fmt.date.format(new Date(h.ms)) })]),
        (function () { var d = el('div', { class: 'hs' }); d.appendChild(document.createTextNode(snip)); markTerms(d, terms); return d; })()]);
      var go = function () { if (V && V.c === h.c) { V.hl = terms; refreshAll(); goTo(h.item); } else { openConv(h.c, { item: h.item, hl: terms }); } if (window.innerWidth < 1100) closeSide(true); };
      row.addEventListener('click', go);
      row.addEventListener('keydown', function (ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); go(); } });
      box.appendChild(row);
    });
  }
  function openSide(title) { $('side').hidden = false; $('sideTitle').textContent = title; clear($('hits')); }
  function closeSide(keep) { $('side').hidden = true; if (!keep) S.runId++; }

  /* ================================================================ wiring */
  function wire() {
    $('msgs').addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', function () { if (V) { V.nodes.forEach(function (n, i) { V.meas[i] = 0; dropNode(i); }); scheduleLayout(); } });
    $('toBottom').addEventListener('click', toBottom);
    $('rows').addEventListener('click', function (ev) { var im = ev.target.closest && ev.target.closest('img.inl'); if (im) { $('lightboxImg').src = im.src; $('lightbox').hidden = false; } });
    $('lightbox').addEventListener('click', function () { $('lightbox').hidden = true; $('lightboxImg').removeAttribute('src'); });
    $('rail').addEventListener('click', function (ev) { var b = ev.target.closest('[data-tab]'); if (b) { S.tab = b.getAttribute('data-tab'); S.limit = 300; renderList(); if (S.tab === 'files' || !V) showEmpty(); } });
    $('filter').addEventListener('input', function (ev) { S.filter = ev.target.value; S.limit = 300; renderList(); });
    var list = $('convList');
    list.addEventListener('click', function (ev) {
      var th = ev.target.closest('.thead'); if (th) { var k = th.getAttribute('data-team'); S.teamOpen[k] = S.teamOpen[k] === false; renderList(); return; }
      var row = ev.target.closest('.li'); if (row) openConv(CBY[row.getAttribute('data-id')]);
    });
    list.addEventListener('keydown', function (ev) {
      var items = Array.prototype.slice.call(list.querySelectorAll('.li,.thead')), cur = items.indexOf(document.activeElement);
      if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
        ev.preventDefault();
        if (cur < 0) { var sel = list.querySelector('.li[aria-selected="true"]') || items[0]; if (sel) sel.focus(); return; }
        var nx = items[cur + (ev.key === 'ArrowDown' ? 1 : -1)]; if (nx) nx.focus();
      } else if (ev.key === 'Home' && cur >= 0) { ev.preventDefault(); items[0].focus(); }
      else if (ev.key === 'End' && cur >= 0) { ev.preventDefault(); items[items.length - 1].focus(); }
      else if ((ev.key === 'Enter' || ev.key === ' ') && cur >= 0) { ev.preventDefault(); items[cur].click(); }
    });
    $('searchForm').addEventListener('submit', function (ev) { ev.preventDefault(); runSearch($('q').value); });
    $('q').addEventListener('input', function () { if (!$('q').value) runSearch(''); });
    $('scope').addEventListener('change', function () { S.scopeAll = $('scope').value === 'all'; if ($('q').value.trim()) runSearch($('q').value); });
    $('sideClose').addEventListener('click', function () { closeSide(); if (V) { V.hl = null; refreshAll(); } });
    $('btnTheme').addEventListener('click', function () { S.theme = S.theme === 'auto' ? 'light' : S.theme === 'light' ? 'dark' : 'auto'; safeStore('theme', S.theme); applyTheme(); });
    $('btnHelp').addEventListener('click', showHelp);
    $('helpClose').addEventListener('click', function () { $('help').close(); });
    document.addEventListener('click', function (ev) { if (pop && !pop.contains(ev.target)) closePop(); });
    document.addEventListener('keydown', onKey);
  }
  function showHelp() {
    var b = $('helpBody'); clear(b);
    b.appendChild(el('h2', { text: t('helpTitle') }));
    var rows = [['/', 'sk_search'], ['Ctrl+K', 'sk_search2'], ['Alt+↑ / Alt+↓', 'sk_nav'], ['↑ ↓ Home End', 'sk_list'], ['Enter', 'sk_open'], ['Ctrl+G', 'sk_date'], ['PgUp PgDn Home End', 'sk_scroll'], ['Esc', 'sk_esc'], ['?', 'sk_help']];
    var tb = el('table'); rows.forEach(function (r) { tb.appendChild(el('tr', null, [el('td', null, [el('kbd', { text: r[0] })]), el('td', { text: t(r[1]) })])); });
    b.appendChild(tb);
    if ($('help').showModal) $('help').showModal();
  }
  function onKey(ev) {
    var tg = ev.target, typing = tg && (tg.tagName === 'INPUT' || tg.tagName === 'TEXTAREA' || tg.tagName === 'SELECT');
    if (ev.key === '/' && !typing && !ev.ctrlKey && !ev.metaKey) { ev.preventDefault(); $('q').focus(); $('q').select(); return; }
    if ((ev.ctrlKey || ev.metaKey) && (ev.key === 'k' || ev.key === 'K')) { ev.preventDefault(); $('q').focus(); $('q').select(); return; }
    if ((ev.ctrlKey || ev.metaKey) && (ev.key === 'g' || ev.key === 'G')) { var d = $('jumpDate'); if (d) { ev.preventDefault(); d.focus(); if (d.select) d.select(); } return; }
    if (ev.key === '?' && !typing) { ev.preventDefault(); showHelp(); return; }
    if (ev.key === 'Escape') {
      if (!$('lightbox').hidden) { $('lightbox').click(); return; }
      if (pop) { closePop(); return; }
      if (!$('side').hidden) { $('sideClose').click(); return; }
      if (typing) { tg.blur(); if (V) $('msgs').focus(); }
      return;
    }
    if (ev.altKey && (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') && S.visible.length) {
      ev.preventDefault();
      var i = V ? S.visible.indexOf(V.c) : -1, j = ev.key === 'ArrowDown' ? i + 1 : i - 1;
      if (j >= 0 && j < S.visible.length) openConv(S.visible[j]);
    }
  }

  /* ================================================================ test / automation surface (read-only helpers) */
  window.TT.api = {
    sanitize: sanitize, sanitizeToString: sanitizeToString, safeHref: safeHref, fold: fold,
    stats: function () { return { nodes: document.getElementsByTagName('*').length, rendered: V ? V.nodes.size : 0, total: V ? V.total : 0, loaded: V ? V.chunks.filter(function (c) { return c.items; }).length : 0, stick: V ? V.stick : null, conv: V ? V.c.id : null }; },
    open: function (id, opt) { openConv(CBY[id], opt); },
    goTo: function (i) { return goTo(i); },
    showTab: function (id) { setTab(id); },
    jump: function (ts) { return jumpToTs(ts); },
    search: runSearch,
    scrollTo: function (y) { $('msgs').scrollTop = y; },
    manifest: function () { return M; }
  };

  boot();
})();
