import AppKit
import Foundation
import PaneEngine
import PaneModel

/// Translates the text of the current page in place with the assistant's model, a batch at a time.
/// Running it again on a translated page puts the original text back.
@MainActor
final class PageTranslator {
    private let provider: () -> LLMProvider?
    init(provider: @escaping () -> LLMProvider?) { self.provider = provider }

    private static let collect = """
    (() => {
      if (window.__paneTrOrig) { // already translated: restore
        window.__paneTrNodes.forEach((n, i) => { n.nodeValue = window.__paneTrOrig[i]; });
        window.__paneTrOrig = null; window.__paneTrNodes = null; return JSON.stringify({restored: true});
      }
      const skip = /^(SCRIPT|STYLE|NOSCRIPT|CODE|PRE|TEXTAREA|SVG)$/;
      const nodes = [], texts = [];
      const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, { acceptNode: n => {
        const p = n.parentElement;
        if (!p || skip.test(p.tagName) || p.closest('[contenteditable=true], #__pane_reader')) return NodeFilter.FILTER_REJECT;
        const t = n.nodeValue.trim();
        if (t.length < 2 || !/\\p{L}/u.test(t)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT; } });
      let total = 0;
      while (w.nextNode() && nodes.length < 700 && total < 40000) { const n = w.currentNode; nodes.push(n); texts.push(n.nodeValue); total += n.nodeValue.length; }
      window.__paneTrNodes = nodes; window.__paneTrOrig = texts.slice();
      return JSON.stringify({ texts });
    })()
    """

    private static func evaluate(_ tab: BrowserTab, _ expr: String) async -> String? {
        let p = (try? JSONSerialization.data(withJSONObject: ["expression": expr, "returnByValue": true])).flatMap { String(data: $0, encoding: .utf8) }
        guard let raw = try? await tab.devTools("Runtime.evaluate", params: p),
              let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let r = o["result"] as? [String: Any] else { return nil }
        return r["value"] as? String
    }

    enum Outcome { case translated(Int), restored, nothing, failed(String) }

    func toggle(on tab: BrowserTab, into language: String, progress: @escaping (Int, Int) -> Void) async -> Outcome {
        guard let raw = await Self.evaluate(tab, Self.collect), let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return .failed(tr("The page can't be translated.")) }
        if o["restored"] as? Bool == true { return .restored }
        guard let texts = o["texts"] as? [String], !texts.isEmpty else { return .nothing }
        guard let llm = provider() else { return .failed(tr("Add an API key in Settings → Assistant to use the agent.")) }

        // Batches of about 3,000 characters, translated one after another and shown as they arrive.
        var batches: [Range<Int>] = []
        var start = 0, size = 0
        for (i, t) in texts.enumerated() {
            if size + t.count > 3000 && i > start { batches.append(start..<i); start = i; size = 0 }
            size += t.count
        }
        batches.append(start..<texts.count)

        var done = 0
        for r in batches {
            if Task.isCancelled { break }
            let chunk = Array(texts[r])
            guard let translated = await translate(chunk, to: language, with: llm), translated.count == chunk.count else {
                if done == 0 { _ = await Self.evaluate(tab, "window.__paneTrOrig = null; window.__paneTrNodes = null; ''"); return .failed(tr("The translation didn't work. Try again.")) }
                continue
            }
            let payload = (try? JSONSerialization.data(withJSONObject: translated)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            _ = await Self.evaluate(tab, "(() => { const t = \(payload); t.forEach((s, k) => { const n = window.__paneTrNodes && window.__paneTrNodes[\(r.lowerBound) + k]; if (n) n.nodeValue = s; }); return ''; })()")
            done += chunk.count
            progress(done, texts.count)
        }
        return .translated(done)
    }

    private func translate(_ strings: [String], to language: String, with llm: LLMProvider) async -> [String]? {
        guard let input = (try? JSONSerialization.data(withJSONObject: strings)).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        let system = "You translate website text into \(language). The user sends a JSON array of strings. Reply with ONLY a JSON array of the same length and order, each string translated. Keep numbers, brand names, code, URLs and punctuation; keep leading and trailing spaces; if a string is already in \(language) or is not text, return it unchanged. No commentary, no code fences."
        var text = ""
        do { for try await chunk in llm.stream(system: system, messages: [LLMMessage(role: "user", content: input)]) { text += chunk } } catch { return nil }
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") { s = s.drop(while: { $0 != "\n" }).dropFirst().description; if let e = s.range(of: "```", options: .backwards) { s = String(s[..<e.lowerBound]) } }
        guard let d = s.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return nil }
        return arr.map { ($0 as? String) ?? "\($0)" }
    }
}
