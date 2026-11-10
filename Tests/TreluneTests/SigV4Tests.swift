import XCTest
@testable import Trelune

final class SigV4Tests: XCTestCase {
    /// Example "GET Object" from the AWS S3 Signature Version 4 documentation.
    func testMatchesAWSDocumentationExample() {
        let headers = ["host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9", "x-amz-content-sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "x-amz-date": "20130524T000000Z"]
        let value = SigV4.authorization(method: "GET", path: "/test.txt", headers: headers, payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", region: "us-east-1", accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        XCTAssertEqual(value, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }
    func testCarouselFormatAndLegacyMediaPath() throws {
        var post = Publication(title: "C", text: "", platforms: ["Instagram", "TikTok", "X"], date: Date(), status: PostStatus.draft)
        post.media = ["/a/1.png", "/a/2.png", "/a/3.png"]
        XCTAssertEqual(post.format(for: "Instagram"), "Carrossel · 3")
        XCTAssertEqual(post.format(for: "TikTok"), "Fotos · 3")
        let legacy = try JSONDecoder().decode(Publication.self, from: Data(#"{"title":"v","text":"","platforms":[],"date":0,"status":"Rascunho","mediaPath":"/v.mp4"}"#.utf8))
        XCTAssertEqual(legacy.media, ["/v.mp4"])
        XCTAssertEqual(legacy.format(for: "Instagram"), "Reels")
    }
}
