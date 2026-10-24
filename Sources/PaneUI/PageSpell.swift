import AppKit

/// Spell checking for text fields, done with the system's spell checker (the web engine has none built in).
/// It looks at the word under the caret when a field's context menu opens.
@MainActor
enum PageSpell {
    struct Word {
        var text: String, start: Int, end: Int, kind: String
        var suggestions: [String]
    }

    static let probeScript = """
    (function(){var e=document.activeElement;if(!e)return '';var t,s,en,kind;
    if(e.tagName==='INPUT'||e.tagName==='TEXTAREA'){try{t=e.value;s=e.selectionStart;en=e.selectionEnd}catch(x){return ''}kind='f'}
    else if(e.isContentEditable){var sel=getSelection();if(!sel.rangeCount)return '';var r=sel.getRangeAt(0);var n=r.startContainer;if(n.nodeType!==3)return '';t=n.textContent;s=r.startOffset;en=r.endOffset;kind='c'}
    else return '';
    if(s==null||t==null)return '';
    var re=/[\\p{L}\\p{M}'\\u2019-]/u,a=s,b=en;
    if(s===en){while(a>0&&re.test(t[a-1]))a--;while(b<t.length&&re.test(t[b]))b++}
    var w=t.slice(a,b);if(!w||w.length>40||/[\\s\\d]/.test(w))return '';
    return JSON.stringify({word:w,start:a,end:b,kind:kind})})()
    """

    static func replaceScript(_ w: Word, with rep: String) -> String {
        func lit(_ s: String) -> String { (try? JSONSerialization.data(withJSONObject: [s])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\"" }
        return """
        (function(){var e=document.activeElement,w=\(lit(w.text)),a=\(w.start),b=\(w.end),rep=\(lit(rep));
        if(\(w.kind == "f" ? "true" : "false")){if(!e||e.value.slice(a,b)!==w)return 0;e.focus();e.setSelectionRange(a,b);
         if(!document.execCommand('insertText',false,rep)){e.setRangeText(rep,a,b,'end');e.dispatchEvent(new Event('input',{bubbles:true}))}return 1}
        var sel=getSelection();if(!sel.rangeCount)return 0;var n=sel.getRangeAt(0).startContainer;if(n.nodeType!==3||n.textContent.slice(a,b)!==w)return 0;
        var r=document.createRange();r.setStart(n,a);r.setEnd(n,b);sel.removeAllRanges();sel.addRange(r);document.execCommand('insertText',false,rep);return 1})()
        """
    }

    /// Pulls the JSON the probe returned out of the DevTools reply.
    static func parse(reply: String?) -> (text: String, start: Int, end: Int, kind: String)? {
        guard let reply, let d = reply.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let value = (o["result"] as? [String: Any])?["value"] as? String, !value.isEmpty,
              let j = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any],
              let w = j["word"] as? String, let s = j["start"] as? Int, let e = j["end"] as? Int, let k = j["kind"] as? String else { return nil }
        return (w, s, e, k)
    }

    /// Languages to try for a word, by its script.
    private static func languages(for word: String) -> [String] {
        let cyr = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let available = NSSpellChecker.shared.availableLanguages
        let wanted = cyr ? ["ru"] : (Array(NSSpellChecker.shared.userPreferredLanguages.filter { $0.hasPrefix("en") }.prefix(1)) + ["en"])
        var out: [String] = []
        for w in wanted { if let m = available.first(where: { $0 == w || $0.hasPrefix(w + "_") || $0.hasPrefix(w + "-") }), !out.contains(m) { out.append(m) } }
        return out
    }

    /// Nil when the word is fine (or can't be judged); otherwise the corrections.
    static func check(_ word: String) -> [String]? {
        let sc = NSSpellChecker.shared
        let langs = languages(for: word)
        guard !langs.isEmpty, word.count > 1 else { return nil }
        for l in langs {
            if sc.checkSpelling(of: word, startingAt: 0, language: l, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound { return nil }
        }
        let l = langs[0]
        return sc.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: l, inSpellDocumentWithTag: 0) ?? []
    }

    static func learn(_ word: String) { NSSpellChecker.shared.learnWord(word) }
}
