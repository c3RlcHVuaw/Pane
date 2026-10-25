import Foundation

public struct QuickAnswer: Equatable, Sendable {
    public var title: String     // the result, big
    public var detail: String    // what was asked
    public var symbol: String
    public init(title: String, detail: String, symbol: String) { self.title = title; self.detail = detail; self.symbol = symbol }
}

/// Answers typed straight into the address bar: arithmetic and currency conversion.
public enum QuickAnswers {
    // MARK: Calculator

    /// Evaluates `+ - * / ^ %` with brackets. Nil unless the text really is an expression with an operator.
    public static func calculate(_ text: String) -> Double? {
        let t = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "=", with: "")
        guard !t.isEmpty, t.contains(where: \.isNumber), t.contains(where: { "+-*/^%".contains($0) }) || t.contains("("),
              t.allSatisfy({ $0.isNumber || "+-*/^%.()".contains($0) }), !t.contains(where: \.isLetter),
              t.filter({ $0 == "." }).count < 12, t.split(whereSeparator: { "+-*/^%()".contains($0) }).allSatisfy({ $0.filter { $0 == "." }.count <= 1 }) else { return nil }
        var p = Parser(Array(t))
        guard let v = p.expression(), p.atEnd, v.isFinite else { return nil }
        // "1.2.3.4"-style or a bare number with a sign is not a calculation worth showing.
        if Double(t) != nil { return nil }
        return v
    }

    private struct Parser {
        let c: [Character]; var i = 0
        init(_ c: [Character]) { self.c = c }
        var atEnd: Bool { i >= c.count }
        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while i < c.count, c[i] == "+" || c[i] == "-" {
                let op = c[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while i < c.count, c[i] == "*" || c[i] == "/" || c[i] == "%" {
                let op = c[i]; i += 1
                guard let r = power() else { return nil }
                switch op { case "*": v *= r; case "/": if r == 0 { return nil }; v /= r; default: if r == 0 { return nil }; v = v.truncatingRemainder(dividingBy: r) }
            }
            return v
        }
        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if i < c.count, c[i] == "^" { i += 1; guard let e = power() else { return nil }; return pow(b, e) }
            return b
        }
        mutating func unary() -> Double? {
            if i < c.count, c[i] == "-" { i += 1; return unary().map { -$0 } }
            if i < c.count, c[i] == "+" { i += 1; return unary() }
            if i < c.count, c[i] == "(" {
                i += 1
                guard let v = expression(), i < c.count, c[i] == ")" else { return nil }
                i += 1; return v
            }
            let start = i
            while i < c.count, c[i].isNumber || c[i] == "." { i += 1 }
            return i > start ? Double(String(c[start..<i])) : nil
        }
    }

    public static func format(_ v: Double, maxFraction: Int = 6) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.maximumFractionDigits = maxFraction; f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    // MARK: Currency

    static let aliases: [String: String] = [
        "usd": "USD", "$": "USD", "dollar": "USD", "dollars": "USD", "доллар": "USD", "доллара": "USD", "долларов": "USD", "баксов": "USD",
        "eur": "EUR", "€": "EUR", "euro": "EUR", "euros": "EUR", "евро": "EUR",
        "rub": "RUB", "₽": "RUB", "руб": "RUB", "рублей": "RUB", "рубль": "RUB", "рубля": "RUB", "ruble": "RUB", "rubles": "RUB", "р": "RUB",
        "gbp": "GBP", "£": "GBP", "pound": "GBP", "pounds": "GBP", "фунт": "GBP", "фунтов": "GBP",
        "jpy": "JPY", "¥": "JPY", "yen": "JPY", "иена": "JPY", "иен": "JPY",
        "cny": "CNY", "yuan": "CNY", "юань": "CNY", "юаней": "CNY", "юаня": "CNY",
        "kzt": "KZT", "тенге": "KZT", "uah": "UAH", "гривна": "UAH", "гривен": "UAH", "byn": "BYN", "try": "TRY", "лира": "TRY", "лир": "TRY",
        "gel": "GEL", "лари": "GEL", "amd": "AMD", "драм": "AMD", "драмов": "AMD", "aed": "AED", "дирхам": "AED", "дирхамов": "AED",
        "chf": "CHF", "франк": "CHF", "франков": "CHF", "pln": "PLN", "злотый": "PLN", "злотых": "PLN", "inr": "INR", "рупия": "INR", "рупий": "INR",
        "krw": "KRW", "cad": "CAD", "aud": "AUD", "thb": "THB", "бат": "THB", "бат\u{430}": "THB", "uzs": "UZS", "сум": "UZS", "azn": "AZN", "манат": "AZN",
    ]

    /// "100 usd in rub", "50 евро в рублях" -> (100, USD, RUB)
    public static func parseConversion(_ text: String) -> (amount: Double, from: String, to: String)? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d+(?:[.,]\d+)?)\s*([a-zа-я$€₽£¥]+)\s*(?:in|to|into|в|на|->|=|→)\s*([a-zа-я$€₽£¥]+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), m.numberOfRanges == 4 else { return nil }
        func g(_ i: Int) -> String { Range(m.range(at: i), in: t).map { String(t[$0]) } ?? "" }
        guard let amount = Double(g(1).replacingOccurrences(of: ",", with: ".")) else { return nil }
        func code(_ s: String) -> String? {
            if let c = aliases[s] { return c }
            if s.count == 3, s.allSatisfy({ $0.isASCII }) { return s.uppercased() }
            // Russian endings: "рублях", "евро", "долларах" share their first letters with a known form.
            if s.count >= 4 { return aliases.first { $0.key.count >= 4 && s.hasPrefix(String($0.key.prefix(4))) }?.value }
            return nil
        }
        guard let from = code(g(2)), let to = code(g(3)), from != to else { return nil }
        return (amount, from, to)
    }

    nonisolated(unsafe) private static var cache: (date: Date, rates: [String: Double])?

    /// Rates against USD, cached for six hours. Only the currency code of the cache is requested; nothing about the user is sent.
    public static func rates() async -> [String: Double]? {
        if let c = cache, Date().timeIntervalSince(c.date) < 6 * 3600 { return c.rates }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD"),
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 6)),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let r = o["rates"] as? [String: Double] else { return cache?.rates }
        cache = (Date(), r)
        return r
    }

    public static func convert(_ amount: Double, from: String, to: String, rates: [String: Double]) -> Double? {
        guard let a = rates[from], let b = rates[to], a > 0 else { return nil }
        return amount / a * b
    }

    /// The answer for whatever was typed, or nil.
    public static func answer(for text: String) async -> QuickAnswer? {
        let q = text.trimmingCharacters(in: .whitespaces)
        if let v = calculate(q) { return QuickAnswer(title: format(v), detail: q, symbol: "equal.circle.fill") }
        if let c = parseConversion(q), let r = await rates(), let v = convert(c.amount, from: c.from, to: c.to, rates: r) {
            return QuickAnswer(title: "\(format(v, maxFraction: 2)) \(c.to)", detail: "\(format(c.amount, maxFraction: 2)) \(c.from)", symbol: "arrow.left.arrow.right.circle.fill")
        }
        return nil
    }

    /// Cheap check before any network: could this be a conversion?
    public static func looksLikeAnswerable(_ text: String) -> Bool { calculate(text) != nil || parseConversion(text) != nil }
}
