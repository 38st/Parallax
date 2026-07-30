import XCTest
@testable import ParallaxMobile

final class WebSpaceTests: XCTestCase {
    func testStarterSpacesUseIndependentDataStores() {
        let spaces = WebSpace.starterSpaces()

        XCTAssertEqual(spaces.count, 4)
        XCTAssertEqual(Set(spaces.map(\.dataStoreID)).count, spaces.count)
    }

    func testSpaceRoundTripsThroughJSON() throws {
        let original = WebSpace(
            name: "Work",
            service: .chatGPT,
            startURL: URL(string: "https://chatgpt.com/")!
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WebSpace.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}

