import XCTest
import SQLite3
@testable import Convertmax

final class ConvertmaxTests: XCTestCase {
    // Each test gets its own storage directory so persisted consent from earlier runs cannot leak in.
    private func freshConfiguration() -> ConvertmaxConfiguration {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ConvertmaxConfiguration(writeKey: "public", appID: "demo", storageDirectory: dir)
    }

    func testConsentAndIdentityBoundaries() async {
        let sdk = Convertmax(configuration: freshConfiguration())
        let beforeConsent = await sdk.track("opened")
        XCTAssertNil(beforeConsent)
        await sdk.setConsent(.granted)
        await sdk.identify("account-a")
        let event = await sdk.track("signup")
        XCTAssertEqual(event?.userId, "account-a")
        await sdk.reset()
        let afterReset = await sdk.track("after-reset")
        XCTAssertNil(afterReset?.userId)
    }

    func testRevenueIsQueuedAndFlushIsBounded() async {
        let sdk = Convertmax(configuration: freshConfiguration())
        await sdk.clearQueue()
        await sdk.setConsent(.granted)
        let purchase = await sdk.revenue(transactionReference: "txn-1", amount: "4.99", currency: "USD")
        XCTAssertNotNil(purchase)
        let before = await sdk.diagnostics()
        XCTAssertEqual(before.queued, 1)
        await sdk.clearQueue()
        let after = await sdk.diagnostics()
        XCTAssertEqual(after.queued, 0)
    }

    func testMobileV1AckDropsAcceptedAndNonRetryableRejected() {
        let body = """
        {"contract":"mobile-v1","results":[
          {"messageId":"AAA","status":"accepted"},
          {"messageId":"BBB","status":"rejected","code":"empty_name","retryable":false},
          {"messageId":"CCC","status":"rejected","retryable":true}
        ]}
        """.data(using: .utf8)!
        XCTAssertEqual(MobileV1Ack.droppableMessageIds(httpStatus: 202, body: body), ["aaa", "bbb"])
        XCTAssertNil(MobileV1Ack.droppableMessageIds(httpStatus: 200, body: Data("{}".utf8)))
    }

    func testSqliteQueueSurvivesRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ConvertmaxConfiguration(writeKey: "public", appID: "demo", storageDirectory: dir)
        let first = Convertmax(configuration: config)
        _ = await first.flush()
        await first.setConsent(.granted)
        let tracked = await first.track("signup")
        XCTAssertNotNil(tracked)
        let second = Convertmax(configuration: config)
        let diagnostics = await second.diagnostics()
        XCTAssertEqual(diagnostics.queued, 1)
    }

    func testIncrementalWritesPersistInsertsAndDeletes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let config = ConvertmaxConfiguration(writeKey: "public", appID: "demo", storageDirectory: dir)
        let first = Convertmax(configuration: config)
        await first.setConsent(.granted)
        _ = await first.track("one")
        _ = await first.track("two")
        await first.clearQueue()
        _ = await first.track("three")
        let second = Convertmax(configuration: config)
        let diagnostics = await second.diagnostics()
        XCTAssertEqual(diagnostics.queued, 1)
    }

    func testGzipPayloadHasGzipMagic() {
        let compressed = Gzip.compress(Data("convertmax".utf8))
        XCTAssertEqual(compressed?.prefix(2), Data([0x1f, 0x8b]))
    }

    func testGzipReturnsNilForEmptyInput() {
        // Callers must not label a body as gzip when compression did not happen.
        XCTAssertNil(Gzip.compress(Data()))
    }

    func testUnreadableRowsAreNotPurgedBySave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = EventStore(directory: dir)
        XCTAssertTrue(store.load().isEmpty)

        // Simulate a row written by an older schema that the current decoder cannot read.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("events.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO events VALUES ('legacy-1', '{\"old\":true}', 0);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let reloaded = EventStore(directory: dir)
        XCTAssertTrue(reloaded.load().isEmpty)
        reloaded.save([])

        var check: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("events.sqlite").path, &check), SQLITE_OK)
        var count: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(check, "SELECT COUNT(*) FROM events WHERE message_id = 'legacy-1';", -1, &count, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(count), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(count, 0), 1)
        sqlite3_finalize(count)
        sqlite3_close(check)
    }
}
