import Foundation

public struct AddressProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var label = ""
    public var fullName = ""
    public var organization = ""
    public var email = ""
    public var phone = ""
    public var street = ""
    public var street2 = ""
    public var city = ""
    public var region = ""
    public var postalCode = ""
    public var country = ""
    public init() {}

    public var title: String {
        if !label.isEmpty { return label }
        let t = [fullName, street].filter { !$0.isEmpty }.joined(separator: ", ")
        return t.isEmpty ? tr("Address") : t
    }
    public var isEmpty: Bool { [fullName, organization, email, phone, street, street2, city, region, postalCode, country].allSatisfy(\.isEmpty) }
}

/// What is kept about a card in the clear: never the number itself (that lives in the Keychain).
public struct CardProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var holder = ""
    public var last4 = ""
    public var expMonth = ""
    public var expYear = ""
    public var brand = ""
    public init() {}
    public var title: String { "\(brand.isEmpty ? tr("Card") : brand) •••• \(last4)" }
}

@MainActor
public final class AutofillStore: ObservableObject {
    public static let shared = AutofillStore()
    @Published public private(set) var addresses: [AddressProfile] = []
    @Published public private(set) var cards: [CardProfile] = []
    private var file: URL?

    private struct Disk: Codable { var addresses: [AddressProfile]; var cards: [CardProfile] }

    public func configure(file: URL) {
        self.file = file
        if let d = try? Data(contentsOf: file), let disk = try? JSONDecoder().decode(Disk.self, from: d) { addresses = disk.addresses; cards = disk.cards }
    }

    private func save() {
        guard let file, let d = try? JSONEncoder().encode(Disk(addresses: addresses, cards: cards)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
    }

    public func upsert(_ a: AddressProfile) {
        if let i = addresses.firstIndex(where: { $0.id == a.id }) { addresses[i] = a } else { addresses.append(a) }
        save()
    }
    public func removeAddress(_ id: UUID) { addresses.removeAll { $0.id == id }; save() }

    public static func secret(for id: UUID) -> KeychainSecretStore { KeychainSecretStore(service: "com.pane.browser.cards", account: id.uuidString) }

    /// Adds a card; the number goes to the Keychain and only its last four digits stay in the list.
    @discardableResult
    public func addCard(number: String, holder: String, expMonth: String, expYear: String) -> CardProfile? {
        let digits = number.filter(\.isNumber)
        guard digits.count >= 12, digits.count <= 19 else { return nil }
        var c = CardProfile()
        c.holder = holder; c.expMonth = expMonth; c.expYear = expYear; c.last4 = String(digits.suffix(4)); c.brand = Self.brand(digits)
        Self.secret(for: c.id).save(digits)
        cards.append(c); save()
        return c
    }
    public func removeCard(_ id: UUID) { Self.secret(for: id).clear(); cards.removeAll { $0.id == id }; save() }

    public static func brand(_ d: String) -> String {
        if d.hasPrefix("4") { return "Visa" }
        if let p = Int(d.prefix(2)), (51...55).contains(p) { return "Mastercard" }
        if let p = Int(d.prefix(4)), (2221...2720).contains(p) { return "Mastercard" }
        if d.hasPrefix("34") || d.hasPrefix("37") { return "Amex" }
        if let p = Int(d.prefix(4)), (2200...2204).contains(p) { return "Мир" }
        if d.hasPrefix("62") { return "UnionPay" }
        return ""
    }
}

/// Page script that fills the form around the focused field.
public enum AutofillScripts {
    public static func address(_ a: AddressProfile) -> String {
        let parts = a.fullName.split(separator: " ", maxSplits: 1).map(String.init)
        let values: [String: String] = [
            "name": a.fullName, "given": parts.first ?? "", "family": parts.count > 1 ? parts[1] : "", "org": a.organization,
            "email": a.email, "tel": a.phone, "street": [a.street, a.street2].filter { !$0.isEmpty }.joined(separator: ", "),
            "line1": a.street, "line2": a.street2, "city": a.city, "region": a.region, "zip": a.postalCode, "country": a.country,
        ]
        return script(values)
    }

    public static func card(number: String, holder: String, month: String, year: String) -> String {
        let yy = year.count == 4 ? String(year.suffix(2)) : year
        let yyyy = year.count == 2 ? "20" + year : year
        let values: [String: String] = [
            "ccnumber": number, "ccname": holder, "ccmonth": month, "ccyear": yyyy, "ccyear2": yy,
            "ccexp": "\(month)/\(yy)", "ccexp4": "\(month)/\(yyyy)",
        ]
        return script(values)
    }

    private static func script(_ values: [String: String]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: values)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "(function(){var V=\(json);\(body)})()"
    }

    // field classification: autocomplete token first, then name/id/placeholder/label text
    private static let body = """
    var rules=[
     ['ccnumber',/^cc-number$/,/card.?n(um|o)|cardnumber|ccnum|номер.?карт/i],
     ['ccname',/^cc-name$/,/card.?holder|name.?on.?card|cc.?name|владел/i],
     ['ccmonth',/^cc-exp-month$/,/exp.*month|month.*exp|cc.?mm|expmonth/i],
     ['ccyear',/^cc-exp-year$/,/exp.*year|year.*exp|cc.?yy|expyear/i],
     ['ccexp',/^cc-exp$/,/expir|valid.?thru|exp.?date|срок/i],
     ['email',/^email$/,/e-?mail|почт/i],
     ['tel',/^tel/,/phone|mobile|tel\\b|телефон/i],
     ['given',/^given-name$/,/first.?name|given|(^|[^a-z])fname|^имя/i],
     ['family',/^family-name$/,/last.?name|surname|family|(^|[^a-z])lname|фамил/i],
     ['name',/(^|\\s)name(\\s|$)/,/full.?name|your.?name|^name$|\\bфио\\b|^имя и фамилия/i],
     ['org',/^organization$/,/company|organi[sz]ation|компан|организац/i],
     ['line1',/^address-line1$/,/address.?(line)?.?1|street.?address|^address$|^street|адрес|улиц/i],
     ['line2',/^address-line2$/,/address.?(line)?.?2|apartment|suite|apt|unit|квартир|офис/i],
     ['street',/^street-address$/,/^$a/],
     ['city',/^address-level2$/,/city|town|locality|город/i],
     ['region',/^address-level1$/,/state|province|region|област|регион/i],
     ['zip',/^postal-code$/,/zip|postal|post.?code|индекс/i],
     ['country',/^country(-name)?$/,/country|страна/i]
    ];
    function labelText(el){var t='';if(el.id){var l=document.querySelector('label[for="'+CSS.escape(el.id)+'"]');if(l)t+=' '+l.textContent}var p=el.closest('label');if(p)t+=' '+p.textContent;return t}
    function classify(el){
     var ac=(el.getAttribute('autocomplete')||'').toLowerCase().split(' ').pop();
     var hay=[el.name,el.id,el.placeholder,el.getAttribute('aria-label'),labelText(el)].join(' ');
     for(var i=0;i<rules.length;i++){if(ac&&rules[i][1].test(ac))return rules[i][0]}
     if(ac==='off'||ac==='on'||ac==='')for(i=0;i<rules.length;i++){if(rules[i][2].test(hay))return rules[i][0]}
     return null}
    function setValue(el,v){
     if(el.tagName==='SELECT'){
      var want=String(v).toLowerCase(),o=[].slice.call(el.options),m=o.find(function(x){return x.value.toLowerCase()===want||x.text.toLowerCase()===want})||o.find(function(x){return x.text.toLowerCase().indexOf(want)===0||(want.length>2&&x.text.toLowerCase().indexOf(want)>=0)});
      if(!m&&/^\\d+$/.test(v)){var n=parseInt(v,10);m=o.find(function(x){return parseInt(x.value,10)===n||parseInt(x.text,10)===n})}
      if(!m)return false;el.value=m.value}
     else{var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
      var d=Object.getOwnPropertyDescriptor(proto,'value');d&&d.set?d.set.call(el,v):el.value=v}
     el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return true}
    var ae=document.activeElement,scope=(ae&&ae.form)||document;
    var els=[].slice.call(scope.querySelectorAll('input,select,textarea')).filter(function(e){return e.type!=='hidden'&&e.type!=='password'&&e.type!=='submit'&&e.type!=='button'&&e.type!=='checkbox'&&e.type!=='radio'&&!e.disabled&&e.offsetParent!==null});
    var used={};
    els.forEach(function(el){
     var k=classify(el);if(!k)return;
     var v;
     if(k==='ccyear'){v=el.tagName==='SELECT'||el.maxLength===4||(el.placeholder||'').length===4?V.ccyear:V.ccyear2;if(el.maxLength===2)v=V.ccyear2}
     else if(k==='ccexp'){v=(el.maxLength===7||/yyyy/i.test(el.placeholder||''))?V.ccexp4:V.ccexp}
     else if(k==='line1'&&!V.line2&&false){v=V.street}
     else v=V[k];
     if(v==null||v===''||used[k])return;
     if(setValue(el,v))used[k]=1});
    return Object.keys(used).length;
    """
}
