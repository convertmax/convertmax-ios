# Convertmax iOS SDK

Swift Package Manager package for the native Convertmax mobile event SDK. The public actor API covers consent, identity, track, screen, revenue observations, deep-link parameter extraction and diagnostics. Events are stored in SQLite, flushed as gzip `mobile-v1` batches, and retried on backgrounding. This SDK does not manage StoreKit entitlements or create verified revenue.

## Sample app

1. Open `samples/ios/ConvertmaxSample.xcodeproj` in Xcode (or regenerate it with `cd samples/ios && xcodegen`).
2. Select an iOS Simulator and run **ConvertmaxSample**.
3. Grant consent, then Identify / Track / Screen / Observe purchase / Flush / Reset. The write key is public and ingestion-only.

```bash
swift test
cd samples/ios && xcodegen && xcodebuild -scheme ConvertmaxSample -destination 'generic/platform=iOS Simulator' build
```

This SDK does not manage StoreKit entitlements or create verified revenue.
