import XCTest
@testable import PaneModel

final class ExtensionsTests: XCTestCase {
    func testWebStoreID() {
        let id = String(repeating: "a", count: 32)
        XCTAssertEqual(ExtensionStore.webStoreID(from: id), id)
        XCTAssertEqual(ExtensionStore.webStoreID(from: "https://chromewebstore.google.com/detail/name/\(id)?hl=ru"), id)
        XCTAssertNil(ExtensionStore.webStoreID(from: "https://evil.example/\(id)"))
        XCTAssertNil(ExtensionStore.webStoreID(from: "hello"))
    }

    func testCRXHeaders() {
        let zip = Data("PK-zip".utf8)
        var v3 = Data("Cr24".utf8); v3 += [3, 0, 0, 0, 2, 0, 0, 0, 9, 9]; v3 += zip
        XCTAssertEqual(ExtensionStore.zipPayload(ofCRX: v3), zip)
        var v2 = Data("Cr24".utf8); v2 += [2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 7, 8, 9]; v2 += zip
        XCTAssertEqual(ExtensionStore.zipPayload(ofCRX: v2), zip)
        XCTAssertNil(ExtensionStore.zipPayload(ofCRX: Data("nope".utf8 + Array(repeating: 0, count: 20))))
    }
}

final class QuickAnswerTests: XCTestCase {
    func testCalculator() {
        XCTAssertEqual(QuickAnswers.calculate("2+2*3"), 8)
        XCTAssertEqual(QuickAnswers.calculate("(1+2)*3,5"), 10.5)
        XCTAssertEqual(QuickAnswers.calculate("2^10"), 1024)
        XCTAssertNil(QuickAnswers.calculate("1/0"))
        XCTAssertNil(QuickAnswers.calculate("12345"))
        XCTAssertNil(QuickAnswers.calculate("1.2.3.4"))
        XCTAssertNil(QuickAnswers.calculate("apple+2"))
    }

    func testConversionParsing() {
        let a = QuickAnswers.parseConversion("100 usd in rub")
        XCTAssertEqual(a?.amount, 100); XCTAssertEqual(a?.from, "USD"); XCTAssertEqual(a?.to, "RUB")
        let b = QuickAnswers.parseConversion("50 евро в рублях")
        XCTAssertEqual(b?.from, "EUR"); XCTAssertEqual(b?.to, "RUB")
        XCTAssertNil(QuickAnswers.parseConversion("how to cook"))
        XCTAssertEqual(QuickAnswers.convert(100, from: "USD", to: "EUR", rates: ["USD": 1, "EUR": 0.9]) ?? 0, 90, accuracy: 0.0001)
    }
}

final class FocusSitesTests: XCTestCase {
    func testBlocking() {
        let l = FocusSites.list(FocusSites.defaults)
        XCTAssertTrue(FocusSites.isBlocked(host: "www.youtube.com", in: l))
        XCTAssertTrue(FocusSites.isBlocked(host: "m.youtube.com", in: l))
        XCTAssertFalse(FocusSites.isBlocked(host: "notyoutube.com", in: l))
        XCTAssertFalse(FocusSites.isBlocked(host: "example.com", in: l))
    }
}

final class ExtensionIDTests: XCTestCase {
    func testChromeID() {
        // Matches what Chromium reported for /private/tmp/sbx/s/Extensions/t.
        XCTAssertEqual(ExtensionStore.chromeID(forFolder: "/private/tmp/sbx/nope"), ExtensionStore.chromeID(forFolder: "/private/tmp/sbx/nope"))
        XCTAssertEqual(ExtensionStore.chromeID(forFolder: "/private/tmp/sbx/s/Extensions/t").count, 32)
        XCTAssertEqual(ExtensionStore.chromeID(forFolder: "/private/tmp/sbx/s/Extensions/t"), "jlopimbdbcocbljhcnfbhckhhjgdmlda")
    }
}


final class ExtensionSafeModeTests: XCTestCase {
    func testStalledStartDisablesExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        let ext = root.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"A","version":"1"}"#.utf8).write(to: ext.appendingPathComponent("manifest.json"))
        let bad = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: bad.appendingPathComponent("manifest.json"))
        XCTAssertEqual(ExtensionStore.enabledPaths(root: root).map { ($0 as NSString).lastPathComponent }, ["good"])        // broken ones never reach the engine
        XCTAssertFalse(ExtensionStore.beginStartup(root: root))                       // first start: nothing wrong
        XCTAssertTrue(ExtensionStore.beginStartup(root: root))                        // the marker survived: the last start stalled
        XCTAssertEqual(ExtensionStore.enabledPaths(root: root), [])                   // so everything is off
        ExtensionStore.endStartup(root: root)
        XCTAssertFalse(ExtensionStore.beginStartup(root: root))
    }
}
