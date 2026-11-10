import XCTest
@testable import Trelune

final class NetworkLimitsTests: XCTestCase {
    func testXCountsLinksAs23() {
        let text = "Comece grátis: https://example.com/?utm_source=x&utm_medium=social&utm_campaign=novembro"
        XCTAssertEqual(NetworkLimits.length(text, for: "X"), "Comece grátis: ".count + 23)
    }
    func testXCountsEmojiAsTwo() {
        XCTAssertEqual(NetworkLimits.length("Salva! 🚀", for: "X"), 9)
        XCTAssertEqual(NetworkLimits.length("👍🏽", for: "X"), 2)
    }
    func testOtherNetworksCountCharacters() {
        XCTAssertEqual(NetworkLimits.length("🚀 https://example.co.uk", for: "Threads"), 23)
    }
}
