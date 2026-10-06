// Lectern chat transcript. Swift pushes the message list with Lectern.sync(messages); the page
// posts {type:"goto"|"copy"|"open"|"resync"} back through the "lectern" message handler.
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

  /// Turns [p. N], [pp. N–M], (p. N), (pages 2, 5) … in escaped text into page links (to the first
  /// page of a range). Leaves text inside links and code alone.
  function linkifyCitations(html) {
    return mapTextRuns(html, (text, skipped) => {
      if (skipped) return text;
      return text.replace(CITE_RE, (whole, open, inner, close) => {
        if ((open === '[') !== (close === ']')) return whole;
        const items = inner.match(CITE_ITEM_RE) || [];
        if (items.length <= 1) {
          const page = parseInt(/\d+/.exec(inner)[0], 10);
          return page >= 1 ? citeAnchor(whole, page) : whole;
        }
        return open + inner.replace(CITE_ITEM_RE, (item, first) => {
          const page = parseInt(first, 10);
          return page >= 1 ? citeAnchor(item, page) : item;
        }) + close;
      });
    });
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

  /// Markdown → safe HTML with page links and KaTeX math.
  function renderMarkdown(src) {
    const { text, maths } = extractMath(src);
    let html = md().parse(text);
    html = html.replace(/<table>/g, '<div class="table-wrap"><table>').replace(/<\/table>/g, '</table></div>');
    html = linkifyCitations(html);
    return restoreMath(html, maths);
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
  };

  const FIELDS = ['role', 'provider', 'model', 'text', 'status', 'errorText'];

  function normalize(item) {
    return {
      id: String(item.id),
      role: item.role || 'assistant',
      provider: item.provider || '',
      model: item.model || '',
      text: item.text || '',
      status: item.status || 'done',
      errorText: item.errorText || '',
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
          entry = { data, el: null, renderedText: null, renderedCaret: false };
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

  const COPY_ICON =
    '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="8.5" rx="1.6"/>' +
    '<path d="M3.5 10.5h-.4A1.6 1.6 0 0 1 1.5 8.9V3.1A1.6 1.6 0 0 1 3.1 1.5h5.8a1.6 1.6 0 0 1 1.6 1.6v.4"/></svg>';

  function createElement(entry) {
    const el = document.createElement('article');
    el.id = 'msg-' + entry.data.id;
    el.dataset.id = entry.data.id;
    el.innerHTML =
      '<div class="meta"></div><div class="body"></div><div class="status"></div>' +
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

    if (d.role === 'assistant') {
      meta.textContent = d.model ? d.provider + ' · ' + d.model : d.provider;
      const caret = d.status === 'streaming' && d.text.length > 0;
      if (entry.renderedText !== d.text || entry.renderedCaret !== caret) {
        body.innerHTML = d.text ? renderMarkdown(d.text) : '';
        if (caret) appendCaret(body);
        entry.renderedText = d.text;
        entry.renderedCaret = caret;
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
        return '<span class="thinking">Thinking<span class="dots"><i></i><i></i><i></i></span></span>';
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

  function onClick(event) {
    const target = event.target;
    if (!target || !target.closest) return;
    const anchor = target.closest('a');
    if (anchor) {
      event.preventDefault();
      if (anchor.classList.contains('cite')) {
        const page = parseInt(anchor.dataset.page, 10);
        if (page >= 1) post({ type: 'goto', page });
      } else if (anchor.classList.contains('ext')) {
        post({ type: 'open', url: anchor.href });
      }
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
    escapeHtml,
    copyMessage,
    flushNow() { if (state.scheduled) flush(); },
  };
  root.Lectern = Lectern;
  if (typeof module !== 'undefined' && module.exports) module.exports = Lectern;

  if (typeof document !== 'undefined') {
    document.addEventListener('click', onClick);
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
