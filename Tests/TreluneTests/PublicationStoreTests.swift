import XCTest
@testable import Trelune

@MainActor final class PublicationStoreTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func makeStore() -> PostStore { PostStore(file: directory.appendingPathComponent("publications.json"), lockFile: directory.appendingPathComponent(".lock")) }

    func testLegacyPublicationsDecodeWithDefaults() throws {
        let legacy = #"[{"id":"9C2B7E2F-6A43-4F6B-8B2A-1C1A3E1E7D01","title":"Antigo","text":"Texto","platforms":["YouTube"],"date":700000000,"status":"Agendado"}]"#
        let posts = try JSONDecoder().decode([Publication].self, from: Data(legacy.utf8))
        XCTAssertEqual(posts.first?.title, "Antigo")
        XCTAssertEqual(posts.first?.youtubePrivacy, "private")
        XCTAssertTrue(posts.first?.results.isEmpty ?? false)
        XCTAssertNil(posts.first?.mediaPath)
    }

    func testPerNetworkTextFallsBackToBaseText() {
        var post = Publication(title: "T", text: "base", platforms: ["X", "YouTube"], date: Date(), status: PostStatus.draft)
        post.overrides = ["X": "curto", "YouTube": "   "]
        XCTAssertEqual(post.text(for: "X"), "curto")
        XCTAssertEqual(post.text(for: "YouTube"), "base")
    }

    func testStorePersistsAndReloadsChangesFromAnotherWriter() throws {
        let store = makeStore()
        let post = store.add(title: "Um", text: "a", platforms: ["X"], date: Date(), status: PostStatus.draft)
        store.edit(post.id) { $0.status = PostStatus.scheduled }
        let other = makeStore()
        XCTAssertEqual(other.post(post.id)?.status, PostStatus.scheduled)
        other.add(title: "Dois", text: "b", platforms: ["Threads"], date: Date(), status: PostStatus.draft)
        // Ensure a distinct modification timestamp for the reload check.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: directory.appendingPathComponent("publications.json").path)
        store.reloadIfChanged()
        XCTAssertEqual(store.posts.count, 2)
    }

    func testDuplicateResetsResultsAndStatus() {
        let store = makeStore()
        var post = Publication(title: "Base", text: "x", platforms: ["X"], date: Date().addingTimeInterval(-60), status: PostStatus.published)
        post.results["X"] = PlatformResult(state: "ok", detail: "feito")
        store.add(post)
        let copy = store.duplicate(post.id)
        XCTAssertEqual(copy?.status, PostStatus.draft)
        XCTAssertTrue(copy?.results.isEmpty ?? false)
        XCTAssertGreaterThan(copy?.date ?? .distantPast, Date())
    }
}
