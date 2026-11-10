import XCTest
@testable import Trelune

final class TikTokProtocolTests: XCTestCase {
    func testTikTokPKCEUsesHexDigestRatherThanBase64() {
        XCTAssertEqual(TikTokProtocol.challenge("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testFormEncodingPreservesReservedCharacters() {
        XCTAssertEqual(String(data: TikTokProtocol.form(["code": "a+b&c=á", "redirect_uri": "http://127.0.0.1:123/oauth/callback"]), encoding: .utf8), "code=a%2Bb%26c%3D%C3%A1&redirect_uri=http%3A%2F%2F127.0.0.1%3A123%2Foauth%2Fcallback")
    }
    func testSmallVideosUseSingleRequest() throws {
        XCTAssertEqual(try TikTokProtocol.chunks(size: 4_194_304), [.init(offset: 0, size: 4_194_304)])
    }
    func testTrailingBytesBelongToLastChunk() throws {
        XCTAssertEqual(try TikTokProtocol.chunks(size: 25_000_123), [.init(offset: 0, size: 10_000_000), .init(offset: 10_000_000, size: 15_000_123)])
    }
    func testChunkPlanCoversEveryByteExactlyOnce() throws {
        for size: Int64 in [1, 9_999_999, 10_000_000, 10_000_001, 19_999_999, 20_000_000, 64_000_001, 4_000_000_000] {
            let chunks = try TikTokProtocol.chunks(size: size)
            XCTAssertEqual(chunks.reduce(0) { $0 + $1.size }, size)
            var end: Int64 = 0
            for chunk in chunks { XCTAssertEqual(chunk.offset, end); XCTAssertGreaterThan(chunk.size, 0); end += chunk.size }
        }
    }
    func testInvalidFileSizesAreRejected() {
        XCTAssertThrowsError(try TikTokProtocol.chunks(size: 0))
        XCTAssertThrowsError(try TikTokProtocol.chunks(size: -1))
        XCTAssertThrowsError(try TikTokProtocol.chunks(size: 4_000_000_001))
    }
    func testInboxDeliveryIsNotShownAsPublished() {
        XCTAssertNotEqual(TikTokDeliveryStatus.label("SEND_TO_USER_INBOX"), TikTokDeliveryStatus.label("PUBLISH_COMPLETE"))
        XCTAssertTrue(TikTokDeliveryStatus.label("SEND_TO_USER_INBOX").contains("finalize"))
    }
    func testAPIErrorCanBeReadWhenDataObjectIsEmpty() throws {
        let payload = Data(#"{"data":{},"error":{"code":"scope_not_authorized","message":"not allowed"}}"#.utf8)
        let result = try JSONDecoder().decode(TikTokConnection.ErrorEnvelope.self, from: payload)
        XCTAssertEqual(result.error.code, "scope_not_authorized")
    }

}
