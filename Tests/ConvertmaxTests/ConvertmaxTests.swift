import XCTest
@testable import Convertmax

final class ConvertmaxTests: XCTestCase {
    func testConsentAndIdentityBoundaries() async {
        let sdk = Convertmax(configuration: .init(writeKey: "public", appID: "demo"))
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
        let sdk = Convertmax(configuration: .init(writeKey: "public", appID: "demo"))
        _ = await sdk.flush()
        await sdk.setConsent(.granted)
        let purchase = await sdk.revenue(transactionReference: "txn-1", amount: "4.99", currency: "USD")
        XCTAssertNotNil(purchase)
        let before = await sdk.diagnostics()
        XCTAssertEqual(before.queued, 1)
        let flushed = await sdk.flush()
        XCTAssertEqual(flushed.count, 1)
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

    func testGzipPayloadHasGzipMagic() {
        let compressed = Gzip.compress(Data("convertmax".utf8))
        XCTAssertEqual(compressed.prefix(2), Data([0x1f, 0x8b]))
    }
}
