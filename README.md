# Convertmax iOS SDK

Swift Package Manager package for the native Convertmax mobile event SDK. The public actor API covers consent, identity, track, screen, revenue observations, deep-link parameter extraction and diagnostics. Durable SQLite queueing, gzip batching, retries and lifecycle adapters are the next slice.

## Sample app

1. Open `samples/ios/ConvertmaxSample.xcodeproj` in Xcode (or regenerate it with `cd samples/ios && xcodegen`).
2. Select an iOS Simulator and run **ConvertmaxSample**.
3. Grant consent, then Identify / Track / Screen / Observe purchase / Flush / Reset. The write key is public and ingestion-only.

```bash
swift test
cd samples/ios && xcodegen && xcodebuild -scheme ConvertmaxSample -destination 'generic/platform=iOS Simulator' build
```

Use the shared `convertmax_event/contracts/mobile-v1` fixtures before publishing a release. This SDK does not manage StoreKit entitlements or create verified revenue. Do not publish a production release until durable disk queueing, network delivery, gzip batching, retries, lifecycle adapters and the privacy manifest are complete.
