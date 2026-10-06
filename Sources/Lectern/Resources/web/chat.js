// Lectern chat transcript. Swift pushes the message list with Lectern.sync(messages); the page
// posts {type:"goto"|"copy"|"open"|"saveCSV"|"resync"|"openFile"|"revealFile"} back through the
// "lectern" message handler.
// The pure helpers (renderMarkdown, extractMath, linkifyCitations, …) also load in node for tests.
(function (root) {
  'use strict';

  // ---------------------------------------------------------------------------------------------
  // Pure helpers

  const ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  function escapeHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ESCAPES[c]);
  }

  // Math placeholders use private-use characters so Markdown leaves them alone.
  const PH_OPEN = '';
  const PH_CLOSE = '';
  const PH_RE = /(\d+)/g;
  const FENCE_RE = /^ {0,3}(`{3,}|~{3,})/;

  /// Pulls math out before Markdown runs, so `_`, `*`, `\\` and `\(` inside formulas survive.
  /// A single `$` follows Pandoc's rules (no space after the opening `$`, none before the closing
  /// one, no digit right after it), so currency such as "$412.7M … $74.1M" stays text.
  function extractMath(src) {
    src = String(src == null ? '' : src);
    const maths = [];
    let out = '';
    let i = 0;
    const n = src.length;
    let lineStart = true;
    let fence = null;

    const push = (tex, display, raw) => {
      maths.push({ tex, display, raw });
      out += PH_OPEN + (maths.length - 1) + PH_CLOSE;
    };

    while (i < n) {
      if (lineStart) {
        const nl = src.indexOf('\n', i);
        const end = nl < 0 ? n : nl + 1;
        const line = src.slice(i, end);
        const m = FENCE_RE.exec(line);
        if (fence) {
          if (m && m[1][0] === fence.ch && m[1].length >= fence.len && /^ {0,3}[`~]+\s*$/.test(line)) fence = null;
          out += line;
          i = end;
          continue;
        }
        if (m) {
          fence = { ch: m[1][0], len: m[1].length };
          out += line;
          i = end;
          continue;
        }
        lineStart = false;
      }

      const c = src[i];
      if (c === '\n') {
        out += c;
        i++;
        lineStart = true;
        continue;
      }
      if (c === '\\') {
        const d = src[i + 1];
        if (d === '(' || d === '[') {
          const close = d === '(' ? '\\)' : '\\]';
          const j = src.indexOf(close, i + 2);
          if (j >= 0 && src.slice(i + 2, j).trim()) {
            push(src.slice(i + 2, j), d === '[', src.slice(i, j + 2));
            i = j + 2;
            continue;
          }
        }
        // Keep escape pairs verbatim so Markdown still sees e.g. `\$` and `\*`.
        out += d === undefined ? c : c + d;
        i += d === undefined ? 1 : 2;
        continue;
      }
      if (c === '`') {
        let k = i;
        while (src[k] === '`') k++;
        const run = k - i;
        const close = findBacktickClose(src, k, run);
        if (close >= 0) {
          out += src.slice(i, close + run);
          i = close + run;
        } else {
          out += src.slice(i, k);
          i = k;
        }
        continue;
      }
      if (c === '$') {
        if (src[i + 1] === '$') {
          const j = src.indexOf('$$', i + 2);
          if (j >= 0 && src.slice(i + 2, j).trim()) {
            push(src.slice(i + 2, j), true, src.slice(i, j + 2));
            i = j + 2;
            continue;
          }
          out += '$$';
          i += 2;
          continue;
        }
        const j = findDollarClose(src, i);
        if (j > 0) {
          push(src.slice(i + 1, j), false, src.slice(i, j + 1));
          i = j + 1;
          continue;
        }
      }
      out += c;
      i++;
    }
    return { text: out, maths };
  }

  /// Index of the backtick run of exactly `len` that closes a code span, or -1. Code spans do not
  /// cross blank lines.
  function findBacktickClose(src, from, len) {
    const para = src.indexOf('\n\n', from);
    const limit = para < 0 ? src.length : para;
    let j = from;
    while (j < limit) {
      if (src[j] !== '`') { j++; continue; }
      let k = j;
      while (src[k] === '`') k++;
      if (k - j === len && k <= limit) return j;
      j = k;
    }
    return -1;
  }

  function findDollarClose(src, open) {
    const first = src[open + 1];
    if (first === undefined || /\s/.test(first)) return -1;
    for (let j = open + 1; j < src.length; j++) {
      const ch = src[j];
      if (ch === '\n') return -1;
      if (ch === '\\') { j++; continue; }
      if (ch === '$') {
        // Only the first `$` can close; otherwise "$5 to $10 or $x$" would swallow the prices.
        if (/\s/.test(src[j - 1]) || /[0-9]/.test(src[j + 1] || '')) return -1;
        return j;
      }
    }
    return -1;
  }

  function safeHref(href) {
    try {
      const url = new URL(String(href));
      return url.protocol === 'http:' || url.protocol === 'https:' || url.protocol === 'mailto:' ? url.href : null;
    } catch (e) {
      return null;
    }
  }

  let markdown = null;
  function md() {
    if (markdown) return markdown;
    const M = root.marked;
    if (!M || !M.Marked) throw new Error('marked is not loaded');
    markdown = new M.Marked({ gfm: true, breaks: false });
    markdown.use({
      renderer: {
        // Model output must never inject markup: raw HTML is shown as text.
        html(token) {
          const text = escapeHtml(token.text);
          return token.block ? '<p class="raw-html">' + text.replace(/\n+$/, '') + '</p>\n' : text;
        },
        // No network: images become a text reference.
        image(token) {
          const label = token.text ? 'image: ' + token.text : 'image';
          return '<span class="image-ref">[' + escapeHtml(label) + ']</span>';
        },
        link(token) {
          const inner = this.parser.parseInline(token.tokens);
          const href = safeHref(token.href);
          if (!href) return inner;
          // Link text that reads like a page citation ("[p. 3]") stays text, which linkifyCitations turns
          // into a real in-app citation: a web link must never pass for one.
          if (CITE_TEXT_RE.test(token.text || '')) return inner;
          // The destination is always visible on hover.
          const title = token.title ? token.title + '\n' + href : href;
          return '<a class="ext" href="' + escapeHtml(href) + '" title="' + escapeHtml(title) + '">' + inner + '</a>';
        },
      },
    });
    return markdown;
  }

  const SKIP_TAGS = /^(a|code|pre)$/i;

  /// Calls `fn(text, skipped)` for every text run between tags of a well-formed HTML string;
  /// `skipped` is true inside <a>, <code> and <pre>. Tags are passed through, with `onTag` applied.
  function mapTextRuns(html, fn, onTag) {
    const parts = html.split(/(<[^>]*>)/);
    let skipDepth = 0;
    for (let k = 0; k < parts.length; k++) {
      const part = parts[k];
      if (!part) continue;
      if (part[0] === '<') {
        const m = /^<(\/?)([a-zA-Z0-9]+)/.exec(part);
        if (m && SKIP_TAGS.test(m[2]) && !/\/>$/.test(part)) skipDepth = Math.max(0, skipDepth + (m[1] ? -1 : 1));
        if (onTag) parts[k] = onTag(part);
      } else {
        parts[k] = fn(part, skipDepth > 0);
      }
    }
    return parts.join('');
  }

  const CITE_TEXT_RE = /^\s*[\[(]?\s*(?:pp?\.|pages?)\s*\d/i;
  const PAGE_ITEM = '(?:pp?\\.|pages?)\\s*\\d+(?:\\s*[–—-]\\s*\\d+)?';
  const CITE_RE = new RegExp(
    '([\\[(])(' + PAGE_ITEM + '(?:\\s*[,;]\\s*(?:(?:pp?\\.|pages?)\\s*)?\\d+(?:\\s*[–—-]\\s*\\d+)?)*)([\\])])', 'gi');
  const CITE_ITEM_RE = /(?:(?:pp?\.|pages?)\s*)?(\d+)(?:\s*[–—-]\s*\d+)?/gi;

  function citeAnchor(label, page) {
    return '<a class="cite" href="#" data-page="' + page + '" title="Go to page ' + page + '">' + label + '</a>';
  }

  const BADGE_SLOT_RE = /<!--lectern-badge:(\d+)-->/g;

  /// Turns [p. N], [pp. N–M], (p. N), (pages 2, 5) … in escaped text into page links (to the first
  /// page of a range). Leaves text inside links and code alone. Each bracketed citation becomes a
  /// numbered `.cite-group` (its 0-based order in the answer, like CitationCheck.ordinal) with a slot
  /// for its badge; `groups`, when given, receives each one's lowest page number.
  function linkifyCitations(html, groups) {
    let ordinal = 0;
    return mapTextRuns(html, (text, skipped) => {
      if (skipped) return text;
      return text.replace(CITE_RE, (whole, open, inner, close) => {
        if ((open === '[') !== (close === ']')) return whole;
        const numbers = (inner.match(/\d+/g) || []).map((d) => parseInt(d, 10));
        if (groups) groups.push({ page: Math.min.apply(null, numbers) });
        const items = inner.match(CITE_ITEM_RE) || [];
        let linked;
        if (items.length <= 1) {
          const page = numbers[0];
          linked = page >= 1 ? citeAnchor(whole, page) : whole;
        } else {
          linked = open + inner.replace(CITE_ITEM_RE, (item, first) => {
            const page = parseInt(first, 10);
            return page >= 1 ? citeAnchor(item, page) : item;
          }) + close;
        }
        const k = ordinal++;
        return '<span class="cite-group" data-cite="' + k + '">' + linked + '<!--lectern-badge:' + k + '--></span>';
      });
    });
  }

  function pageLabel(pages) {
    const list = (pages || []).filter((n) => Number.isFinite(n));
    if (list.length <= 1) return 'p. ' + (list.length ? list[0] : '?');
    const contiguous = list.every((n, k) => k === 0 || n === list[k - 1] + 1);
    return 'pp. ' + (contiguous ? list[0] + '–' + list[list.length - 1] : list.join(', '));
  }

  function badgeHTML(check) {
    const missing = (check.missing || []).map(String).filter((m) => m);
    let cls;
    let tip;
    switch (check.status) {
      case 'verified':
        cls = 'ok';
        tip = 'Found on ' + pageLabel(check.pages);
        break;
      case 'partial':
      case 'notFound':
        cls = 'warn';
        tip = 'Not found on ' + pageLabel(check.pages) + (missing.length ? ': ' + missing.join(', ') : '');
        break;
      case 'pageMissing':
        cls = 'warn';
        tip = 'No ' + pageLabel(check.pages).replace(/^pp?\. /, (check.pages || []).length > 1 ? 'pages ' : 'page ');
        break;
      default:
        return '';
    }
    const t = escapeHtml(tip);
    return '<span class="cite-badge ' + cls + '" title="' + t + '" aria-label="' + t + '">' +
      (cls === 'ok' ? '✓' : '⚠') + '</span>';
  }

  /// Fills the badge slots from Swift's CitationChecks (matched by ordinal). When the checks don't
  /// line up with the citations found here (different count, or a different page at some ordinal),
  /// the message gets no badges rather than wrong ones.
  function applyCitationBadges(html, groups, checks) {
    const list = Array.isArray(checks) ? checks.slice().sort((a, b) => a.ordinal - b.ordinal) : [];
    const aligned = list.length > 0 && list.length === groups.length && list.every((c, k) => {
      if (!c || c.ordinal !== k) return false;
      const pages = Array.isArray(c.pages) ? c.pages : [];
      return pages.length === 0 || Math.min.apply(null, pages) === groups[k].page;
    });
    return html.replace(BADGE_SLOT_RE, (_, k) => (aligned ? badgeHTML(list[+k]) : ''));
  }

  const texCache = new Map();
  function renderTex(tex, display) {
    const K = root.katex;
    if (!K || !K.renderToString) return null;
    const key = (display ? 'D:' : 'I:') + tex;
    if (texCache.has(key)) return texCache.get(key);
    let html = null;
    try {
      html = K.renderToString(tex, { displayMode: display, throwOnError: false, strict: 'ignore', trust: false, maxSize: 20 });
    } catch (e) {
      html = null;
    }
    if (texCache.size > 800) texCache.clear();
    texCache.set(key, html);
    return html;
  }

  /// Puts math back: rendered with KaTeX in normal text, as the original source inside code,
  /// links and attributes.
  function restoreMath(html, maths) {
    if (!maths.length) return html;
    const source = (idx) => (maths[idx] ? escapeHtml(maths[idx].raw) : '');
    return mapTextRuns(
      html,
      (text, skipped) =>
        text.replace(PH_RE, (_, d) => {
          const m = maths[+d];
          if (!m) return '';
          if (skipped) return source(+d);
          const rendered = renderTex(m.tex, m.display);
          if (rendered == null) return '<span class="math-source">' + source(+d) + '</span>';
          return m.display ? '<span class="math-display">' + rendered + '</span>' : rendered;
        }),
      (tag) => tag.replace(PH_RE, (_, d) => source(+d))
    );
  }

  const TABLE_OPEN =
    '<div class="table-block"><div class="table-tools">' +
    '<button type="button" class="table-csv-copy" title="Copy the table as CSV">Copy CSV</button>' +
    '<button type="button" class="table-csv-save" title="Save the table as a CSV file">Save CSV…</button>' +
    '</div><div class="table-wrap"><table>';

  /// Markdown → safe HTML with page links, citation badges (from `checks`, optional) and KaTeX math.
  function renderMarkdown(src, checks) {
    const { text, maths } = extractMath(src);
    let html = md().parse(text);
    html = html.replace(/<table>/g, TABLE_OPEN).replace(/<\/table>/g, '</table></div></div>');
    const groups = [];
    html = linkifyCitations(html, groups);
    html = restoreMath(html, maths);
    return applyCitationBadges(html, groups, checks);
  }

  // ---------------------------------------------------------------------------------------------
  // Citation claims: the sentence a clicked citation supports, sent with the page so the reader can
  // highlight the passage. Built from the rendered block's text, with the clicked citation replaced
  // by MARK and the block's other citations by OTHER.

  const MARK = '\u0001';
  const OTHER = '\u0002';
  const ABBREVIATIONS = new Set(['pp', 'vs', 'etc', 'inc', 'co', 'corp', 'ltd', 'mr', 'mrs', 'ms', 'dr', 'no',
    'fig', 'figs', 'approx', 'e.g', 'i.e', 'cf', 'est', 'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug',
    'sep', 'sept', 'oct', 'nov', 'dec']);

  /// Whether text[i] ends a sentence. Decimal points (412.7), "p. 3", "e.g." and initials don't.
  function isSentenceEnd(text, i) {
    const c = text[i];
    if (c === '。' || c === '！' || c === '？') return true;
    if (c !== '.' && c !== '!' && c !== '?') return false;
    let j = i + 1;
    while (j < text.length && /["'”’)\]]/.test(text[j])) j++;
    if (j < text.length && !/\s/.test(text[j])) return false;
    if (c === '.') {
      const word = /([A-Za-z][A-Za-z.]*)$/.exec(text.slice(Math.max(0, i - 12), i));
      if (word && (word[1].length === 1 || ABBREVIATIONS.has(word[1].toLowerCase()))) return false;
    }
    return true;
  }

  function cleanClaim(s) {
    return s
      .split(MARK).join(' ')
      .split(OTHER).join(' ')
      .replace(/\s+/g, ' ')
      .replace(/\s+([.,;:!?)\]。，；：！？])/g, '$1')
      .replace(/([(\[])\s+/g, '$1')
      .replace(/^[\s,;:–—-]+/, '')
      .replace(/[\s,;:–—-]+$/, '')
      .trim()
      .slice(0, 600);
  }

  function wordCount(s) {
    // A CJK character counts as a word.
    return (s.match(/[A-Za-z0-9$€£¥%.,]+|[\u3400-\u9fff]/g) || []).length;
  }

  /// The claim for MARK in `raw`: the sentence it ends or sits in. With several citations in one
  /// sentence, the clause since the previous citation; a citation that opens a sentence supports
  /// the sentence before it.
  function claimFromText(raw) {
    const text = String(raw == null ? '' : raw).replace(/\s+/g, ' ');
    const at = text.indexOf(MARK);
    if (at < 0) return cleanClaim(text);
    let start = 0;
    for (let i = at - 1; i >= 0; i--) if (isSentenceEnd(text, i)) { start = i + 1; break; }
    let end = text.length;
    for (let i = at + 1; i < text.length; i++) if (isSentenceEnd(text, i)) { end = i + 1; break; }
    if (!cleanClaim(text.slice(start, at))) {
      if (start === 0) return cleanClaim(text.slice(at + 1, end));
      let prev = 0;
      for (let i = start - 2; i >= 0; i--) if (isSentenceEnd(text, i)) { prev = i + 1; break; }
      return cleanClaim(text.slice(prev, start));
    }
    const before = text.lastIndexOf(OTHER, at);
    const after = text.indexOf(OTHER, at);
    const clauseStart = before >= start ? before + 1 : start;
    const clauseEnd = after >= 0 && after < end ? at : end;
    const clause = cleanClaim(text.slice(clauseStart, clauseEnd));
    if (wordCount(clause) >= 3) return clause;
    return cleanClaim(text.slice(start, end));
  }

  const SKIP_CLASSES = ['cite-badge', 'table-tools', 'caret'];

  /// Visible text of a rendered element: math as its TeX source, no badges or buttons. `hook(el)` may
  /// return a string to use instead of an element's text.
  function plainText(node, hook) {
    let out = '';
    const walk = (n) => {
      for (const child of n.childNodes) {
        if (child.nodeType === 3) { out += child.nodeValue; continue; }
        if (child.nodeType !== 1) continue;
        const replaced = hook ? hook(child) : undefined;
        if (replaced != null) { out += replaced; continue; }
        if (SKIP_CLASSES.some((c) => child.classList.contains(c))) continue;
        if (child.classList.contains('katex')) {
          const tex = child.querySelector('annotation');
          out += tex ? tex.textContent : '';
          continue;
        }
        if (child.tagName === 'BR') { out += ' '; continue; }
        walk(child);
        if (child.tagName === 'TD' || child.tagName === 'TH') out += ' ';
      }
    };
    walk(node);
    return out;
  }

  /// The claim for a clicked `.cite-group`: its sentence, or its table row.
  function citationClaim(group) {
    if (!group || !group.closest) return '';
    const cell = group.closest('td, th');
    const block = (cell && cell.closest('tr')) ||
      group.closest('p, li, h1, h2, h3, h4, h5, h6, dd, dt, blockquote') || group.closest('.body');
    if (!block) return '';
    const text = plainText(block, (el) => {
      if (el === group) return MARK;
      if (el.classList.contains('cite-group')) return OTHER;
      // A list item's nested list holds other claims.
      if ((el.tagName === 'UL' || el.tagName === 'OL') && !el.contains(group)) return ' ';
      return undefined;
    });
    return claimFromText(text);
  }

  // ---------------------------------------------------------------------------------------------
  // Tables → CSV (RFC 4180, CRLF line ends)

  function csvField(value) {
    let s = String(value == null ? '' : value);
    // Spreadsheets run cells that start with = + - @ as formulas; "-12.3%" and "+4" stay as shown.
    if (/^[=@\t\r]/.test(s) || (/^[+-]/.test(s) && /[=(|!@]/.test(s))) s = "'" + s;
    return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }

  function toCSV(rows) {
    return rows.map((row) => row.map(csvField).join(',')).join('\r\n') + '\r\n';
  }

  function tableRows(table) {
    const rows = [];
    for (const tr of table.querySelectorAll('tr')) {
      const cells = Array.from(tr.children).filter((c) => c.tagName === 'TD' || c.tagName === 'TH');
      rows.push(cells.map((c) => plainText(c).replace(/\s+/g, ' ').trim()));
    }
    return rows;
  }

  // ---------------------------------------------------------------------------------------------
  // Skill turns: a chip on the question, a label and the output files on the answer

  const SKILL_NOTE = ' · writes to Lectern Output · network on';

  const FILE_KINDS = {
    word: ['doc', 'docx', 'rtf', 'pages', 'odt'],
    sheet: ['xls', 'xlsx', 'xlsm', 'csv', 'tsv', 'numbers', 'ods'],
    slides: ['ppt', 'pptx', 'key', 'odp'],
    pdf: ['pdf'],
    image: ['png', 'jpg', 'jpeg', 'gif', 'tif', 'tiff', 'heic', 'webp', 'svg'],
    text: ['md', 'markdown', 'txt', 'json', 'xml', 'yaml', 'yml', 'html', 'htm'],
  };

  function baseName(path) {
    const s = String(path == null ? '' : path);
    return s.slice(s.lastIndexOf('/') + 1);
  }

  /// The extension (lowercase; '' when none) and the icon kind of a file name.
  function fileKind(name) {
    const dot = name.lastIndexOf('.');
    const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
    for (const kind of Object.keys(FILE_KINDS)) if (FILE_KINDS[kind].includes(ext)) return { ext, kind };
    return { ext, kind: 'other' };
  }

  /// An answer's files: an icon (the extension, colored by kind), the name, Open and Show in Finder.
  /// Buttons carry the file's index; the path itself goes to Swift from the message data.
  function filesHTML(files) {
    if (!Array.isArray(files) || !files.length) return '';
    return '<ul>' + files.map((path, i) => {
      const name = baseName(path);
      const { ext, kind } = fileKind(name);
      return '<li class="file" data-index="' + i + '" title="' + escapeHtml(path) + '">' +
        '<span class="file-icon kind-' + kind + '" aria-hidden="true">' +
        escapeHtml(ext ? ext.slice(0, 4).toUpperCase() : 'FILE') + '</span>' +
        '<span class="file-name">' + escapeHtml(name) + '</span><span class="file-actions">' +
        '<button type="button" class="file-open">Open</button>' +
        '<button type="button" class="file-reveal">Show in Finder</button></span></li>';
    }).join('') + '</ul>';
  }

  // ---------------------------------------------------------------------------------------------
  // Bridge to Swift

  function post(message) {
    const handler = root.webkit && root.webkit.messageHandlers && root.webkit.messageHandlers.lectern;
    if (!handler) return false;
    handler.postMessage(message);
    return true;
  }

  // ---------------------------------------------------------------------------------------------
  // Transcript state and rendering

  const state = {
    entries: new Map(), // id → { data, el, renderedText, renderedCaret }
    order: [],
    dirty: new Set(),
    orderDirty: true,
    scheduled: false,
    raf: 0,
    timer: 0,
    forceScroll: true,
    pinned: true, // the reader is at the end of the transcript
  };

  const FIELDS = ['role', 'provider', 'model', 'text', 'status', 'errorText', 'checksKey', 'skill', 'filesKey'];

  function normalize(item) {
    const checks = Array.isArray(item.checks) && item.checks.length ? item.checks : null;
    const files = Array.isArray(item.files) ? item.files.filter((f) => typeof f === 'string' && f) : [];
    return {
      id: String(item.id),
      role: item.role || 'assistant',
      provider: item.provider || '',
      model: item.model || '',
      text: item.text || '',
      status: item.status || 'done',
      errorText: item.errorText || '',
      checks,
      checksKey: checks ? JSON.stringify(checks) : '',
      skill: item.skill || '',
      files,
      filesKey: files.join('\n'),
    };
  }

  /// Accepts the full ordered message list. An item with only an `id` means "unchanged since the
  /// previous sync" (Swift sends those to keep streaming updates small). Returns the message count.
  function sync(list) {
    if (!Array.isArray(list)) return 0;
    const seen = new Set();
    const order = [];
    let missing = false;
    for (const item of list) {
      if (!item || item.id == null) continue;
      const id = String(item.id);
      if (seen.has(id)) continue;
      let entry = state.entries.get(id);
      if (item.role === undefined) {
        if (!entry) { missing = true; continue; }
      } else {
        const data = normalize(item);
        if (!entry) {
          entry = { data, el: null, renderedText: null, renderedCaret: false, renderedChecks: '', renderedFiles: null };
          state.entries.set(id, entry);
          state.dirty.add(id);
          if (data.role === 'user') state.forceScroll = true;
        } else if (FIELDS.some((f) => entry.data[f] !== data[f])) {
          entry.data = data;
          state.dirty.add(id);
        }
      }
      seen.add(id);
      order.push(id);
    }
    for (const [id, entry] of state.entries) {
      if (seen.has(id)) continue;
      if (entry.el) entry.el.remove();
      state.entries.delete(id);
      state.dirty.delete(id);
    }
    if (order.length !== state.order.length || order.some((id, k) => id !== state.order[k])) state.orderDirty = true;
    state.order = order;
    if (missing) post({ type: 'resync' });
    schedule();
    return order.length;
  }

  // requestAnimationFrame coalesces streaming updates; the timer covers hidden windows, where
  // WebKit pauses animation frames.
  function schedule() {
    if (state.scheduled || typeof document === 'undefined') return;
    state.scheduled = true;
    state.raf = root.requestAnimationFrame ? root.requestAnimationFrame(flush) : 0;
    state.timer = setTimeout(flush, 120);
  }

  function flush() {
    if (!state.scheduled) return;
    state.scheduled = false;
    if (state.raf && root.cancelAnimationFrame) root.cancelAnimationFrame(state.raf);
    clearTimeout(state.timer);

    const scroller = document.scrollingElement || document.documentElement;
    const nearBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
    const list = document.getElementById('messages');

    for (const id of state.dirty) renderEntry(state.entries.get(id));
    state.dirty.clear();

    if (state.orderDirty) {
      let k = 0;
      for (const id of state.order) {
        const el = state.entries.get(id).el;
        if (list.children[k] !== el) list.insertBefore(el, list.children[k] || null);
        k++;
      }
      state.orderDirty = false;
    }
    document.body.classList.toggle('is-empty', state.order.length === 0);

    if (nearBottom || state.forceScroll) scroller.scrollTop = scroller.scrollHeight;
    state.forceScroll = false;
  }

  // A reader at the end of the transcript stays there when the panel changes width (the conversation
  // grid changed, the window resized) or the text size changes.
  function nearEnd() {
    const scroller = document.scrollingElement || document.documentElement;
    return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
  }

  function keepEnd() {
    const scroller = document.scrollingElement || document.documentElement;
    if (state.pinned) scroller.scrollTop = scroller.scrollHeight;
  }

  /// View > Chat Text Size: every size in chat.css scales from --chat-font-size.
  /// View > Chat Font: the transcript's font family (code and math stay monospaced).
  function setFont(family) {
    state.pinned = nearEnd();
    document.documentElement.style.setProperty('--chat-font-family', family);
    keepEnd();
  }

  function setTextSize(px) {
    state.pinned = nearEnd();
    document.documentElement.style.setProperty('--chat-font-size', px + 'px');
    keepEnd();
  }

  const COPY_ICON =
    '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="8.5" rx="1.6"/>' +
    '<path d="M3.5 10.5h-.4A1.6 1.6 0 0 1 1.5 8.9V3.1A1.6 1.6 0 0 1 3.1 1.5h5.8a1.6 1.6 0 0 1 1.6 1.6v.4"/></svg>';

  function createElement(entry) {
    const el = document.createElement('article');
    el.id = 'msg-' + entry.data.id;
    el.dataset.id = entry.data.id;
    el.innerHTML =
      '<div class="skill-chip"></div><div class="meta"></div><div class="body"></div>' +
      '<div class="files"></div><div class="status"></div>' +
      '<div class="actions"><button type="button" class="copy" title="Copy answer as Markdown">' +
      COPY_ICON + '<span>Copy</span></button></div>';
    entry.el = el;
    return el;
  }

  function renderEntry(entry) {
    if (!entry) return;
    const d = entry.data;
    const el = entry.el || createElement(entry);
    el.className = 'msg ' + d.role + ' is-' + d.status;
    const meta = el.querySelector('.meta');
    const body = el.querySelector('.body');
    const status = el.querySelector('.status');

    el.querySelector('.skill-chip').textContent = d.role === 'user' && d.skill ? 'Skill: ' + d.skill + SKILL_NOTE : '';
    if (entry.renderedFiles !== d.filesKey) {
      el.querySelector('.files').innerHTML = d.role === 'assistant' ? filesHTML(d.files) : '';
      entry.renderedFiles = d.filesKey;
    }
    if (d.role === 'assistant') {
      meta.innerHTML = escapeHtml(d.model ? d.provider + ' · ' + d.model : d.provider) +
        (d.skill ? ' <span class="skill-tag">Skill: ' + escapeHtml(d.skill) + '</span>' : '');
      const caret = d.status === 'streaming' && d.text.length > 0;
      if (entry.renderedText !== d.text || entry.renderedCaret !== caret || entry.renderedChecks !== d.checksKey) {
        body.innerHTML = d.text ? renderMarkdown(d.text, d.checks) : '';
        if (caret) appendCaret(body);
        entry.renderedText = d.text;
        entry.renderedCaret = caret;
        entry.renderedChecks = d.checksKey;
      }
    } else {
      meta.textContent = '';
      if (entry.renderedText !== d.text) {
        body.textContent = d.text;
        entry.renderedText = d.text;
      }
    }
    status.innerHTML = statusHTML(d);
    el.classList.toggle('can-copy', d.role === 'assistant' && d.text.length > 0 &&
      d.status !== 'streaming' && d.status !== 'thinking');
  }

  function statusHTML(d) {
    switch (d.status) {
      case 'thinking':
        return '<span class="thinking">' + (d.skill ? 'Running skill' : 'Thinking') +
          '<span class="dots"><i></i><i></i><i></i></span></span>';
      case 'streaming':
        return d.text ? '' : '<span class="thinking"><span class="dots"><i></i><i></i><i></i></span></span>';
      case 'interrupted':
        return '<span class="tag">Stopped</span>';
      case 'failed':
        return '<div class="error">' + escapeHtml(d.errorText || 'Something went wrong.') + '</div>';
      case 'waitingForLogin':
        return '<span class="waiting">Waiting for you to log in — will send automatically</span>';
      default:
        return '';
    }
  }

  const CARET_BLOCKS = /^(P|UL|OL|LI|BLOCKQUOTE|H[1-6])$/;
  function appendCaret(body) {
    let target = body;
    for (;;) {
      let last = target.lastChild;
      while (last && last.nodeType === 3 && !last.textContent.trim()) last = last.previousSibling;
      if (last && last.nodeType === 1 && CARET_BLOCKS.test(last.tagName)) target = last;
      else break;
    }
    const caret = document.createElement('span');
    caret.className = 'caret';
    target.appendChild(caret);
  }

  function copyMessage(id) {
    const entry = state.entries.get(String(id));
    if (!entry) return false;
    const text = entry.data.text;
    if (post({ type: 'copy', text })) return true;
    if (root.navigator && root.navigator.clipboard) {
      root.navigator.clipboard.writeText(text).catch(() => {});
      return true;
    }
    return false;
  }

  function flashLabel(button, text) {
    const original = button.dataset.label || button.textContent;
    button.dataset.label = original;
    button.textContent = text;
    button.classList.add('done');
    setTimeout(() => {
      button.textContent = original;
      button.classList.remove('done');
    }, 1200);
  }

  function onTableButton(button) {
    const block = button.closest('.table-block');
    const table = block && block.querySelector('table');
    if (!table) return;
    const csv = toCSV(tableRows(table));
    if (button.classList.contains('table-csv-save')) {
      post({ type: 'saveCSV', csv, name: 'table' });
    } else if (post({ type: 'copy', text: csv }) ||
               (root.navigator && root.navigator.clipboard && root.navigator.clipboard.writeText(csv).catch(() => {}))) {
      flashLabel(button, 'Copied');
    }
  }

  /// Open / Show in Finder on an answer's file: posts that file's path. Returns the message, or null.
  function onFileButton(button) {
    const item = button.closest('li.file');
    const article = button.closest('article');
    const entry = article && state.entries.get(article.dataset.id);
    const path = entry && item ? entry.data.files[parseInt(item.dataset.index, 10)] : null;
    if (!path) return null;
    const message = { type: button.classList.contains('file-open') ? 'openFile' : 'revealFile', path };
    post(message);
    return message;
  }

  function onClick(event) {
    const target = event.target;
    if (!target || !target.closest) return;
    const fileButton = target.closest('button.file-open, button.file-reveal');
    if (fileButton) {
      onFileButton(fileButton);
      return;
    }
    const anchor = target.closest('a');
    if (anchor) {
      event.preventDefault();
      if (anchor.classList.contains('cite')) {
        const page = parseInt(anchor.dataset.page, 10);
        if (page >= 1) post({ type: 'goto', page, claim: citationClaim(anchor.closest('.cite-group')) });
      } else if (anchor.classList.contains('ext')) {
        post({ type: 'open', url: anchor.href });
      }
      return;
    }
    const tableButton = target.closest('button.table-csv-copy, button.table-csv-save');
    if (tableButton) {
      onTableButton(tableButton);
      return;
    }
    const button = target.closest('button.copy');
    if (button) {
      const article = button.closest('article');
      if (article && copyMessage(article.dataset.id)) {
        button.classList.add('done');
        button.querySelector('span').textContent = 'Copied';
        setTimeout(() => {
          button.classList.remove('done');
          button.querySelector('span').textContent = 'Copy';
        }, 1200);
      }
    }
  }

  const Lectern = {
    sync,
    renderMarkdown,
    extractMath,
    linkifyCitations,
    applyCitationBadges,
    claimFromText,
    citationClaim,
    plainText,
    tableRows,
    toCSV,
    escapeHtml,
    copyMessage,
    fileKind,
    filesHTML,
    onFileButton,
    flushNow() { if (state.scheduled) flush(); },
    setTextSize,
    setFont,
  };
  root.Lectern = Lectern;
  if (typeof module !== 'undefined' && module.exports) module.exports = Lectern;

  if (typeof document !== 'undefined') {
    document.addEventListener('click', onClick);
    // Resize steps run before scroll steps, so a reflow's scroll clamp can't unpin first.
    root.addEventListener('scroll', () => { state.pinned = nearEnd(); }, { passive: true });
    root.addEventListener('resize', keepEnd);
    document.body.classList.add('is-empty');

    // KaTeX metrics change when its web fonts arrive; math laid out with fallback fonts can be left
    // painted over the following text, so re-render messages with math once fonts finish loading.
    const fonts = document.fonts;
    if (fonts && fonts.addEventListener) {
      fonts.addEventListener('loadingdone', () => {
        for (const [id, entry] of state.entries) {
          if (entry.el && entry.el.querySelector('.katex')) {
            entry.renderedText = null;
            state.dirty.add(id);
          }
        }
        schedule();
      });
      for (const face of ['16px KaTeX_Main', 'italic 16px KaTeX_Math', 'bold 16px KaTeX_Main']) {
        fonts.load(face).catch(() => {});
      }
    }
  }
})(typeof window !== 'undefined' ? window : globalThis);
