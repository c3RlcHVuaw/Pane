import Foundation

/// Page script for Reader mode: pulls the article out of the page and shows it in a clean full-window layer.
/// Running it again (or pressing Esc) removes the layer.
enum ReaderScript {
    static let source = """
    (() => {
      const old = document.getElementById('__pane_reader');
      if (old) { old.remove(); document.documentElement.style.overflow = ''; return 'closed'; }
      const score = el => Array.from(el.querySelectorAll('p')).reduce((n, p) => n + (p.innerText.length > 60 ? p.innerText.length : 0), 0);
      let best = document.querySelector('article') || document.querySelector('main') || document.body;
      for (const el of document.querySelectorAll('article, main, section, div')) {
        if (score(el) > score(best) * 1.15 && el.querySelectorAll('p').length >= 3) best = el;
      }
      const blocks = Array.from(best.querySelectorAll('h1, h2, h3, h4, p, li, blockquote, pre, figure img, img'))
        .filter(e => !e.closest('nav, header, footer, aside, form, [role=navigation], [aria-hidden=true]'));
      const text = blocks.filter(e => !/^IMG$/.test(e.tagName)).map(e => e.innerText || '').join('').length;
      if (text < 200) return 'nothing';
      const esc = s => s.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
      let html = '';
      const h1 = document.querySelector('h1');
      html += '<h1>' + esc((h1 && h1.innerText.trim()) || document.title) + '</h1>';
      const seen = new Set();
      for (const e of blocks) {
        const t = (e.innerText || '').trim();
        if (e.tagName === 'IMG') { if (e.naturalWidth > 300 && e.src && !seen.has(e.src)) { seen.add(e.src); html += '<img src="' + e.src + '">'; } continue; }
        if (!t || seen.has(t) || (e.tagName === 'LI' && t.length < 25)) continue;
        seen.add(t);
        const tag = e.tagName.toLowerCase();
        html += '<' + tag + '>' + esc(t) + '</' + tag + '>';
      }
      const root = document.createElement('div');
      root.id = '__pane_reader';
      root.innerHTML = '<style>' +
        '#__pane_reader{all:initial;position:fixed;inset:0;z-index:2147483647;overflow:auto;background:#fbfaf7;color:#222;font:21px/1.65 Georgia,"Iowan Old Style",serif;-webkit-font-smoothing:antialiased}' +
        '@media(prefers-color-scheme:dark){#__pane_reader{background:#161618;color:#dcdcdc}}' +
        '#__pane_reader .w{max-width:680px;margin:0 auto;padding:72px 28px 120px;opacity:0;transform:translateY(10px);transition:all .45s cubic-bezier(.2,.9,.3,1)}' +
        '#__pane_reader .w.on{opacity:1;transform:none}' +
        '#__pane_reader h1{font:700 40px/1.2 -apple-system,Helvetica,sans-serif;margin:0 0 32px}' +
        '#__pane_reader h2,#__pane_reader h3,#__pane_reader h4{font:650 26px/1.3 -apple-system,Helvetica,sans-serif;margin:42px 0 12px}' +
        '#__pane_reader p,#__pane_reader li,#__pane_reader blockquote{margin:0 0 22px;display:block}' +
        '#__pane_reader blockquote{border-left:3px solid #8884;padding-left:18px;font-style:italic}' +
        '#__pane_reader pre{font:15px/1.5 ui-monospace,Menlo,monospace;white-space:pre-wrap;background:#8881;padding:14px;border-radius:10px}' +
        '#__pane_reader img{max-width:100%;border-radius:12px;margin:10px 0 26px;display:block}' +
        '#__pane_reader .x{position:fixed;top:16px;right:22px;font:600 13px -apple-system,sans-serif;opacity:.55;cursor:pointer;background:#8883;padding:6px 12px;border-radius:99px}' +
        '</style><div class="x" title="Esc">✕</div><div class="w">' + html + '</div>';
      document.documentElement.appendChild(root);
      document.documentElement.style.overflow = 'hidden';
      const close = () => { root.remove(); document.documentElement.style.overflow = ''; document.removeEventListener('keydown', key, true); };
      const key = e => { if (e.key === 'Escape') close(); };
      document.addEventListener('keydown', key, true);
      root.querySelector('.x').onclick = close;
      requestAnimationFrame(() => root.querySelector('.w').classList.add('on'));
      return 'opened';
    })()
    """
}
