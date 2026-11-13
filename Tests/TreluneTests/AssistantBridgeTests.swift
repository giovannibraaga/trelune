import XCTest
@testable import Trelune

@MainActor final class AssistantBridgeTests: XCTestCase {
    func testOldPermissionsDoNotGrantNewCapabilities() throws {
        let old = Data(#"{"enabled":true,"allowWrite":true,"allowSchedule":true,"allowDelete":false}"#.utf8)
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: old)
        XCTAssertTrue(decoded.enabled)
        XCTAssertTrue(decoded.allowSchedule)
        XCTAssertFalse(decoded.allowPublish)
        XCTAssertFalse(decoded.allowManage)
    }

    func testBridgePermissionsBackupAndExpiredRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = getenv("TRELUNE_DATA_DIR").map { String(cString: $0) }
        setenv("TRELUNE_DATA_DIR", directory.path, 1)
        defer {
            if let old { setenv("TRELUNE_DATA_DIR", old, 1) } else { unsetenv("TRELUNE_DATA_DIR") }
            try? FileManager.default.removeItem(at: directory)
        }
        var settings = AssistantSettings(); settings.enabled = true; settings.allowWrite = true; settings.save()
        let store = PostStore(file: directory.appendingPathComponent("publications.json"), lockFile: directory.appendingPathComponent("lock"))
        let post = store.add(title: "Teste", text: "Texto", platforms: ["X"], date: Date(), status: PostStatus.draft)
        let center = PublishingCenter(store: store, youtube: YouTubeConnection(), meta: MetaConnection(), tiktok: TikTokConnection(), threads: ThreadsConnection(), x: XConnection(), host: MediaHost())
        let bridge = AssistantBridge(center: center, router: Router())
        let backup = try XCTUnwrap(bridge.execute(["action": "export_backup"]) as? [[String: Any]])
        XCTAssertEqual(backup.count, 1)
        XCTAssertThrowsError(try bridge.execute(["action": "import_backup", "arguments": ["publications": backup]]))
        settings.allowManage = true; settings.save()
        let result = try XCTUnwrap(bridge.execute(["action": "import_backup", "arguments": ["publications": backup + backup]]) as? [String: Int])
        XCTAssertEqual(result["imported"], 0)
        XCTAssertEqual(store.posts.first?.id, post.id)
        let requests = directory.appendingPathComponent("assistant-requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let expired = requests.appendingPathComponent("expired.request")
        let data = try JSONSerialization.data(withJSONObject: ["action": "export_backup", "expires": Date().timeIntervalSince1970 - 1])
        try data.write(to: expired)
        bridge.process()
        XCTAssertFalse(FileManager.default.fileExists(atPath: requests.appendingPathComponent("expired.response").path))
        let valid = requests.appendingPathComponent("valid.request")
        let request = try JSONSerialization.data(withJSONObject: ["action": "export_backup", "expires": Date().timeIntervalSince1970 + 8])
        try request.write(to: valid)
        bridge.process()
        let response = try Data(contentsOf: requests.appendingPathComponent("valid.response"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual((object["value"] as? [[String: Any]])?.count, 1)
    }
}
