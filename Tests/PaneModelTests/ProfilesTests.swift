import XCTest
@testable import PaneModel

@MainActor
final class ProfilesTests: XCTestCase {
    func testSlugs() {
        XCTAssertEqual(ProfilesStore.slug(from: "Work"), "work")
        XCTAssertEqual(ProfilesStore.slug(from: "  My School!! "), "my-school")
        XCTAssertEqual(ProfilesStore.slug(from: "Café"), "cafe")
        XCTAssertEqual(ProfilesStore.slug(from: "Работа"), "profile", "non-Latin names still get a safe folder name")
        XCTAssertEqual(ProfilesStore.slug(from: "../../etc"), "etc", "no path tricks")
    }

    func testAddRenameRemove() {
        let s = ProfilesStore()
        let work = s.add(name: "Work", colorIndex: 1)
        XCTAssertEqual(work?.id, "work")
        XCTAssertNil(s.add(name: "work", colorIndex: 2), "names are unique, ignoring case")
        XCTAssertNil(s.add(name: "Default", colorIndex: 0), "the built-in profile's name is reserved")
        XCTAssertNil(s.add(name: "   ", colorIndex: 0))
        XCTAssertNil(s.add(name: String(repeating: "x", count: 31), colorIndex: 0))
        let ru = s.add(name: "Работа", colorIndex: 3), ru2 = s.add(name: "Школа", colorIndex: 4)
        XCTAssertEqual([ru?.id, ru2?.id], ["profile", "profile-2"], "two names with the same slug get different folders")
        XCTAssertTrue(s.rename("work", to: "Job"))
        XCTAssertEqual(s.profile("work")?.name, "Job")
        XCTAssertFalse(s.rename("work", to: "Школа"))
        s.remove("work")
        XCTAssertNil(s.profile("work"))
    }

    func testPersistence() throws {
        let s = ProfilesStore()
        s.add(name: "Work", colorIndex: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID()).json")
        try s.save(to: url)
        let t = ProfilesStore()
        XCTAssertTrue(t.load(from: url))
        XCTAssertEqual(t.profiles, s.profiles)
    }
}
