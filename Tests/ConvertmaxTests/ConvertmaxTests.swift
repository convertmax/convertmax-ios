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
}
