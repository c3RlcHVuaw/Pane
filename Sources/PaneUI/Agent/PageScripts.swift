import Foundation

/// JavaScript the agent runs inside pages (through the DevTools protocol). Kept in one place so it can be read as a whole.
enum PageScripts {
    /// Numbers every visible interactive element and returns a JSON snapshot of the page.
    static let state = #"""
    (() => {
      const MAX = 120;
      const visible = (el) => {
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity) > 0.05
          && r.bottom > 0 && r.top < innerHeight * 3 && r.right > 0 && r.left < innerWidth;
      };
      document.querySelectorAll('[data-pane-ref]').forEach(e => e.removeAttribute('data-pane-ref'));
      const sel = 'a[href],button,input:not([type=hidden]),select,textarea,[role=button],[role=link],[role=menuitem],[role=tab],[role=checkbox],[role=radio],[role=switch],[role=option],summary,[contenteditable=""],[contenteditable="true"],[onclick]';
      const out = []; let n = 0;
      for (const el of document.querySelectorAll(sel)) {
        if (n >= MAX) break;
        if (!visible(el)) continue;
        n++; el.setAttribute('data-pane-ref', String(n));
        const tag = el.tagName.toLowerCase();
        const type = (el.getAttribute('type') || '').toLowerCase();
        const label = (el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].innerText) || el.getAttribute('placeholder')
          || el.getAttribute('title') || el.innerText || el.getAttribute('value') || el.getAttribute('alt') || '').trim().replace(/\s+/g, ' ').slice(0, 80);
        const hint = ((el.getAttribute('name') || '') + ' ' + (el.id || '') + ' ' + (el.getAttribute('autocomplete') || '')).toLowerCase();
        const item = { ref: n, tag, label };
        if (type) item.type = type;
        if (tag === 'a') item.href = (el.href || '').slice(0, 140);
        if (['input', 'textarea', 'select'].includes(tag) && type !== 'password') item.value = String(el.value || '').slice(0, 60);
        if (type === 'checkbox' || type === 'radio') item.checked = !!el.checked;
        if (el.disabled) item.disabled = true;
        if (tag === 'select') item.options = [...el.options].slice(0, 15).map(o => o.text.trim().slice(0, 40));
        const secret = type === 'password' || /(^|[^a-z])(password|passwd|pwd|cvv|cvc|cardnumber|card-number|ccnum|cc-number|cc-csc|one-time-code|otp|2fa)([^a-z]|$)/.test(hint);
        if (secret) item.secret = true;
        const inForm = !!el.closest('form');
        if (type === 'submit' || (tag === 'button' && type !== 'button' && type !== 'reset' && inForm)) item.submit = true;
        out.push(item);
      }
      const text = (document.body ? document.body.innerText : '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim().slice(0, 5000);
      return JSON.stringify({ url: location.href, title: document.title, scrollY: Math.round(scrollY),
        height: document.documentElement.scrollHeight, viewport: innerHeight, elements: out, text, more: n >= MAX });
    })()
    """#

    /// Scrolls the numbered element into view and reports where it is (CSS pixels, relative to the viewport).
    static func locate(_ ref: Int) -> String { #"""
    ((ref) => {
      const el = document.querySelector('[data-pane-ref="' + ref + '"]');
      if (!el) return JSON.stringify({ error: 'There is no element with that number now. Call get_page_state again.' });
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect();
      return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2, left: r.left, top: r.top, w: r.width, h: r.height, innerWidth: innerWidth });
    })(\#(ref))
    """# }

    /// Focuses a field and selects its content so the next insertion replaces it.
    static func focus(_ ref: Int, clear: Bool) -> String { #"""
    ((ref, clear) => {
      const el = document.querySelector('[data-pane-ref="' + ref + '"]');
      if (!el) return 'missing';
      el.focus();
      if (clear) {
        if (el.select) el.select();
        else if (el.isContentEditable) { const r = document.createRange(); r.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
      } else if (el.setSelectionRange && typeof el.value === 'string') { el.setSelectionRange(el.value.length, el.value.length); }
      return 'ok';
    })(\#(ref), \#(clear))
    """# }

    static func selectOption(_ ref: Int, _ option: String) -> String {
        let quoted = (try? JSONSerialization.data(withJSONObject: [option]))
            .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return #"""
        ((ref, want) => {
          const el = document.querySelector('[data-pane-ref="' + ref + '"]');
          if (!el || el.tagName.toLowerCase() !== 'select') return 'not a select';
          const w = want.trim().toLowerCase();
          const o = [...el.options].find(o => o.text.trim().toLowerCase() === w || o.value.toLowerCase() === w)
            || [...el.options].find(o => o.text.trim().toLowerCase().includes(w));
          if (!o) return 'no such option';
          el.value = o.value;
          el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok:' + o.text.trim();
        })(\#(ref), \#(quoted))
        """#
    }

    static func scroll(_ direction: String) -> String { #"""
    ((d) => {
      const h = innerHeight * 0.85;
      if (d === 'top') scrollTo({ top: 0, behavior: 'smooth' });
      else if (d === 'bottom') scrollTo({ top: document.documentElement.scrollHeight, behavior: 'smooth' });
      else scrollBy({ top: d === 'up' ? -h : h, behavior: 'smooth' });
      return JSON.stringify({ y: Math.round(scrollY), height: document.documentElement.scrollHeight, viewport: innerHeight });
    })('\#(direction)')
    """# }
}
