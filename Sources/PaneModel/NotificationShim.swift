import Foundation

/// Web notifications. Chromium's embedded engine has no notification centre, so Pane gives pages its own `Notification`
/// that hands the message to macOS. It works for pages that are open (a chat or mail tab), not for push messages to closed ones.
public enum NotificationShim {
    /// The decisions per site: ["https://mail.example.com": "granted" | "denied"].
    public static func script(decisions: [String: String]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: decisions)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (() => {
          window.__paneNotifDecisions = \(json);
          if (window.__paneNotif) return;
          Object.defineProperty(window, '__paneNotif', { value: true });
          const log = console.debug.bind(console);
          const send = (k, d) => log('__pane-notif:' + JSON.stringify(Object.assign({ k }, d)));
          const perm = () => (window.__paneNotifDecisions || {})[location.origin] || 'default';
          class PaneNotification extends EventTarget {
            constructor(title, opts) {
              super(); opts = opts || {};
              this.title = String(title); this.body = opts.body || ''; this.tag = opts.tag || ''; this.icon = opts.icon || ''; this.data = opts.data;
              if (perm() === 'granted') send('show', { title: this.title, body: this.body, tag: this.tag, icon: this.icon });
              setTimeout(() => { const e = new Event(perm() === 'granted' ? 'show' : 'error'); (perm() === 'granted' ? this.onshow : this.onerror) && (perm() === 'granted' ? this.onshow : this.onerror)(e); this.dispatchEvent(e); }, 0);
            }
            close() { send('close', { tag: this.tag }); }
            static get permission() { return perm(); }
            static get maxActions() { return 0; }
            static requestPermission(cb) {
              return new Promise(resolve => {
                const finish = p => { const d = window.__paneNotifDecisions = window.__paneNotifDecisions || {}; d[location.origin] = p; if (cb) cb(p); resolve(p); };
                if (perm() !== 'default') return finish(perm());
                window.__paneNotifAnswer = finish;
                send('ask', {});
              });
            }
          }
          Object.defineProperty(window, 'Notification', { value: PaneNotification, configurable: true, writable: true });
          if (window.ServiceWorkerRegistration) {
            ServiceWorkerRegistration.prototype.showNotification = function (title, opts) { new PaneNotification(title, opts); return Promise.resolve(); };
          }
        })()
        """
    }
}
