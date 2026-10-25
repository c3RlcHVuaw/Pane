import Foundation

/// Red wavy underlines for misspelled words in text fields. The page lists its words, Pane checks them with the system
/// spell checker and answers with the wrong ones; fields get a transparent mirror layer, rich editors use the highlight API.
public enum SpellScript {
    public static let script = """
    (() => {
      if (window.__paneSpell) return;
      Object.defineProperty(window, '__paneSpell', { value: true });
      const wordRe = /[\\p{L}\\p{M}'\\u2019-]{2,40}/gu;
      const overlays = new WeakMap();
      let seq = 0, pending = null, timer = null, current = null, bad = new Set();
      const style = document.createElement('style');
      style.textContent = '::highlight(pane-spell){text-decoration:underline wavy #e5484d;text-decoration-thickness:1px;text-underline-offset:2px}';
      const addStyle = () => { (document.head || document.documentElement).appendChild(style); };
      if (document.documentElement) addStyle(); else document.addEventListener('DOMContentLoaded', addStyle);
      const isField = e => e && (e.tagName === 'TEXTAREA' || (e.tagName === 'INPUT' && /^(text|search|email|)$/.test(e.type)));
      const target = () => { const e = document.activeElement; if (!e || e.spellcheck === false) return null; if (isField(e) || e.isContentEditable) return e; return null; };
      const textOf = e => e.isContentEditable ? e.innerText : e.value;
      const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
      function schedule() { clearTimeout(timer); timer = setTimeout(run, 450); }
      function run() {
        const el = target();
        if (!el) { clearAll(); return; }
        const words = [...new Set((textOf(el).match(wordRe) || []).slice(0, 300))];
        current = el;
        if (!words.length) { bad = new Set(); paint(); return; }
        const id = ++seq; pending = id;
        console.log('__pane-notif:' + JSON.stringify({ k: 'spell', id, words }));
      }
      window.__paneSpellApply = (id, list) => { if (id !== pending) return; bad = new Set(list); paint(); };
      function clearAll() { if (CSS.highlights) CSS.highlights.delete('pane-spell'); const o = current && overlays.get(current); if (o) o.remove(); current = null; bad = new Set(); }
      function paint() {
        const el = current; if (!el) return;
        if (el.isContentEditable) {
          if (!CSS.highlights) return;
          const ranges = [], walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
          for (let n; (n = walker.nextNode());) {
            const t = n.textContent; wordRe.lastIndex = 0;
            for (let m; (m = wordRe.exec(t));) if (bad.has(m[0])) { const r = new Range(); r.setStart(n, m.index); r.setEnd(n, m.index + m[0].length); ranges.push(r); }
          }
          CSS.highlights.set('pane-spell', new Highlight(...ranges));
          return;
        }
        let o = overlays.get(el);
        if (!o) { o = document.createElement('div'); o.setAttribute('aria-hidden', 'true'); overlays.set(el, o); }
        if (!bad.size) { o.remove(); return; }
        const text = el.value, cs = getComputedStyle(el), r = el.getBoundingClientRect();
        let html = '', last = 0; wordRe.lastIndex = 0;
        for (let m; (m = wordRe.exec(text));) {
          if (!bad.has(m[0])) continue;
          html += esc(text.slice(last, m.index)) + '<span style="text-decoration:underline wavy #e5484d;text-decoration-thickness:1px;text-underline-offset:2px">' + esc(m[0]) + '</span>';
          last = m.index + m[0].length;
        }
        html += esc(text.slice(last)) + (text.endsWith('\\n') ? ' ' : '');
        o.innerHTML = html;
        const sb = el.offsetWidth - el.clientWidth - parseFloat(cs.borderLeftWidth) - parseFloat(cs.borderRightWidth);
        o.style.cssText = 'position:fixed;pointer-events:none;overflow:hidden;color:transparent;z-index:2147483646;background:none;margin:0;' +
          'white-space:' + (el.tagName === 'INPUT' ? 'pre' : 'pre-wrap') + ';word-wrap:break-word;left:' + r.left + 'px;top:' + r.top + 'px;width:' + r.width + 'px;height:' + r.height + 'px;' +
          ['fontFamily','fontSize','fontWeight','fontStyle','letterSpacing','lineHeight','textTransform','textIndent','paddingTop','paddingBottom','paddingLeft','borderTopWidth','borderBottomWidth','borderLeftWidth','borderRightWidth','textAlign','tabSize']
            .map(p => p.replace(/[A-Z]/g, c => '-' + c.toLowerCase()) + ':' + cs[p]).join(';') + ';border-style:solid;border-color:transparent;box-sizing:' + cs.boxSizing + ';padding-right:' + (parseFloat(cs.paddingRight) + Math.max(0, sb)) + 'px';
        if (!o.isConnected) document.documentElement.appendChild(o);
        o.scrollTop = el.scrollTop; o.scrollLeft = el.scrollLeft;
      }
      addEventListener('input', schedule, true);
      addEventListener('focusin', schedule, true);
      addEventListener('focusout', () => setTimeout(() => { if (!target()) clearAll(); }, 50), true);
      addEventListener('scroll', () => { if (current && !current.isContentEditable) paint(); }, true);
      addEventListener('resize', () => { if (current && !current.isContentEditable) paint(); });
    })();
    """
}
