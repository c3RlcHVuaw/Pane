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
