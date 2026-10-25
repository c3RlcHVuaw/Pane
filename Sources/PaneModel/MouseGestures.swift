import Foundation

/// Hold ⌥ and drag with the left button: ← back, → forward, ↓ new tab, ↓→ close tab, ↑↓ reload, ↓← reopen closed tab, ↑ to top.
public enum MouseGestures {
    public static let script = """
    (() => {
      if (window.__paneGest) return;
      Object.defineProperty(window, '__paneGest', { value: true });
      let tracking = false, x = 0, y = 0, path = '', done = 0;
      addEventListener('mousedown', e => {
        if (e.button === 0 && e.altKey) { tracking = true; x = e.clientX; y = e.clientY; path = ''; e.preventDefault(); }
      }, true);
      addEventListener('mousemove', e => {
        if (!tracking || !(e.buttons & 1)) return;
        const dx = e.clientX - x, dy = e.clientY - y;
        if (Math.abs(dx) < 28 && Math.abs(dy) < 28) return;
        const d = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 'R' : 'L') : (dy > 0 ? 'D' : 'U');
        if (path.slice(-1) !== d && path.length < 3) path += d;
        x = e.clientX; y = e.clientY;
      }, true);
      addEventListener('mouseup', e => {
        if (e.button !== 0 || !tracking) return;
        tracking = false;
        if (path) { done = Date.now(); console.log('__pane-notif:' + JSON.stringify({ k: 'gesture', d: path })); }
      }, true);
      addEventListener('click', e => { if (done && Date.now() - done < 400) { e.preventDefault(); e.stopPropagation(); } }, true);
    })();
    """

    public enum Action: Equatable, Sendable { case back, forward, newTab, closeTab, reload, reopen, top }

    public static func action(for path: String) -> Action? {
        switch path {
        case "L": .back
        case "R": .forward
        case "D": .newTab
        case "DR": .closeTab
        case "UD": .reload
        case "DL": .reopen
        case "U": .top
        default: nil
        }
    }
}
