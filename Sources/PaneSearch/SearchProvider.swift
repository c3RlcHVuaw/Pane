import Foundation
import NaturalLanguage
import PaneModel

public final class DefaultSearchProvider: SearchProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var embeddings: [NLLanguage: NLEmbedding?] = [:]
    private var vectorCache: [String: [[Double]]] = [:]

    public init() {}

    // MARK: Keyword

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
    static func words(_ s: String) -> [String] {
        fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    /// A light Russian stemmer: drops common case/number endings so "курсов", "курсы" and "курс" meet.
    /// Words that aren't Cyrillic, or are short, are left alone. (Folding has already turned й into и and ё into е.)
    static func stem(_ w: String) -> String {
        guard w.count >= 5,
              w.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) else { return w }
        for e in ["ями", "ами", "ого", "его", "ому", "ему", "ыми", "ими", "ть", "ая", "яя", "ое", "ее", "ые", "ие", "ой", "ей", "ов", "ев", "ах", "ях", "ом", "ем", "ую", "юю", "ам", "ям", "ы", "и", "а", "я", "у", "ю", "е", "о", "ь"] where w.hasSuffix(e) && w.count - e.count >= 3 {
            return String(w.dropLast(e.count))
        }
        return w
    }
    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle { var found = false; while let h = it.next() { if h == c { found = true; break } }; if !found { return false } }
        return true
    }

    public func keywordSearch(_ query: String, in items: [SearchItem], limit: Int) -> [SearchHit] {
        let tokens = Self.words(query).map(Self.stem)
        guard !tokens.isEmpty else { return [] }
        let now = Date()
        var best: [String: SearchHit] = [:]  // by normalized URL
        for item in items {
            guard let s = score(tokens, item, now: now) else { continue }
            let key = normalizedURL(item.url)
            if let existing = best[key], existing.item.kind.rawValue <= item.kind.rawValue, existing.score >= s { continue }
            if let existing = best[key], existing.item.kind.rawValue < item.kind.rawValue { continue }  // keep the open tab over its bookmark
            best[key] = SearchHit(item: item, score: s)
        }
        return Array(best.values.sorted { $0.score > $1.score }.prefix(limit))
    }

    private func score(_ tokens: [String], _ item: SearchItem, now: Date) -> Double? {
        let title = Self.fold(item.title), host = Self.fold(item.host), url = Self.fold(item.url)
        let titleWords = Self.words(item.title).map(Self.stem)
        let detail = item.detail.isEmpty ? "" : Self.fold(item.detail)
        var total = 0.0
        for t in tokens {
            if let i = titleWords.firstIndex(where: { $0.hasPrefix(t) }) { total += i == 0 ? 3.5 : 3.0 }
            else if host.contains(t) { total += 2.4 }
            else if title.contains(t) { total += 2.0 }
            else if url.contains(t) { total += 1.0 }
            else if !detail.isEmpty, detail.contains(t) { total += 1.4 }
            else if t.count >= 3, Self.isSubsequence(t, of: title) { total += 0.6 }
            else { return nil }
        }
        var s = total / Double(tokens.count)
        if title.hasPrefix(tokens.joined(separator: " ")) { s += 1.5 }
        switch item.kind {
        case .tab:
            s += 1.2
            if let d = item.lastUsed { s += 0.5 * exp(-now.timeIntervalSince(d) / 3600 / 6) }
        case .note:
            s += 1.6
        case .bookmark:
            s += 0.7
        case .history:
            s += 0.3 + 0.15 * log1p(Double(item.visits))
            if let d = item.lastUsed { s += 0.4 * exp(-now.timeIntervalSince(d) / 86400 / 14) }
        }
        return s
    }

    // MARK: Meaning (word-embedding soft match)

    private func embedding(for language: NLLanguage) -> NLEmbedding? {
        lock.lock(); defer { lock.unlock() }
        if let cached = embeddings[language] { return cached }
        let e = NLEmbedding.wordEmbedding(for: language)
        embeddings[language] = .some(e)
        return e
    }

    /// Whether meaning-based search can handle this query's language on this Mac.
    public func supportsMeaning(for query: String) -> Bool { language(of: query) != nil }

    private func language(of query: String) -> NLLanguage? {
        let r = NLLanguageRecognizer()
        r.processString(query)
        // Short queries are ambiguous, so look at the best few guesses rather than only the top one.
        for (lang, p) in r.languageHypotheses(withMaximum: 4).sorted(by: { $0.value > $1.value }) where p > 0.15 {
            if embedding(for: lang) != nil { return lang }
        }
        // Plain Latin text with no supported guess: assume English.
        if query.unicodeScalars.allSatisfy({ $0.isASCII }), embedding(for: .english) != nil { return .english }
        return nil
    }

    private func vectors(_ text: String, _ e: NLEmbedding, _ lang: NLLanguage) -> [[Double]] {
        let key = lang.rawValue + "|" + text
        lock.lock(); if let c = vectorCache[key] { lock.unlock(); return c }; lock.unlock()
        let v = Self.words(text).filter { $0.count > 2 }.compactMap { e.vector(for: $0) }
        lock.lock(); vectorCache[key] = v; lock.unlock()
        return v
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var d = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return d / ((na * nb).squareRoot() + 1e-9)
    }

    public func semanticSearch(_ query: String, in items: [SearchItem], limit: Int) async -> [SearchHit] {
        guard let lang = language(of: query), let e = embedding(for: lang) else { return [] }
        let q = vectors(query, e, lang)
        guard !q.isEmpty else { return [] }
        var hits: [String: SearchHit] = [:]
        for item in items {
            if Task.isCancelled { return [] }
            let t = vectors(item.title + " " + item.host + " " + String(item.detail.prefix(240)), e, lang)
            guard !t.isEmpty else { continue }
            // Each query word is matched with its closest word in the page title.
            let s = q.map { qv in t.map { Self.cosine(qv, $0) }.max() ?? 0 }.reduce(0, +) / Double(q.count)
            guard s >= 0.45 else { continue }
            let key = normalizedURL(item.url)
            if let ex = hits[key], ex.item.kind.rawValue <= item.kind.rawValue { continue }
            hits[key] = SearchHit(item: item, score: s, viaMeaning: true)
        }
        return Array(hits.values.sorted { $0.score > $1.score }.prefix(limit))
    }
}
